// gcc -lutil build.c -o hacer && ./hacer

// link with -lutil

char* build_dir;
char* source_dir = "./"; // "src"
char* exe_path = "hworld";
char* base_build_dir = "build";


#include "_build.inc.c"



char* sources[] = {
	"test.c",
	NULL,
};

// these are run through pkg-config
char* lib_headers_needed[] = {
	// freetype and fontconfig are dynamically loaded only when needed
//	"freetype2", "fontconfig",
	
//	"gl", "glu", "glew",
//	"libpcre2-8", 
//	"libpng", 
//	"x11", "xfixes",
	NULL
};

// these are run through pkg-config
char* libs_needed[] = {
//	"gl", "glu", "glew",
//	"libpcre2-8", 
//	"libpng",
//	"x11", "xfixes",
	NULL,
};

char* ld_add[] = {
	"-lm",
//	"-ldl", "-lutil",
	NULL,
};


char* debug_cflags[] = {
	"-ggdb",
	"-DDEBUG",
	"-O0",
	NULL
};

char* profiling_cflags[] = {
	"-pg",
	NULL
};

char* release_cflags[] = {
	"-DRELEASE",
	"-O3",
//	"-Wno-array-bounds", // temporary, until some shit in sti gets fixed. only happens with -O3
	NULL
};

// -ffast-math but without reciprocal approximations 
char* common_cflags[] = {
	"-std=gnu11", 
	"-ffunction-sections", "-fdata-sections",
	"-DLINUX",
	"-march=native",
	"-mtune=native", 
	"-fno-math-errno", 
	"-fexcess-precision=fast", 
	"-fno-signed-zeros",
	"-fno-trapping-math", 
	"-fassociative-math", 
	"-ffinite-math-only", 
	"-fno-rounding-math", 
	"-fno-signaling-nans", 
//	"-include signal.h", 
	"-pthread", 
	"-Wall", 
	"-Werror", 
	"-Wextra", 
	"-Wno-unused-result", 
	"-Wno-unused-variable", 
	"-Wno-unused-but-set-variable", 
	"-Wno-unused-function", 
	"-Wno-unused-label", 
	"-Wno-unused-parameter",
	"-Wno-pointer-sign", 
	"-Wno-missing-braces", 
	"-Wno-maybe-uninitialized", 
	"-Wno-implicit-fallthrough", 
	"-Wno-sign-compare", 
	"-Wno-char-subscripts", 
	"-Wno-int-conversion", 
	"-Wno-int-to-pointer-cast", 
	"-Wno-unknown-pragmas",
	"-Wno-sequence-point",
	"-Wno-switch",
	"-Wno-parentheses",
	"-Wno-comment",
	"-Wno-strict-aliasing",
	"-Wno-endif-labels",
	"-Werror=implicit-function-declaration",
	"-Werror=uninitialized",
	"-Werror=return-type",
	NULL,
};



int compile_source(char* src_path, char* obj_path, objfile* obj) {
	char* cmd = sprintfdup("gcc -c -o %s %s %s", obj_path, src_path, obj->gcc_opts_flat);
	if(obj->verbose) puts(cmd);
//	printf("%s\n", cmd);
	strlist_push(&obj->compile_cache, cmd);
//	exit(1);
	return 0;
}



/*
void check_source(char* raw_src_path, strlist* objs, objfile* o) {
	time_t src_mtime, obj_mtime = 0, dep_mtime = 0;
	
	char* src_path = resolve_path(raw_src_path, &src_mtime);
	char* src_dir = dir_name(raw_src_path);
	char* base = base_name(src_path);
	
//	char* build_base = "debug";
	char* src_build_dir = path_join(o->build_dir, src_dir);
	char* obj_path = path_join(src_build_dir, base);
	
	// cheap and dirty
	size_t olen = strlen(obj_path);
	obj_path[olen-1] = 'o';
	
	
	strlist_push(objs, obj_path);
	
	char* dep_path = strcatdup(src_build_dir, "/", base, ".d");
	
	mkdirp_cached(src_build_dir, 0755);
	
	char* real_obj_path = resolve_path(obj_path, &obj_mtime);
	if(obj_mtime < src_mtime) {
//		printf("  objtime compile\n");
		compile_source(src_path, real_obj_path, o);
		return;
	}
	
	
	if(gen_deps(src_path, dep_path, src_mtime, obj_mtime, o)) {
//		printf("  deep dep compile\n");
		compile_source(src_path, real_obj_path, o);
	}
	
	//gcc -c -o $2 $1 $CFLAGS $LDADD
}
*/


