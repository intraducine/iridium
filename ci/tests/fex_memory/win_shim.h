/* Host test boundary only. Production allocator code is compiled unchanged. */
#pragma once
#include <stdint.h>
#include <stddef.h>
#include <wchar.h>
typedef void *HANDLE, *HMODULE, *PVOID;
typedef size_t SIZE_T;
typedef unsigned long ULONG;
#define WINAPI
#define MEM_RESERVE 0x2000
#define MEM_COMMIT 0x1000
#define MEM_RELEASE 0x8000
#define MEM_TOP_DOWN 0x100000
#define PAGE_NOACCESS 1
#define PAGE_READWRITE 4
typedef struct { void *LowestStartingAddress, *HighestEndingAddress; size_t Alignment; } MEM_ADDRESS_REQUIREMENTS;
typedef struct { unsigned long Type; void *Pointer; } MEM_EXTENDED_PARAMETER;
#define MemExtendedParameterAddressRequirements 1
typedef struct { unsigned long dwPageSize, dwAllocationGranularity; void *lpMaximumApplicationAddress; } SYSTEM_INFO;
static inline void *GetCurrentProcess(void) { return (void *)-1; }
static inline void *GetStdHandle(unsigned long x) { (void)x; return 0; }
static inline int WriteFile(void *h,const void *p,unsigned long n,unsigned long *w,void *o) { (void)h;(void)p;(void)o; if(w)*w=n; return 1; }
static inline void *CreateFileA(const char *a,int b,int c,void*d,int e,int f,void*g) { (void)a;(void)b;(void)c;(void)d;(void)e;(void)f;(void)g; return (void*)-1; }
static inline void *GetModuleHandleW(const wchar_t *s) { (void)s; return 0; }
static inline void *GetProcAddress(void *h,const char*s) { (void)h;(void)s; return 0; }
static inline void GetSystemInfo(SYSTEM_INFO *s) { s->dwPageSize=16384;s->dwAllocationGranularity=65536;s->lpMaximumApplicationAddress=(void*)0x8000000000ULL; }
static inline int VirtualFree(void *p,size_t n,int t) { (void)p;(void)n;(void)t; return 1; }
