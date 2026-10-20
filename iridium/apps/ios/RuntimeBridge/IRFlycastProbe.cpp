// SPDX-License-Identifier: AGPL-3.0-only
#include "oslib/virtmem.h"
#include "IRJITExecutionProbe.h"
#include <cstring>
#include <unistd.h>
extern "C" bool ir_phase3_core_check_jit() {
#if defined(__aarch64__)
    void *code=nullptr;
    size_t size=(size_t)getpagesize();
    if(!virtmem::prepare_jit_block(nullptr,size,&code)||!code)return false;
    const uint32_t first[]={0xd2800540,0xd65f03c0};
    memcpy(code,first,sizeof first);
    virtmem::flush_cache(code,(char *)code+sizeof first,code,(char *)code+sizeof first);
    bool result=ir_jit_probe_execute(code,sizeof first,42);
    if(result) {
        const uint32_t second[]={0xd28000e0,0xd65f03c0};
        memcpy(code,second,sizeof second);
        virtmem::flush_cache(code,(char *)code+sizeof second,code,(char *)code+sizeof second);
        result=ir_jit_probe_execute(code,sizeof second,7);
    }
    virtmem::release_jit_block(code,size);return result;
#else
    return false;
#endif
}
