
/* ----- pkgconfig.c ----- */


char* pkg_config(char** packages, char* opts) {
	char* tmp;
	
	int num_pkgs = list_len(packages);
	if(num_pkgs == 0) return strdup("");
	
	char* pkgs = join_str_list(packages, " ");
	
	for(char* c = opts; *c; c++) {
		switch(*c) {
			case 'c':
			case 'C':
			case 'i':
			case 'I':
				tmp = strjoin(" ", "--cflags", pkgs);
				free(pkgs);
				pkgs = tmp;
				break;
				
			case 'l':
			case 'L':
				tmp = strjoin(" ", "--libs", pkgs);
				free(pkgs);
				pkgs = tmp;
				break;
		}
	} 	
	
	tmp = strjoin(" ", "pkg-config", pkgs);
	free(pkgs);
	
	FILE* f = popen(tmp, "r");
	free(tmp);
	if(!f) {
		fprintf(stderr, "Could not run command '%s'\n", tmp);
		exit(1);
		return NULL;
	}
	
	int len = 2048;
	int fill = 0;
	char* buffer = malloc(len * sizeof(*buffer));
	while(!feof(f)) {
		if(fill + 1 >= len) {
			len *= 2;
			buffer = realloc(buffer, len * sizeof(*buffer));
		} 
		fill += fread(buffer + fill, 1, len - fill - 1, f); 
	}
	
	buffer[fill] = 0;
	pclose(f);
		
	// strip out newlines and other garbage
	for(char* c = buffer; *c; c++) if(isspace(*c)) *c = ' ';
	
	return buffer;
}


/* -END- pkgconfig.c ----- */


