/* ----- strlist.c ----- */

#include <string.h>
#include <stdlib.h>

#define check_alloc(x) \
	if((x)->len + 1 >= (x)->alloc) { \
		(x)->alloc *= 2; \
		(x)->entries = realloc((x)->entries, (x)->alloc * sizeof(*(x)->entries)); \
	}
	


typedef struct strlist {
	int len;
	int alloc;
	char** entries;
} strlist;



void strlist_init(strlist* sl) {
	sl->len = 0;
	sl->alloc = 32;
	sl->entries = malloc(sl->alloc * sizeof(*sl->entries));
}

strlist* strlist_new() {
	strlist* sl = malloc(sizeof(*sl));
	strlist_init(sl);
	return sl;
}

void strlist_push(strlist* sl, char* e) {
	check_alloc(sl);
	sl->entries[sl->len++] = e;
	sl->entries[sl->len] = 0;
}


/* -END- strlist.c ----- */

