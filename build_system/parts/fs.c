
/* ----- fs.c ----- */

typedef struct realname_entry {
	char* realname;
	time_t mtime;
} realname_entry;

struct {
	hashtable names;

	int len;
	int alloc;
	struct realname_entry* entries;
} realname_cache;


hashtable mkdir_cache;


#define FSU_EXCLUDE_HIDDEN     (1<<0)
#define FSU_NO_FOLLOW_SYMLINKS (1<<1)
#define FSU_INCLUDE_DIRS       (1<<2)
#define FSU_EXCLUDE_FILES      (1<<3)

// return 0 to continue, nonzero to stop all directory scanning
typedef int (*readDirCallbackFn)(char* /*fullPath*/, char* /*fileName*/, unsigned char /*type*/, void* /*data*/);
// returns negative on error, nonzero if scanning was halted by the callback
int recurse_dirs(
	char* path, 
	readDirCallbackFn fn, 
	void* data, 
	int depth, 
	unsigned int flags
);




void realname_cache_init();
time_t realname_cache_add(char* fake_name, char* real_name);
realname_entry* realname_cache_search_real(char* real_name);
realname_entry* realname_cache_search(char* fake_name);
char* realname_cache_find(char* fake_name);

char* resolve_path(char* in, time_t* mtime_out);


char* read_whole_file(char* path, size_t* srcLen);


char* dir_name(char* path) {
	char* n = strdup(path);
	char* o = dirname(n);
	return strcache(o);
}

char* base_name(char* path) {
	char* n = strdup(path);
	char* o = basename(n);
	return strcache(o);
}




// does not handle escaped slashes
int mkdirp(char* path, mode_t mode) {
	
	char* clean_path = strdup(path);
	
	// inch along the path creating each directory in line
	for(char* p = clean_path; *p; p++) {
		if(*p == '/') {
			*p = 0;
			
			if(mkdir(clean_path, mode)) {
				if(errno != EEXIST) goto FAIL;
			}
			
			*p = '/';
		}
	}
	
	// mop up the last dir
	if(mkdir(clean_path, mode)) {
		if(errno != EEXIST) goto FAIL;
	}
	
	free(clean_path);
	return 0;
	
FAIL:
	free(clean_path);
	return -1;
}


void mkdirp_cached(char* path, mode_t mode) {
	void* there = hash_find(&mkdir_cache, path);
	if(!there) {
		hash_insert(&mkdir_cache, path, NULL);
		mkdirp(path, mode);
	}
}





// works like realpath(), except also handles ~/
char* resolve_path(char* in, time_t* mtime_out) {
	int tmp_was_malloced = 0;
	char* out, *tmp;
	
	if(!in) return NULL;
	
	realname_entry* e = realname_cache_search(in);
	if(e) {
		if(mtime_out) *mtime_out = e->mtime;
		return strcache(e->realname);
	}
	
	// skip leading whitespace
	while(isspace(*in)) in++;
	
	// handle home dir shorthand
	if(in[0] == '~') {
		char* home = getenv("HOME");
		
		tmp_was_malloced = 1;
		tmp = malloc(sizeof(*tmp) * (strlen(home) + strlen(in) + 2));
		
		strcpy(tmp, home);
		strcat(tmp, "/"); // just in case
		strcat(tmp, in + 1);
	}
	else tmp = in;
	
	out = realpath(tmp, NULL);
	
	if(tmp_was_malloced) free(tmp);
	
	time_t t = 0;
	if(out) {
		// put it in the cache
		t = realname_cache_add(in, out);
	}
	else {
		// temporary
		struct stat st;
		if(!lstat(in, &st))
			t = st.st_mtim.tv_sec;
	}
	
	if(mtime_out) *mtime_out = t;	
	return out ? out : in;
}






void realname_cache_init() {
	realname_cache.len = 0;
	realname_cache.alloc = 1024;
	realname_cache.entries = malloc(realname_cache.alloc * sizeof(*realname_cache.entries));

	hash_init(&realname_cache.names, 1024);
}