void global_init() {
	string_cache_init(2048);
	realname_cache_init();
	//strlist_init(&string_cache);
	hash_init(&mkdir_cache, 128);
	g_nprocs = get_nprocs();
}



int main(int argc, char* argv[]) {
	char* cmd;

	global_init();
	
	// defaults
	
	objfile* obj = calloc(1, sizeof(*obj));
	
	obj->mode_debug = 2;
	
	obj->exe_path = "hworld";
	obj->source_dir = "./"; // "src"
	obj->base_build_dir = "build";
	
	obj->sources = sources;
	
	obj->debug_cflags = debug_cflags;
	obj->release_cflags = release_cflags;
	obj->profiling_cflags = profiling_cflags;
	obj->common_cflags = common_cflags;
	
	obj->libs_needed = libs_needed;
	obj->lib_headers_needed = lib_headers_needed;
	obj->ld_add = ld_add;


	parse_cli_opts(argc, argv, obj);
	
	start_obj(obj);
	
	//---------------------------
	//
	// [ custom init code here]
	//
	//---------------------------

	
	//printf("%s\n\n\n\n",g_gcc_opts_flat);
//	rglob src;
	//recursive_glob("src", "*.[ch]", 0, &src);
	
	strlist objs;
	strlist_init(&objs);
	
	float source_count = list_len(obj->sources);
	
	for(int i = 0; obj->sources[i]; i++) {
//		printf("%i: checking %s\n", i, sources[i]);
		char* t = path_join(obj->source_dir, obj->sources[i]);
		check_source(t, &objs, obj);
		free(t);
		
		printf("\rChecking dependencies...  %s", printpct((i * 100) / source_count));
	}
	printf("\rChecking dependencies...  \e[32mDONE\e[0m\n");
	fflush(stdout);
	
	
	
	if(compile_cache_execute(obj)) {
		printf("\e[1;31mBuild failed.\e[0m\n");
		return 1;
	}
	
	char* objects_flat = join_str_list(objs.entries, " ");
	
	
	cmd = sprintfdup("ar rcs %s/tmp.a %s", obj->build_dir, objects_flat);
	if(obj->verbose) puts(cmd);
	
	printf("Creating archive...      "); fflush(stdout);
	if(system(cmd)) {
		printf(" \e[1;31mFAIL\e[0m\n");
		return 1;
	}
	else {
		printf(" \e[32mDONE\e[0m\n");
	}
	
	
	cmd = sprintfdup("gcc -Wl,--gc-sections %s %s/tmp.a -o %s %s %s", 
		obj->mode_profiling ? "-pg" : "", obj->build_dir, obj->exe_path, obj->gcc_libs, obj->gcc_opts_flat
	);
	if(obj->verbose) puts(cmd);
	
	printf("Linking executable...    "); fflush(stdout);
	if(system(cmd)) {
		printf(" \e[1;31mFAIL\e[0m\n");
		return 1;
	}
	else {
		printf(" \e[32mDONE\e[0m\n");
	}
	
	if(!obj->verbose) {
		// erase the build output if it succeeded
		printf("\e[F\e[K");
		printf("\e[F\e[K");
		printf("\e[F\e[K");
		printf("\e[F\e[K");
	}
	
	printf("\e[32mBuild successful:\e[0m %s\n\n", obj->exe_path);
	
	return 0;
}


