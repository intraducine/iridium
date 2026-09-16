#include "callret_stub.h"
#include "CallRetStack.h"
#include <vector>
#include <string>
using namespace FEX::Windows::CallRetStack;
int main(int argc,char **argv) {
  assert(argc==2); std::string mode=argv[1]; model_init(mode=="replay");
  if(mode=="failure") {
    FEXCore::Core::InternalThreadState t;
    fail_reserve=true;
    assert(!TryInitializeThread(&t)); assert(!t.CallRetStackBase && !scrub_calls && !release_calls);
    assert(!t.CurrentFrame->State.callret_sp);
    fail_reserve=false; fail_commit=true;
    assert(!TryInitializeThread(&t)); assert(!t.CallRetStackBase && !scrub_calls && release_calls==1);
    fail_commit=false; assert(TryInitializeThread(&t));
    assert(t.CallRetStackBase && scrub_calls==1);
    auto info=GetInfoThread(&t); assert(info.DefaultLocation==(uintptr_t)t.CallRetStackBase+0x400000);
    uint64_t sp=0; assert(HandleAccessViolation(&t,info.AllocationBase,sp)); assert(sp==info.DefaultLocation);
    DestroyThread(&t); assert(!t.CallRetStackBase && !t.CurrentFrame->State.callret_sp);
    DestroyThread(&t); assert(release_calls==2); assert(!HandleAccessViolation(&t,0,sp));
    puts("reserve failure, commit failure, rollback, retry, bounds and repeated destroy passed");
  } else if(mode=="diagnostic") {
    model_diagnostic(); puts("bounded allocator diagnostic passed");
  } else if(mode=="classes") {
    auto h=model_heap();
    for(size_t n: {size_t(1),size_t(4096),size_t(12288),size_t(262144),size_t(524288),size_t(3<<20),size_t(4<<20),size_t(5<<20),size_t(8<<20),size_t(16<<20)}) {
      assert(model_class_blocks(n));
      for(size_t a: {size_t(16),size_t(4096),size_t(65536)}) {
        auto p=model_alloc(h,n,a);assert(p);assert(!((uintptr_t)p&(a-1)));
        memset(p,0x5a,n); assert(((unsigned char*)p)[n-1]==0x5a);model_free(h,p);
      }
    }
    model_heap_release(h);puts("small/medium/large/huge and aligned allocation boundaries passed");
  } else {
    constexpr int count=28;
    std::vector<FEXCore::Core::InternalThreadState> threads(count);
    std::vector<void*> heaps;
    // Four simultaneously active compilers, each using the logged 16+8 MiB scratch.
    for(int i=0;i<8;i++) { auto p=model_reserve(i%2?8UL<<20:16UL<<20,65536); assert(p); }
    for(int i=0;i<count;i++) {
      auto h=model_heap(); assert(h); heaps.push_back(h);
      // Exercise every span type in a live heap, not just arithmetic on sizes.
      for(size_t n: {size_t(256),size_t(12288),size_t(524288)}) {
        auto p=model_alloc(h,n,n==12288?4096:16); assert(p); memset(p,i+1,n);
      }
      auto l1=model_reserve(2UL<<20,65536);assert(l1);
      assert(TryInitializeThread(&threads[i]));
    }
    model_check_guests();
    printf("8 guest reservations plus %d live heaps + full callret stacks + L1 + scratch; span=%zu peak=%zu bytes\n",count,model_span(),model_peak());
    assert(model_peak()<(1UL<<30));
    for(auto &t:threads) DestroyThread(&t);
    for(auto h:heaps) model_heap_release(h);
  }
}
