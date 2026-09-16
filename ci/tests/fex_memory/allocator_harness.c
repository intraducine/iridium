/* Execute the pinned rpmalloc, with only OS mappings replaced by a bounded
 * address-space model backed by real anonymous memory. No allocator mock. */
#define _GNU_SOURCE
#include "win_shim.h"
#include "rpmalloc/rpmalloc.c"
#include <assert.h>
#include <pthread.h>
#define UNIT 65536UL
#define GIB (1UL << 30)
static unsigned char *arena, *guest;
static unsigned int pages[16384];
static size_t occupied, peak;
static pthread_mutex_t map_lock = PTHREAD_MUTEX_INITIALIZER;
static int exhaust_is_exit;
volatile int FEX_AllocWatch_Armed;
void FEX_AllocWatch_Event(const void *p, unsigned int e) { (void)p; (void)e; }
void *model_reserve(size_t size, size_t alignment) {
  if (alignment < UNIT) alignment = UNIT;
  size_t n = (size + UNIT - 1) / UNIT;
  pthread_mutex_lock(&map_lock);
  for (size_t i=0; i+n<=16384; ) {
    uintptr_t at = (uintptr_t)arena + i*UNIT;
    size_t pad = ((-at)&(alignment-1))/UNIT;
    i += pad;
    if (i+n>16384) break;
    size_t j=0;
    while (j<n && !pages[i+j]) ++j;
    if (j==n) {
      for(j=0;j<n;j++) pages[i+j]=(unsigned)n;
      occupied += n*UNIT; if(occupied>peak) peak=occupied;
      pthread_mutex_unlock(&map_lock);
      return arena+i*UNIT;
    }
    i += j+1;
  }
  pthread_mutex_unlock(&map_lock);
  if (exhaust_is_exit) { fprintf(stderr,"bounded arena exhausted peak=%zu\n",peak); exit(42); }
  return NULL;
}
void model_release(void *ptr) {
  assert(ptr && (unsigned char *)ptr>=arena && (unsigned char *)ptr<arena+GIB);
  size_t i=((unsigned char*)ptr-arena)/UNIT;
  assert((unsigned char*)ptr==arena+i*UNIT);
  pthread_mutex_lock(&map_lock);
  size_t n=pages[i]; assert(n && i+n<=16384);
  assert(!mprotect(ptr,n*UNIT,PROT_NONE));
  assert(!madvise(ptr,n*UNIT,MADV_DONTNEED));
  for(size_t j=0;j<n;j++) { assert(pages[i+j]==n); pages[i+j]=0; }
  occupied-=n*UNIT;
  pthread_mutex_unlock(&map_lock);
}
void model_commit(void *ptr,size_t size) {
  assert(ptr && (unsigned char*)ptr>=arena && (unsigned char*)ptr+size<=arena+GIB);
  uintptr_t begin=(uintptr_t)ptr&~(uintptr_t)16383;
  uintptr_t end=((uintptr_t)ptr+size+16383)&~(uintptr_t)16383;
  assert(!mprotect((void*)begin,end-begin,PROT_READ|PROT_WRITE));
}
static void model_decommit(void *ptr,size_t size) {
  uintptr_t begin=((uintptr_t)ptr+16383)&~(uintptr_t)16383;
  uintptr_t end=((uintptr_t)ptr+size)&~(uintptr_t)16383;
  if(end>begin) assert(!madvise((void*)begin,end-begin,MADV_DONTNEED));
}
static void *model_map(size_t size,size_t align,size_t *offset,size_t *mapped) {
  *offset=0; *mapped=(size+UNIT-1)&~(UNIT-1); return model_reserve(size,align);
}
static void model_unmap(void *ptr,size_t offset,size_t size) { assert(!offset); (void)size; model_release(ptr); }
void model_init(int on_exhaust_exit) {
  size_t total=6*GIB+(16UL<<20);
  unsigned char *raw=mmap(NULL,total,PROT_NONE,MAP_PRIVATE|MAP_ANONYMOUS,-1,0);
  assert(raw!=MAP_FAILED);
  guest=(void*)(((uintptr_t)raw+(16UL<<20)-1)&~((16UL<<20)-1));
  arena=guest+5*GIB;
  // Keep eight large guest reservations and image space in the same VM map.
  // Touch sentinel pages only; reservations are not physical-RAM consumption.
  for(size_t i=0;i<8;i++) {
    unsigned char *p=guest+i*(GIB/2);
    assert(!mprotect(p,16384,PROT_READ|PROT_WRITE)); p[0]=(unsigned char)(i+1);
  }
  assert(!mprotect(guest+4*GIB,16384,PROT_READ|PROT_WRITE));
  guest[4*GIB]=0x5a;
  ios_fex_band_base=(uintptr_t)arena; ios_fex_band_end=(uintptr_t)arena+GIB-1;
  exhaust_is_exit=on_exhaust_exit;
  static rpmalloc_interface_t iface;
  iface.memory_map=model_map; iface.memory_unmap=model_unmap;
  iface.memory_commit=model_commit; iface.memory_decommit=model_decommit;
  rpmalloc_config_t config={0}; config.page_size=16384;
  assert(!rpmalloc_initialize_config(&iface,&config));
}
size_t model_peak(void) { return peak; }
size_t model_span(void) { return SPAN_SIZE; }
void *model_heap(void) {
  heap_t *h = rpmalloc_heap_acquire();
  // Match production thread heaps, not ownerless first-class huge-list rules.
  assert(h); h->owner_thread = get_thread_id(); return h;
}
void *model_alloc(void *h,size_t n,size_t align) { return rpmalloc_heap_aligned_alloc(h,align,n); }
void model_free(void *h,void *p) { rpmalloc_heap_free(h,p); }
void model_heap_release(void *h) { rpmalloc_heap_free_all(h); rpmalloc_heap_release(h); }
unsigned model_class(size_t n) { return get_size_class(n); }
unsigned model_class_limit(void) { return SIZE_CLASS_COUNT; }
unsigned model_class_blocks(size_t n) { unsigned c=get_size_class(n);return c<SIZE_CLASS_COUNT?global_size_class[c].block_count:1; }

void model_check_guests(void) {
  for(size_t i=0;i<8;i++) assert(guest[i*(GIB/2)]==(unsigned char)(i+1));
  assert(guest[4*GIB]==0x5a);
}
void model_diagnostic(void) {
  heap_t heap={0}; page_t first={0}, second={0};
  first.heap=&heap; first.size_class=3; first.prev=&second;
  second.next=&first; heap.page_available[3]=&first;
  assert(rpm_avail_check(&heap,3,&first,1,"consume")&32);
  char operation[1024]; memset(operation,'x',sizeof(operation)-1);operation[sizeof(operation)-1]=0;
  assert(rpm_avail_check(&heap,3,&first,1,operation)&32);
}
