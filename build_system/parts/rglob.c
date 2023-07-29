
/* ----- rglob.c ----- */

typedef struct rglob_entry {
	char type;
	char* full_path;
	char* file_name;
//	char* dir_name;
} rglob_entry;

typedef struct rglob {
	char* pattern;

	int len;
	int alloc;
	rglob_entry* entries;
	
} rglob;



int rglob_fn(char* full_path, char* file_name, unsigned char type, void* _results) {
	rglob* res = (rglob*)_results;
	
	if(0 == fnmatch(res->pattern, file_name, 0)) {
		check_alloc(res);
		
		res->entries[res->len].type = type;
		res->entries[res->len].full_path = strcache(full_path);
		res->entries[res->len].file_name = strcache(file_name);
		res->len++;
	}
	
	return 0;
}

void recursive_glob(char* base_path, char* pattern, int flags, rglob* results) {
	
	// to pass into recurse_dirs()
	results->pattern = pattern;
	results->len = 0;
	results->alloc = 32;
	results->entries = malloc(sizeof(*results->entries) * results->alloc);
	
	recurse_dirs(base_path, rglob_fn, results, -1, flags);
}


/* -END- rglob.c ----- */
