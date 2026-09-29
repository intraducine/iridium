// SPDX-License-Identifier: MIT
#define _SECIMP
#define _CRTIMP
#include <cstdint>
#include "../Priv.h"
#include <rpmalloc/rpmalloc.h>

#ifdef FEX_IOS_HOST
extern "C" void fex_ios_rpm_lock(void);
extern "C" void fex_ios_rpm_unlock(void);
namespace { struct IosRpmGuard { IosRpmGuard() { fex_ios_rpm_lock(); } ~IosRpmGuard() { fex_ios_rpm_unlock(); } }; }
#define IOS_RPM_GUARD() IosRpmGuard ios_rpm_guard_
#else
#define IOS_RPM_GUARD() ((void)0)
#endif

void* calloc(size_t NumOfElements, size_t SizeOfElements) {
  IOS_RPM_GUARD();
  return ::rpcalloc(NumOfElements, SizeOfElements);
}

void free(void* Memory) {
  IOS_RPM_GUARD();
  ::rpfree(Memory);
}

void* malloc(size_t Size) {
  IOS_RPM_GUARD();
  return ::rpmalloc(Size);
}

void* realloc(void* Memory, size_t NewSize) {
  IOS_RPM_GUARD();
  return ::rprealloc(Memory, NewSize);
}

DLLEXPORT_FUNC(void*, _aligned_malloc, (size_t Size, size_t Alignment)) {
  IOS_RPM_GUARD();
  return ::rpaligned_alloc(Alignment, Size);
}

DLLEXPORT_FUNC(void, _aligned_free, (void* Memory)) {
  IOS_RPM_GUARD();
  ::rpfree(Memory);
}
