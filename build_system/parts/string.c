/* ----- string.c ----- */

#define strjoin(j, ...) strjoin_(j, PP_NARG(__VA_ARGS__), __VA_ARGS__)
char* strjoin_(char* joiner, size_t nargs, ...);
#define strcatdup(...) strcatdup_(PP_NARG(__VA_ARGS__), __VA_ARGS__)
char* strcatdup_(size_t nargs, ...);
size_t list_len(char** list);
char* join_str_list(char* list[], char* joiner);
char* sprintfdup(char* fmt, ...);
#define path_join(...) path_join_(PP_NARG(__VA_ARGS__), __VA_ARGS__)
char* path_join_(size_t nargs, ...);
#define concat_lists(...) concat_lists_(PP_NARG(__VA_ARGS__), __VA_ARGS__)
char** concat_lists_(int nargs, ...);


size_t span_path(char* s) {
	size_t n = 0;
	for(; *s; s++, n++) {
		if(isspace(*s)) break; 
		if(*s == '\\') {
			s++;
			n++;
		}
	} 
	return n;
}


// splits on whitespace
char** strsplit(char* splitters, char* in) {
	char* e;
	int alloc = 32;
	int len = 0;
	char** list = malloc(alloc * sizeof(*list)); 
	
	for(char* s = in; *s;) {
		e = strpbrk(s, splitters);
		if(!e) e = s + strlen(s);
		
		if(len >= alloc - 1) {
			alloc *= 2;
			list = realloc(list, alloc* sizeof(*list));
		}
		
		list[len++] = strndup(s, e - s);
		
		e += strspn(e, splitters);
		s = e;
	}
	
	list[len] = NULL;
	
	return list;
}



static inline char* strskip(char* s, char* skip) {
	return s + strspn(s, skip);
}


// concatenate all argument strings together in a new buffer
char* strcatdup_(size_t nargs, ...) {
	size_t total = 0;
	char* out, *end;
	
	if(nargs == 0) return NULL;
	
	// calculate total buffer len
	va_list va;
	va_start(va, nargs);
	
	for(size_t i = 0; i < nargs; i++) {
		char* s = va_arg(va, char*);
		if(s) total += strlen(s);
	}
	
	va_end(va);
	
	out = malloc((total + 1) * sizeof(char*));
	end = out;
	
	va_start(va, nargs);
	
	for(size_t i = 0; i < nargs; i++) {
		char* s = va_arg(va, char*);
		if(s) {
			strcpy(end, s); // not exactly the ost efficient, but maybe faster than
			end += strlen(s); // a C version. TODO: test the speed
		};
	}
	
	va_end(va);
	
	*end = 0;
	
	return out;
}


// concatenate all argument strings together in a new buffer,
//    with the given joining string between them
char* strjoin_(char* joiner, size_t nargs, ...) {
	size_t total = 0;
	char* out, *end;
	size_t j_len;
	
	if(nargs == 0) return NULL;
	
	// calculate total buffer len
	va_list va;
	va_start(va, nargs);
	
	for(size_t i = 0; i < nargs; i++) {
		char* s = va_arg(va, char*);
		if(s) total += strlen(s);
	}
	
	va_end(va);
	
	j_len = strlen(joiner);
	total += j_len * (nargs - 1);
	
	out = malloc((total + 1) * sizeof(char*));
	end = out;
	
	va_start(va, nargs);
	
	for(size_t i = 0; i < nargs; i++) {
		char* s = va_arg(va, char*);
		if(s) {
			if(i > 0) {
				strcpy(end, joiner);
				end += j_len;
			}
			
			strcpy(end, s); // not exactly the ost efficient, but maybe faster than
			end += strlen(s); // a C version. TODO: test the speed
		};
	}
	
	va_end(va);
	
	*end = 0;
	
	return out;
}

// allocates a new buffer and calls sprintf with it
// why isn't this a standard function?
char* sprintfdup(char* fmt, ...) {
	va_list va;
	
	va_start(va, fmt);
	size_t n = vsnprintf(NULL, 0, fmt, va);
	char* buf = malloc(n + 1);
	va_end(va);
	
	va_start(va, fmt);
	vsnprintf(buf, n + 1, fmt, va);
	va_end(va);
	
	return buf;
}





void free_strpp(char** l) {
	for(char** s = l; *s; s++) free(*s);
	free(l);
}


size_t list_len(char** list) {
	size_t total = 0;
	for(; *list; list++) total++;
	return total;
}

char** concat_lists_(int nargs, ...) {
	size_t total = 0;
	char** out, **end;

	if(nargs == 0) return NULL;

	// calculate total list length
	va_list va;
	va_start(va, nargs);

	for(size_t i = 0; i < nargs; i++) {
		char** s = va_arg(va, char**);
		if(s) total += list_len(s);
	}

	va_end(va);

	out = malloc((total + 1) * sizeof(char**));
	end = out;

	va_start(va, nargs);
	
	// concat lists
	for(size_t i = 0; i < nargs; i++) {
		char** s = va_arg(va, char**);
		size_t l = list_len(s);
		
		if(s) {
			memcpy(end, s, l * sizeof(*s));
			end += l;
		}
	}

	va_end(va);

	*end = 0;

	return out;
}


char* join_str_list(char* list[], char* joiner) {
	size_t list_len = 0;
	size_t total = 0;
	size_t jlen = strlen(joiner);
	
	// calculate total length
	for(int i = 0; list[i]; i++) {
		list_len++;
		total += strlen(list[i]);
	}
	
	if(total == 0) return strdup("");
	
	total += (list_len - 1) * jlen;
	char* out = malloc((total + 1) * sizeof(*out));
	
	char* end = out;
	for(int i = 0; list[i]; i++) {
		char* s = list[i];
		size_t l = strlen(s);
		
		if(i > 0) {
			memcpy(end, joiner, jlen);
			end += jlen;
		}
		
		if(s) {
			memcpy(end, s, l);
			end += l;
		}
		
		total += strlen(list[i]);
	}
	
	*end = 0;
	
	return out;
}




char* path_join_(size_t nargs, ...) {
	size_t total = 0;
	char* out, *end;
	size_t j_len;
	char* joiner = "/";
	int escape;

	if(nargs == 0) return NULL;

	// calculate total buffer length
	va_list va;
	va_start(va, nargs);

	for(size_t i = 0; i < nargs; i++) {
		char* s = va_arg(va, char*);
		if(s) total += strlen(s);
	}

	va_end(va);

	j_len = strlen(joiner);
	total += j_len * (nargs - 1);

	out = malloc((total + 1) * sizeof(char*));
	end = out;

	va_start(va, nargs);

	for(size_t i = 0; i < nargs; i++) {
		char* s = va_arg(va, char*);
		size_t l = strlen(s);
		
		if(s) {
			if(l > 1) {
				escape = s[l-2] == '\\' ? 1 : 0;
			}

			if(i > 0 && (s[0] == joiner[0])) {
				s++;
				l--;
			}

			if(i > 0 && i != nargs-1 && !escape && (s[l-1] == joiner[0])) {
				l--;
			}

			if(i > 0) {
				strcpy(end, joiner);
				end += j_len;
			}

			// should be strncpy, but GCC is so fucking stupid that it
			//   has a warning about using strncpy to do exactly what 
			//   strncpy does if you read the fucking man page.
			// fortunately, we are already terminating our strings
			//   manually so memcpy is a drop-in replacement here.
			memcpy(end, s, l);
			end += l;
		}
	}

	va_end(va);

	*end = 0;

	return out;
}


/* -END- string.c ----- */


