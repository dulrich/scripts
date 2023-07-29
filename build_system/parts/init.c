





void parse_cli_opts(int argc, char** argv, objfile* obj) {

	for(int a = 1; a < argc; a++) {
		if(argv[a][0] == '-') {
			for(int i = 0; argv[a][i]; i++) {
				
				switch(argv[a][i]) {
					case 'd': // debug: -ggdb
						obj->mode_debug = 1;
						if(obj->mode_release == 1) {
							fprintf(stderr, "Debug and Release set at the same time.\n");
						}
						break;
						
					case 'p': // profiling: -pg
						obj->mode_profiling = 1;
						break;
						
					case 'r': // release: -O3
						obj->mode_release = 1;
						obj->mode_debug = 0;
						break;
						
					case 'c': // clean
						obj->clean_first = 1;
						break;
						
					case 'v': // verbose
						obj->verbose = 1;
						break;
				}
			}		
		}
	
	}
	
	
}


char* default_compile_source(char* src_path, char* obj_path, objfile* obj);

void start_obj(objfile* obj) {

	
	obj->build_subdir = calloc(1, 20);
	
	if(obj->mode_debug) strcat(obj->build_subdir, "d");
	if(obj->mode_profiling) strcat(obj->build_subdir, "p");
	if(obj->mode_release) strcat(obj->build_subdir, "r");

	obj->build_dir = path_join(obj->base_build_dir, obj->build_subdir);
	
	if(!obj->archive_path) {
		obj->archive_path = path_join(obj->build_dir, "tmp.a");
	}
	
	// clean up old executables
	unlink(obj->exe_path);
	unlink(obj->archive_path);
	
	// delete old build files if needed 
	if(obj->clean_first) {
		printf("Cleaning directory %s/\n", obj->build_dir);
		system(sprintfdup("rm -rf %s/*", obj->build_dir));
	}
	
	// ensure the build dir exists
	mkdirp_cached(obj->build_dir, 0755);
	
	
	// flatten all the gcc options
	obj->gcc_opts_list = concat_lists(obj->ld_add, obj->common_cflags);
	
	if(obj->mode_debug) obj->gcc_opts_list = concat_lists(obj->gcc_opts_list, obj->debug_cflags);
	if(obj->mode_profiling) obj->gcc_opts_list = concat_lists(obj->gcc_opts_list, obj->profiling_cflags);
	if(obj->mode_release) obj->gcc_opts_list = concat_lists(obj->gcc_opts_list, obj->release_cflags);
	
	obj->gcc_opts_flat = join_str_list(obj->gcc_opts_list, " ");
	obj->gcc_include = pkg_config(obj->lib_headers_needed, "I");
	obj->gcc_libs = pkg_config(obj->libs_needed, "L");
	
	char* tmp = obj->gcc_opts_flat;
	obj->gcc_opts_flat = strjoin(" ", obj->gcc_opts_flat, obj->gcc_include);
	free(tmp);
	
	// initialze the object file list
	strlist_init(&obj->objs);
	strlist_init(&obj->compile_cache);
	
	if(!obj->compile_source_cmd) obj->compile_source_cmd = default_compile_source;	
}




