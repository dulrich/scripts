
/* ----- strcache.c ----- */

typedef unsigned long hash_t;

hash_t strhash(char* str) {
	unsigned long h = 0;
	int c;

	while(c = *str++) {
		h = c + (h << 6) + (h << 16) - h;
	}
	return h;
}
hash_t strnhash(char* str, size_t n) {
	unsigned long h = 0;
	int c;

	while((c = *str++) && n--) {
		h = c + (h << 6) + (h << 16) - h;
	}
		
	return h;
}


typedef struct {
		hash_t hash;
		char* str;
		unsigned int len;
		int refs;
} string_cache_bucket;

typedef struct {
	int fill;
	int alloc;
	string_cache_bucket* buckets;
} string_cache_t;


string_cache_t string_cache;

void string_cache_init(int alloc) {
	string_cache.fill = 0;
	string_cache.alloc = alloc ? alloc : 1024;
	string_cache.buckets = calloc(1, string_cache.alloc * sizeof(*string_cache.buckets));
}

int string_cache_find_bucket(string_cache_t* ht, hash_t hash, char* key) {
	int b = hash % ht->alloc;
	
	for(int i = 0; i < ht->alloc; i++) {
		// empty bucket
		if(ht->buckets[b].str == NULL) return b;
		
		// full bucket
		if(ht->buckets[b].hash == hash) {
			if(0 == strcmp(key, ht->buckets[b].str)) {
				return b;
			}
		}
		
		// probe forward on collisions
		b = (b + 1) % ht->alloc;
	}
	
	// should never reach here
	printf("oops. -1 bucket \n");
	return -1;
}

void string_cache_expand(string_cache_t* ht) {
	int old_alloc = ht->alloc;
	ht->alloc *= 2;
	
	string_cache_bucket* old = ht->buckets;
	ht->buckets = calloc(1, ht->alloc * sizeof(*ht->buckets));
	
	for(int i = 0, f = 0; i < old_alloc && f < ht->fill; i++) { 
		if(!old[i].str) continue;
		
		int b = string_cache_find_bucket(ht, old[i].hash, old[i].str);
		
		ht->buckets[b] = old[i];
		f++;
	}
	
	free(old);
}

char* strcache(char* in) {
	hash_t hash = strhash(in);
	int b = string_cache_find_bucket(&string_cache, hash, in);
	
	if(!string_cache.buckets[b].str) {
		if(string_cache.fill > string_cache.alloc * .80) {
			string_cache_expand(&string_cache);
			
			// the bucket location has changed
			b = string_cache_find_bucket(&string_cache, hash, in);
		}
		
		string_cache.fill++;
		
		string_cache.buckets[b].str = strdup(in);
		string_cache.buckets[b].hash = hash;
		string_cache.buckets[b].refs = 1;
		string_cache.buckets[b].len = strlen(in);
	}
	else {
		string_cache.buckets[b].refs++;
	}
	
	return string_cache.buckets[b].str;
}

char* strncache(char* in, size_t n) {
	hash_t hash = strnhash(in, n);
	int b = string_cache_find_bucket(&string_cache, hash, in);
	
	if(!string_cache.buckets[b].str) {
		if(string_cache.fill > string_cache.alloc * .80) {
			string_cache_expand(&string_cache);
			
			// the bucket location has changed
			b = string_cache_find_bucket(&string_cache, hash, in);
		}
		
		string_cache.fill++;
		
		string_cache.buckets[b].str = strndup(in, n);
		string_cache.buckets[b].hash = hash;
		string_cache.buckets[b].refs = 1;
		string_cache.buckets[b].len = n;
	}
	else {
		string_cache.buckets[b].refs++;
	}
	
	return string_cache.buckets[b].str;
}

void struncache(char* in) {
	hash_t hash = strhash(in);
	int b = string_cache_find_bucket(&string_cache, hash, in);
	
	if(!string_cache.buckets[b].str) {
		// normal string, free it
		free(in);
		return;
	}
	
	string_cache.buckets[b].refs--;
	if(string_cache.buckets[b].refs == 0) {
		// just do nothing for now. deletion is a pain.
	}
}

/* -END- strcache.c ----- */


