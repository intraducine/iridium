// SPDX-License-Identifier: AGPL-3.0-only
#include "oslib/virtmem.h"
#include "IRJITExecutionProbe.h"
#include "IRSharedJITMemory.h"
#include <cstring>
#include <unistd.h>
namespace virtmem {
bool prepare_jit_block(void *, size_t size, void **write, ptrdiff_t *offset) {
    if (!write || !offset) return false;
    void *rx = ir_shared_jit_allocate(size, write);
    if (!rx) return false;
    *offset = (intptr_t)rx - (intptr_t)*write;
    return true;
}
void release_jit_block(void *first, void *second, size_t) {
    ir_shared_jit_release(first ? first : second);
}
}
extern "C" bool ir_phase3_core_check_jit() {
#if defined(__aarch64__)
    void *write=nullptr;
    ptrdiff_t offset=0;
    size_t size=(size_t)getpagesize();
    if(!virtmem::prepare_jit_block(nullptr,size,&write,&offset)||!write)return false;
    void *code=(char *)write+offset;
    const uint32_t first[]={0xd2800540,0xd65f03c0};
    memcpy(write,first,sizeof first);
    virtmem::flush_cache(code,(char *)code+sizeof first,write,(char *)write+sizeof first);
    bool result=ir_jit_probe_execute(code,sizeof first,42);
    if(result) {
        const uint32_t second[]={0xd28000e0,0xd65f03c0};
        memcpy(write,second,sizeof second);
        virtmem::flush_cache(code,(char *)code+sizeof second,write,(char *)write+sizeof second);
        result=ir_jit_probe_execute(code,sizeof second,7);
    }
    virtmem::release_jit_block(code,write,size);return result;
#else
    return false;
#endif
}