time_t realname_cache_add(char* fake_name, char* real_name) {
	realname_entry* e = hash_find(&realname_cache.names, fake_name);
	if(e) return e->mtime;
	
	e = hash_find(&realname_cache.names, real_name);
	if(!e) {
		struct stat st;
		lstat(real_name, &st);
		
		e = &realname_cache.entries[realname_cache.len];
		e->realname = strcache(real_name);
		e->mtime = st.st_mtim.tv_sec;
		realname_cache.len++;
		
		hash_insert(&realname_cache.names, real_name, e);
	}
	
	hash_insert(&realname_cache.names, fake_name, e);
	
	return e->mtime;
}

realname_entry* realname_cache_search_real(char* real_name) {
	for(int i = 0; i < realname_cache.len; i++) {
		if(0 == strcmp(real_name, realname_cache.entries[i].realname)) {
			return &realname_cache.entries[i];
		}
	}
	
	return NULL;
}
realname_entry* realname_cache_search(char* fake_name) {
	return hash_find(&realname_cache.names, fake_name);
}

char* realname_cache_find(char* fake_name) {
	realname_entry* r = realname_cache_search(fake_name);
	return r ? r->realname : NULL;
}






// returns negative on error, nonzero if scanning was halted by the callback
int recurse_dirs(
	char* path, 
	readDirCallbackFn fn, 
	void* data, 
	int depth, 
	unsigned int flags
) {
	
	DIR* derp;
	struct dirent* result;
	int stop = 0;
	
	if(fn == NULL) {
		fprintf(stderr, "Error: readAllDir called with null function pointer.\n");
		return -1;
	}
	
	derp = opendir(path);
	if(derp == NULL) {
		fprintf(stderr, "Error opening directory '%s': %s\n", path, strerror(errno));
		return -1;
	}
	
	
	while((result = readdir(derp)) && !stop) {
		char* n = result->d_name;
		unsigned char type = DT_UNKNOWN;
		char* fullPath;
		
		// skip self and parent dir entries
		if(n[0] == '.') {
			if(n[1] == '.' && n[2] == 0) continue;
			if(n[1] == 0) continue;
			
			if(flags & FSU_EXCLUDE_HIDDEN) continue;
		}

#ifdef _DIRENT_HAVE_D_TYPE
		type = result->d_type; // the way life should be
#else
		// do some slow extra bullshit to get the type
		fullPath = path_join(path, n);
		
		struct stat upgrade_your_fs;
		
		lstat(fullPath, &upgrade_your_fs);
		
		if(S_ISREG(upgrade_your_fs.st_mode)) type = DT_REG;
		else if(S_ISDIR(upgrade_your_fs.st_mode)) type = DT_DIR;
		else if(S_ISLNK(upgrade_your_fs.st_mode)) type = DT_LNK;
#endif
		
		if(flags & FSU_NO_FOLLOW_SYMLINKS && type == DT_LNK) {
			continue;
		}
		
#ifdef _DIRENT_HAVE_D_TYPE
		fullPath = path_join(path, n);
#endif
		
		if(type == DT_DIR) {
			if(flags & FSU_INCLUDE_DIRS) {
				stop = fn(fullPath, n, type, data);
			}
			if(depth != 0) {
				stop |= recurse_dirs(fullPath, fn, data, depth - 1, flags);
			}
		}
		else if(type == DT_REG) {
			if(!(flags & FSU_EXCLUDE_FILES)) {
				stop = fn(fullPath, n, type, data);
			}
		}
		
		free(fullPath);
	}
	
	
	closedir(derp);
	
	return stop;
}




char* read_whole_file(char* path, size_t* srcLen) {
	size_t fsize, total_read = 0, bytes_read;
	char* contents;
	FILE* f;
	
	
	f = fopen(path, "rb");
	if(!f) {
		fprintf(stderr, "Could not open file \"%s\"\n", path);
		return NULL;
	}
	
	fseek(f, 0, SEEK_END);
	fsize = ftell(f);
	rewind(f);
	
	contents = malloc(fsize + 1);
	
	while(total_read < fsize) {
		bytes_read = fread(contents + total_read, sizeof(char), fsize - total_read, f);
		total_read += bytes_read;
	}
	
	contents[fsize] = 0;
	
	fclose(f);
	
	if(srcLen) *srcLen = fsize;
	
	return contents;
}

/* -END- fs.c ----- */


