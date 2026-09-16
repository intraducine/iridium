#pragma once
#include <cassert>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <cstdlib>
#include <cstdio>
#include "win_shim.h"
extern "C" {
void model_check_guests(void); void model_diagnostic(void); void model_init(int); void *model_reserve(size_t,size_t); void model_commit(void*,size_t); void model_release(void*);
size_t model_peak(void); size_t model_span(void); void *model_heap(void); void *model_alloc(void*,size_t,size_t);
void model_free(void*,void*); void model_heap_release(void*); unsigned model_class(size_t); unsigned model_class_limit(void);
unsigned model_class_blocks(size_t);
extern uintptr_t ios_fex_band_base, ios_fex_band_end;
}
static bool fail_reserve, fail_commit, fail_emulator;
static unsigned scrub_calls, release_calls;
static void *VirtualAlloc2(void*,void*,size_t n,unsigned flags,unsigned,MEM_EXTENDED_PARAMETER *param,unsigned count) {
  assert(count==1 && param && (flags & MEM_RESERVE));
  auto req=static_cast<MEM_ADDRESS_REQUIREMENTS*>(param->Pointer);
  assert(req && reinterpret_cast<uintptr_t>(req->LowestStartingAddress)==ios_fex_band_base);
  assert(reinterpret_cast<uintptr_t>(req->HighestEndingAddress)==ios_fex_band_end);
  return fail_reserve ? nullptr : model_reserve(n,65536);
}
static void *VirtualAlloc(void *p,size_t n,unsigned flags,unsigned) {
  if (flags & MEM_RESERVE) return fail_emulator ? nullptr : model_reserve(n,65536);
  if(fail_commit) return nullptr;
  assert(flags==MEM_COMMIT); model_commit(p,n); return p;
}
// Use real release semantics instead of the allocator's unused Win32 stub.
static int ModelVirtualFree(void *p,size_t n,int t) { assert(!n && t==MEM_RELEASE); ++release_calls; model_release(p);return 1; }
#define VirtualFree ModelVirtualFree
#define LOGMAN_THROW_A_FMT(p,...) do { if(!(p)) abort(); } while(0)
#define ERROR_AND_DIE_FMT(...) abort()
namespace LogMan::Msg { template<class... T> void EFmt(const char*,T...){} template<class... T> void DFmt(const char*,T...){} }
namespace FEXCore::Utils { constexpr size_t FEX_PAGE_SIZE=4096; }
namespace FEXCore::Core {
struct CPUState {
  uint64_t rip,gregs[16],callret_sp{},callret_sp_base{},flags;
  struct gdt_segment { int L, D; };
  static constexpr int DEFAULT_USER_CS=1, SEGMENT_ARRAY_INDEX_GDT=0, SEGMENT_ARRAY_INDEX_LDT=1;
  static void SetGDTBase(gdt_segment*,uint64_t){} static void SetGDTLimit(gdt_segment*,uint64_t){}
  static uint64_t CalculateGDTBase(gdt_segment&) {return 0;}
  gdt_segment *segment_arrays[2]{};
  uint64_t gs_cached{},fs_cached{},cs_cached{},cs_idx{};
};
struct CpuStateFrame { CPUState State{}; };
struct InternalThreadState {
  static constexpr size_t CALLRET_STACK_SIZE=0x1000000;
  void *CallRetStackBase{}; CpuStateFrame frame{}; CpuStateFrame *CurrentFrame=&frame;
};
}
namespace FEXCore::X86State { constexpr size_t REG_RSP=4; }
namespace FEXCore::Allocator {
enum class THPControl {Disable};
inline void VirtualName(const char*,const void*,size_t){}
inline void VirtualTHPControl(const void*,size_t,THPControl){}
inline size_t ZeroScrub(void *p,size_t n) { assert(p && reinterpret_cast<uintptr_t>(p)>65536); ++scrub_calls; memset(p,0,n); return 0; }
}
