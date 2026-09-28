#!/usr/bin/env python3
"""Compile the production arena policy against an ownership-aware Mach VM model.

These tests exercise reservation/rollback and replay the measured allocation
pressure. They do not execute Wine, FEX, Metal, or an iOS kernel.
"""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / "MadeiraSupport/NativePool.c").read_text()
function = source[source.index("/* Host arena policy:"):]
harness = r'''
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
typedef uint64_t vm_address_t;
typedef uint64_t vm_size_t;
typedef int kern_return_t;
typedef int mach_msg_type_number_t;
typedef void *task_info_t;
typedef struct { uint64_t max_address; } task_vm_info_data_t;
#define TASK_VM_INFO_COUNT 1
#define TASK_VM_INFO 1
#define KERN_SUCCESS 0
#define VM_FLAGS_FIXED 0
#define VM_PROT_NONE 0
#define FALSE 0
#define G (1ULL << 30)
#define M (1ULL << 20)
struct interval { uint64_t lo, hi; };
static struct interval allowed[8], blocks[128];
static int allowed_count, block_count, info_fails, protect_fails, allocations;
static int release_fails, publication_fails;
static uint64_t ceiling;
static int mach_task_self(void) { return 1; }
static int task_info(int t, int f, task_info_t i, int *n) {
    (void)t; (void)f; (void)n;
    if (info_fails) return 1;
    ((task_vm_info_data_t *)i)->max_address = ceiling;
    return 0;
}
static int fits(uint64_t base, uint64_t size) {
    if (!size || size > UINT64_MAX - base || base + size > ceiling) return 0;
    int in_allowed = 0;
    for (int i=0; i<allowed_count; i++)
        if (base >= allowed[i].lo && base + size <= allowed[i].hi) in_allowed = 1;
    if (!in_allowed) return 0;
    for (int i=0; i<block_count; i++)
        if (base < blocks[i].hi && base + size > blocks[i].lo) return 0;
    return 1;
}
static int vm_allocate(int t, uint64_t *base, uint64_t size, int flags) {
    (void)t;
    assert(flags == VM_FLAGS_FIXED); /* Never overwrite another mapping. */
    allocations++;
    if (!fits(*base,size)) return 1;
    assert(block_count < 128);
    blocks[block_count++] = (struct interval){*base, *base+size};
    return 0;
}
static int vm_protect(int t, uint64_t b, uint64_t s, int max, int p) {
    (void)t; (void)b; (void)s; (void)max;
    assert(p == VM_PROT_NONE);
    return protect_fails ? 1 : 0;
}
static int vm_deallocate(int t, uint64_t b, uint64_t s) {
    (void)t;
    if (release_fails) { release_fails--; return 1; }
    assert(s && b+s>b);
    for (int i=0; i<block_count; ) {
        struct interval x = blocks[i];
        if (b >= x.hi || b+s <= x.lo) { i++; continue; }
        blocks[i] = blocks[--block_count];
        if (x.lo < b) blocks[block_count++] = (struct interval){x.lo,b};
        if (x.hi > b+s) blocks[block_count++] = (struct interval){b+s,x.hi};
    }
    return 0;
}
static int tracked_setenv(const char *name, const char *value, int overwrite) {
    if (publication_fails && --publication_fails == 0) return -1;
    return setenv(name,value,overwrite);
}
#define setenv tracked_setenv
'''
main = r'''
#undef setenv
static void reset(uint64_t low, uint64_t high) {
    allowed_count=1; allowed[0]=(struct interval){low,high};
    ceiling=high; block_count=0; info_fails=protect_fails=release_fails=publication_fails=allocations=0;
    iridium_fex_reserved=0;
    unsetenv("WINE_IOS_FEX_ARENA_BASE"); unsetenv("WINE_IOS_FEX_ARENA_SIZE");
}
static uint64_t arena_size(void) {
    const char *p=getenv("WINE_IOS_FEX_ARENA_SIZE");
    return p ? strtoull(p,0,16) : 0;
}
static uint64_t arena_base(void) {
    const char *p=getenv("WINE_IOS_FEX_ARENA_BASE");
    return p ? strtoull(p,0,16) : 0;
}
static void unpublished(void) {
    assert(!iridium_fex_reserved);
    assert(!getenv("WINE_IOS_FEX_ARENA_BASE"));
    assert(!getenv("WINE_IOS_FEX_ARENA_SIZE"));
}
/* Replay ordinary guest allocations without letting them enter the FEX band. */
static uint64_t guest_reserve(uint64_t size, uint64_t limit) {
    size=(size+0xffff)&~0xffffULL;
    for (int w=0; w<allowed_count; w++) {
        uint64_t a=(allowed[w].lo+0xffff)&~0xffffULL;
        uint64_t end=allowed[w].hi < limit ? allowed[w].hi : limit;
        while (a < end && end-a>=size) {
            uint64_t next=a;
            for (int i=0;i<block_count;i++)
                if (a < blocks[i].hi && a+size > blocks[i].lo && blocks[i].hi > next)
                    next=(blocks[i].hi+0xffff)&~0xffffULL;
            if (next!=a) { a=next; continue; }
            if (vm_allocate(1,&a,size,VM_FLAGS_FIXED)==0) return a;
            break;
        }
    }
    return 0;
}
static int replay_guest_startup(uint64_t fex_base) {
    /* The logs show ~2 GB above 0x700... minus Wine images/TEBs, plus
     * one ~512 MB low-address allocation; the fifth 511 MB request fails.
     * Reserve 200 MB of ordinary runtime space below the arena. */
    uint64_t metadata=fex_base-200*M;
    assert(vm_allocate(1,&metadata,200*M,VM_FLAGS_FIXED)==0);
    int count=0;
    while (count<8 && guest_reserve(0x1ffff000ULL,fex_base)) count++;
    return count;
}
int main(void) {
    int tests=0;
    const uint64_t lo=0x7000000000ULL, hi=0x7180000000ULL;
    /* Actual failing geometry, not a mock that only accepts a given size. */
    reset(lo,hi);
    allowed[allowed_count++]=(struct interval){0x140000000ULL,0x160000000ULL};
    uint64_t old_base=hi-4*G;
    assert(vm_allocate(1,&old_base,4*G,VM_FLAGS_FIXED)==0);
    assert(replay_guest_startup(old_base)==4); tests++;
    reset(lo,hi);
    allowed[allowed_count++]=(struct interval){0x140000000ULL,0x160000000ULL};
    assert(iridium_reserve_fex_memory());
    assert(arena_size()==G && arena_base()==hi-G && block_count==1);
    assert(blocks[0].lo==hi-G && blocks[0].hi==hi);
    assert(replay_guest_startup(arena_base())==8); tests++;
    reset(lo,hi);
    allowed[allowed_count++]=(struct interval){0x140000000ULL,0x160000000ULL};
    assert(iridium_tight_va_fex_size(5*G)==0);
    assert(iridium_tight_va_fex_size(6*G)==1536*M);
    assert(iridium_tight_va_fex_size(7*G)==1792*M);
    assert(iridium_tight_va_fex_size(8*G)==0);
    assert(iridium_try_budgeted_fex_range(hi,lo,iridium_tight_va_fex_size(hi-lo))==1);
    assert(arena_size()==1536*M && arena_base()==hi-1536*M);
    assert(replay_guest_startup(arena_base())==8);
    assert(guest_reserve(0x1ffff000ULL,arena_base())!=0); tests++;
    /* The same code must work at different process ceilings, not phone IDs. */
    struct { uint64_t low, high, size; } cases[] = {
        {lo, 0x8000000000ULL,16*G}, {lo+G,0x8000000000ULL,8*G},
        {8*G,40*G,8*G}, {8*G,24*G,4*G}, {8*G,16*G,2*G},
        {8*G,14*G,G}, {8*G,13*G,G}
    };
    for(unsigned i=0;i<sizeof(cases)/sizeof(*cases);i++) {
        reset(cases[i].low,cases[i].high);
        assert(iridium_reserve_fex_memory());
        assert(arena_size()==cases[i].size && block_count==1);
        assert(arena_base()>=cases[i].low+4*G);
        uint64_t guest=3*arena_size(); if(guest<4*G)guest=4*G;
        assert(arena_base()-cases[i].low>=guest);
        tests++;
    }
    reset(lo,lo+4*G); assert(!iridium_reserve_fex_memory()); unpublished(); assert(block_count==0); tests++;
    reset(lo,hi); info_fails=1; assert(!iridium_reserve_fex_memory()); unpublished(); assert(allocations==0); tests++;
    reset(lo,hi); protect_fails=1; assert(!iridium_reserve_fex_memory()); unpublished(); assert(block_count==0); tests++;
    reset(lo,hi); release_fails=1; assert(!iridium_reserve_fex_memory()); unpublished(); assert(block_count==0); tests++;
    reset(lo,hi); release_fails=2; assert(!iridium_reserve_fex_memory()); unpublished(); assert(block_count==1); tests++;
    for (int fail_at=1;fail_at<=2;fail_at++) {
        reset(lo,hi); publication_fails=fail_at;
        assert(!iridium_reserve_fex_memory()); unpublished(); assert(block_count==0); tests++;
    }
    reset(lo,hi); setenv("WINE_IOS_FEX_ARENA_BASE","deadbeef",1); setenv("WINE_IOS_FEX_ARENA_SIZE","100000000",1);
    assert(iridium_reserve_fex_memory()); assert(arena_base()==hi-G && arena_size()==G); tests++;
    int calls=allocations, count=block_count; assert(iridium_reserve_fex_memory());
    assert(allocations==calls && block_count==count); tests++;
    /* The top hole alone fits 4 GB but lacks a guest budget. Scan down to a
     * separate usable 5 GB interval, retaining all foreign mappings. */
    reset(8*G,13*G); allowed[allowed_count++]=(struct interval){20*G,24*G}; ceiling=24*G;
    uint64_t foreign=21*G; assert(vm_allocate(1,&foreign,G,0)==0);
    assert(iridium_reserve_fex_memory()); assert(arena_base()==12*G && arena_size()==G);
    assert(block_count==2 && blocks[0].lo==21*G && blocks[0].hi==22*G); tests++;
    /* If all allocatable intervals are too small, never trust apparent free
     * addresses in between (the log's CPU-inaccessible gaps). */
    reset(8*G,10*G); allowed[allowed_count++]=(struct interval){20*G,22*G}; ceiling=32*G;
    assert(!iridium_reserve_fex_memory()); unpublished(); assert(block_count==0); tests++;
    reset(G,4*G); assert(!iridium_reserve_fex_memory()); unpublished(); assert(allocations==0); tests++;
    printf("Host arena: %d executable cases passed; 1.5 GiB FEX range serves the ninth guest reserve.\n",tests);
    return 0;
}
'''
with tempfile.TemporaryDirectory() as tmp:
    src, exe = Path(tmp) / "arena.c", Path(tmp) / "arena"
    src.write_text(harness + function + main)
    subprocess.run(["cc", "-std=c11", "-D_POSIX_C_SOURCE=200809L", "-Wall", "-Wextra", "-Werror",
                    "-fsanitize=undefined", str(src), "-o", str(exe)], check=True)
    env = {k: v for k, v in os.environ.items()
           if k not in {"WINE_IOS_FEX_ARENA_BASE", "WINE_IOS_FEX_ARENA_SIZE"}}
    subprocess.run([str(exe)], check=True, env=env)
