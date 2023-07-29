
/* ----- hash.c ----- */

typedef struct {
		hash_t hash;
		char* key;
		void* value;
} hashbucket;

typedef struct hashtable {
	int fill;
	int alloc;
	hashbucket* buckets;

} hashtable;


void hash_init(hashtable* ht, int alloc) {
	ht->fill = 0;
	ht->alloc = alloc ? alloc : 128;
	ht->buckets = calloc(1, ht->alloc * sizeof(*ht->buckets));
}

hashtable* hash_new(int alloc) {
	hashtable* ht = malloc(sizeof(*ht));
	hash_init(ht, alloc);
	return ht;
}

int hash_find_bucket(hashtable* ht, hash_t hash, char* key) {
	int b = hash % ht->alloc;
	
	for(int i = 0; i < ht->alloc; i++) {
		// empty bucket
		if(ht->buckets[b].key == NULL) return b;
		
		// full bucket
		if(ht->buckets[b].hash == hash) {
			if(0 == strcmp(key, ht->buckets[b].key)) {
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

void hash_expand(hashtable* ht) {
	int old_alloc = ht->alloc;
	ht->alloc *= 2;
	
	hashbucket* old = ht->buckets;
	ht->buckets = calloc(1, ht->alloc * sizeof(*ht->buckets));
	
	for(int i = 0, f = 0; i < old_alloc && f < ht->fill; i++) { 
		if(!old[i].key) continue;
		
		int b = hash_find_bucket(ht, old[i].hash, old[i].key);
		
		ht->buckets[b] = old[i];
		f++;
	}
	
	free(old);
}

void hash_insert(hashtable* ht, char* key, void* value) {
	
	hash_t hash = strhash(key);
	int b = hash_find_bucket(ht, hash, key);
	
	if(!ht->buckets[b].key) {
		if(ht->fill > ht->alloc * .80) {
			hash_expand(ht);
			
			// the bucket location has changed
			b = hash_find_bucket(ht, hash, key);
		}
		
		ht->fill++;
	}
	
	ht->buckets[b].key = strcache(key);
	ht->buckets[b].hash = hash;
	ht->buckets[b].value = value;
}

void* hash_find(hashtable* ht, char* key) {

	hash_t hash = strhash(key);
	int b = hash_find_bucket(ht, hash, key);
	 
	return ht->buckets[b].value;
}

/* -END- hash.c ----- */


