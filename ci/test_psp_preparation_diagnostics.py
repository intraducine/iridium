"""Fault-inject the shipping Mach mapper and exercise real VM region boundaries."""
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
BRIDGE = ROOT/'iridium/apps/ios/RuntimeBridge'


@unittest.skipUnless(platform.system() == 'Darwin' and shutil.which('clang++'), 'Darwin compiler required')
class PreparationDiagnosticsTests(unittest.TestCase):
    def run_fixture(self, source):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); main = root/'main.cpp'; binary = root/'check'
            main.write_text('#include <algorithm>\n' + source)
            result = subprocess.run(['clang++', '-std=c++17', '-Wall', '-Wextra', '-Werror',
                                     '-I', str(BRIDGE), str(main), '-o', str(binary)],
                                    text=True, capture_output=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            result = subprocess.run([str(binary)], text=True, capture_output=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            print(result.stdout.strip())

    def fragments(self):
        source = (BRIDGE/'IRPSPExecutableMemory.cpp').read_text()
        operations = source[source.index('enum Operation {'):source.index('#if defined(IR_PSP_EXEC_FIXTURE)')]
        start = source.index('bool recordView(')
        query = source[start:source.index('bool unmapView(', start)]
        mapper = source[source.index('bool mapArena(Arena &a,'):source.index('void synchronize(void *rw,')]
        return operations, query, mapper

    def test_actual_mapper_errno_mach_query_failures_and_bounded_values(self):
        operations, query, mapper = self.fragments()
        fixture = r'''
#include "IRJITDiagnostic.h"
#include <mach/mach.h>
#include <sys/mman.h>
#include <cassert>
#include <cstdio>
#include <cstdint>
#include <climits>
constexpr size_t page = 16384;
struct Arena { uint8_t *rx = nullptr, *rw = nullptr; size_t bytes = page; };
static int fault, queries, protections, rights, remaps;
static vm_size_t fakePage = page;
static IRJITDiagnosticStage recordedStage;
static uint32_t recordedPass;
static int64_t recordedValue;
static int recordedError;
static unsigned viewPhases;
static bool record(void *,IRJITDiagnosticStage s,uint32_t p,int64_t v,int e) {
    if(s==IR_JIT_ARENA_VIEW){viewPhases|=1u<<((p>>16)&255);assert(((uint64_t)v>>32)==7 || fault==4);}
    recordedStage=s;recordedPass=p;recordedValue=v;recordedError=e;errno=EINTR;return true;
}
static IRJITDiagnosticSink sink{nullptr,record};
static kern_return_t fixture_remap(vm_map_t,vm_address_t *a,vm_size_t,vm_address_t,int,
                                   vm_map_t,vm_address_t source,boolean_t copy,vm_prot_t *,vm_prot_t *,vm_inherit_t) {
    assert(queries>=2 && !copy);remaps++;
    *a=fault==9 ? source : 0xc00000000ULL;
    return fault==3 ? KERN_NO_SPACE : KERN_SUCCESS;
}
static kern_return_t fixture_protect(vm_map_t,vm_address_t address,vm_size_t,boolean_t maximum,vm_prot_t protection) {
    ++protections;
    assert(remaps==1 && address==0xc00000000ULL && !maximum && protection==(VM_PROT_READ|VM_PROT_WRITE));
    return fault==5 ? KERN_PROTECTION_FAILURE : KERN_SUCCESS;
}
static kern_return_t fixture_region(vm_map_t,vm_address_t *a,vm_size_t *extent,int,
                                    vm_region_info_t raw,mach_msg_type_number_t *count,mach_port_t *object) {
    ++queries;*object=42;*extent=page;
    auto *info=(vm_region_basic_info_data_64_t *)raw;
    bool rx=*a==0x400000000ULL;
    info->protection=rx || protections==0 ? VM_PROT_READ|VM_PROT_EXECUTE : VM_PROT_READ|VM_PROT_WRITE;
    info->max_protection=fault==4 && rx ? 3:7;
    if(fault==4 && rx)info->protection=VM_PROT_READ;
    if(fault==6&&rx)return KERN_INVALID_ADDRESS;
    if(fault==7&&!rx)info->protection=VM_PROT_READ;
    if(fault==8)*count=VM_REGION_BASIC_INFO_COUNT_64-1;
    if(fault==10){*a-=page;*extent+=page;} // Coalesced containing region.
    if(fault==11)*a+=page; // Next region does not contain the pointer.
    if(fault==12)*extent=page-1;
    if(fault==13){*a=0;*extent=UINT64_MAX;} // Adversarial addition would overflow.
    return KERN_SUCCESS;
}
static kern_return_t fixture_right(vm_map_t,mach_port_t object){assert(object==42);rights++;return KERN_SUCCESS;}
#define vm_page_size fakePage
#define vm_remap fixture_remap
#define vm_protect fixture_protect
#define vm_region_64 fixture_region
#define mach_port_deallocate fixture_right
'''
        cases = r'''
static void reset(int value){fault=value;queries=protections=rights=viewPhases=remaps=0;recordedStage=(IRJITDiagnosticStage)0;fakePage=page;}
int main(){
    struct Failure {int mode,operation,error;};
    for(auto failure:{Failure{1,1,0},Failure{3,3,KERN_NO_SPACE},
                     Failure{4,6,0},Failure{5,5,KERN_PROTECTION_FAILURE},Failure{6,6,KERN_INVALID_ADDRESS},
                     Failure{7,7,0},Failure{8,6,0},Failure{9,9,0}}){
        reset(failure.mode);if(fault==1)fakePage=4096;Arena arena;arena.rx=(uint8_t *)0x400000000ULL;
        assert(!mapArena(arena,2,&sink));
        assert(recordedStage==IR_JIT_ARENA_ERROR&&recordedPass==((2u<<8)|failure.operation));
        assert(recordedError==failure.error&&recordedValue>=0&&recordedValue<=16384);
        assert(rights==queries); // Every returned object right is released, including rejected queries.
    }
    reset(0);Arena exact;exact.rx=(uint8_t *)0x400000000ULL;assert(mapArena(exact,1,&sink)&&rights==8&&viewPhases==22);
    reset(10);Arena coalesced;coalesced.rx=(uint8_t *)0x400000000ULL;assert(mapArena(coalesced,1,&sink)&&rights==8);
    for(int mode:{8,11,12}){reset(mode);protections=2;assert(!query((void *)0x400000000ULL,page,VM_PROT_READ|VM_PROT_EXECUTE,&sink,1,queryRX));assert(rights==(mode==12?2:1));}
    reset(13);assert(!query((void *)(UINT64_MAX-7),16,VM_PROT_READ|VM_PROT_EXECUTE,&sink,1,queryRX));
    assert(rights==0&&recordedValue==0); // Reject overflowing input before a kernel query.
    puts("PASS shipping mapper: helper RX verified before shared remap; only alias RW protection requested; page size, remap/protect Mach failures, downgraded RX, strict count/protection/coverage/overflow, alias identity and object-right cleanup; bounded numeric records");
}
'''
        self.run_fixture('#include <initializer_list>\n' + fixture + operations + query + mapper + cases)

    def test_bounded_span_walk_checks_every_reply_and_releases_every_right(self):
        operations, query, _ = self.fragments()
        fixture = r'''
#include "IRJITDiagnostic.h"
#include <mach/mach.h>
#include <cassert>
#include <cstdio>
#include <cstdint>
struct Arena { uint8_t *rx=nullptr,*rw=nullptr;size_t bytes=0; };
constexpr uintptr_t base=0x400000000ULL;constexpr size_t page=16384;
static int fault,calls,rights,marks,lastError;
static vm_prot_t wanted=VM_PROT_READ|VM_PROT_EXECUTE;
static bool record(void *,IRJITDiagnosticStage stage,uint32_t pass,int64_t value,int error){
    marks++;lastError=error;
    if(stage==IR_JIT_ARENA_ERROR){assert(pass==((1u<<8)|6));assert(value>=0&&value<64);}
    return true;
}
static IRJITDiagnosticSink sink{nullptr,record};
static kern_return_t fixture_region(vm_map_t,vm_address_t *address,vm_size_t *extent,int,
                                    vm_region_info_t raw,mach_msg_type_number_t *count,mach_port_t *object){
    calls++;*object=42;*extent=page;
    auto *info=(vm_region_basic_info_data_64_t *)raw;
    info->protection=wanted;info->max_protection=7;
    if((fault==1&&calls==2)||fault==10)info->protection=VM_PROT_READ;
    if(fault==14&&calls==2)info->protection=VM_PROT_READ|VM_PROT_WRITE|VM_PROT_EXECUTE;
    if(fault==2&&calls==2)*address+=page;
    if((fault==3&&calls==2)||fault==11)*count=VM_REGION_BASIC_INFO_COUNT_64-1;
    if(fault==4)*extent=0;
    if(fault==5)*extent=UINTPTR_MAX;
    if((fault==6&&calls==2)||fault==12)return KERN_PROTECTION_FAILURE;
    if(fault==7&&calls==2)*address-=page; // The reply ends at the cursor: no progress.
    if(fault==8)*extent=1; // An adversarial sequence must hit the strict bound.
    if(fault==9&&calls==3)return KERN_INVALID_ADDRESS; // Allocation ends early.
    if(fault==13){*address-=page;*extent=2*page;} // Containing coalesced prefixes.
    return KERN_SUCCESS;
}
static kern_return_t fixture_right(vm_map_t,mach_port_t object){assert(object==42);rights++;return KERN_SUCCESS;}
#define vm_region_64 fixture_region
#define mach_port_deallocate fixture_right
'''
        cases = r'''
static void reset(int value){fault=value;calls=rights=marks=lastError=0;wanted=VM_PROT_READ|VM_PROT_EXECUTE;}
static bool check(size_t bytes=3*page){return query((void *)base,bytes,wanted,&sink,1,queryRX);}
int main(){
    reset(0);assert(check()&&calls==3&&rights==3&&marks==0);
    reset(0);assert(check(1024*page)&&calls==1024&&rights==1024&&marks==0);
    reset(0);assert(!check(1025*page)&&calls==1024&&rights==1024&&marks==2);
    reset(0);assert(check(2*page+1)&&calls==3&&rights==3);
    reset(0);wanted=VM_PROT_READ|VM_PROT_WRITE;assert(check()&&calls==3&&rights==3);
    reset(13);assert(check()&&calls==3&&rights==3);
    for(int mode=1;mode<=14;mode++){
        if(mode==13)continue;
        reset(mode);assert(!check());
        int expected=mode==8?1024:mode==9?3:(mode==1||mode==2||mode==3||mode==6||mode==7||mode==14)?2:1;
        assert(calls==expected&&rights==calls&&marks==2);
        assert(lastError==((mode==6||mode==12)?KERN_PROTECTION_FAILURE:mode==9?KERN_INVALID_ADDRESS:0));
    }
    reset(0);assert(!query((void *)(UINTPTR_MAX-7),16,wanted,&sink,1,queryRX));
    assert(calls==0&&rights==0&&marks==1);
    reset(0);assert(!query(nullptr,page,wanted,&sink,1,queryRX)&&calls==0);
    reset(0);assert(!check(0)&&calls==0);
    puts("PASS bounded span walk: complete RX/RW and containing prefixes; later permission/RWX mismatch, hole, short count, zero extent/progress, region/request overflow, short allocation, kernel errors and 1024-query cap; every object right released, at most two failure records");
}
'''
        self.run_fixture(fixture + operations + query + cases)

    def test_real_owned_adjacent_mapping_coalescence_is_accepted(self):
        operations, query, _ = self.fragments()
        fixture = r'''
#include "IRJITDiagnostic.h"
#include <mach/mach.h>
#include <sys/mman.h>
#include <unistd.h>
#include <cassert>
#include <cstdio>
#include <cstdint>
struct Arena { uint8_t *rx=nullptr,*rw=nullptr;size_t bytes=0; };
'''
        cases = r'''
int main(){
    size_t page=(size_t)sysconf(_SC_PAGESIZE);
    void *reservation=mmap(nullptr,2*page,PROT_NONE,MAP_PRIVATE|MAP_ANON,-1,0);assert(reservation!=MAP_FAILED);
    auto *second=(uint8_t *)reservation+page;
    assert(mmap(reservation,page,PROT_READ|PROT_WRITE,MAP_FIXED|MAP_PRIVATE|MAP_ANON,-1,0)==reservation);
    assert(mmap(second,page,PROT_READ|PROT_WRITE,MAP_FIXED|MAP_PRIVATE|MAP_ANON,-1,0)==second);
    vm_address_t address=(vm_address_t)second;vm_size_t extent=0;vm_region_basic_info_data_64_t info{};
    mach_msg_type_number_t count=VM_REGION_BASIC_INFO_COUNT_64;mach_port_t object=MACH_PORT_NULL;
    assert(vm_region_64(mach_task_self(),&address,&extent,VM_REGION_BASIC_INFO_64,(vm_region_info_t)&info,&count,&object)==KERN_SUCCESS);
    if(object!=MACH_PORT_NULL)mach_port_deallocate(mach_task_self(),object);
    assert(address<(vm_address_t)second); // Original exact-start predicate rejected this owned range.
    assert(query(second,page,VM_PROT_READ|VM_PROT_WRITE));
    assert(munmap(reservation,2*page)==0);
    puts("PASS actual Mach region coalescence: original exact-start predicate rejects, shipping full-range proof accepts own adjacent RW mapping; no executable memory or debugger used");
}
'''
        self.run_fixture(fixture + operations + query + cases)

    def test_real_owned_split_mapping_requires_complete_correct_coverage(self):
        operations, query, _ = self.fragments()
        fixture = r'''
#include "IRJITDiagnostic.h"
#include <mach/mach.h>
#include <sys/mman.h>
#include <unistd.h>
#include <cassert>
#include <cstdio>
#include <cstdint>
struct Arena { uint8_t *rx=nullptr,*rw=nullptr;size_t bytes=0; };
'''
        cases = r'''
int main(){
    const size_t page=(size_t)sysconf(_SC_PAGESIZE), bytes=3*page;
    auto *owned=(uint8_t *)mmap(nullptr,bytes,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANON,-1,0);
    assert(owned!=MAP_FAILED);
    // Inheritance splits this owned mapping without changing any access right.
    assert(vm_inherit(mach_task_self(),(vm_address_t)(owned+page),page,VM_INHERIT_NONE)==KERN_SUCCESS);
    for(size_t i=0;i<3;i++){
        owned[i*page]=(uint8_t)(i+1);
        vm_address_t address=(vm_address_t)(owned+i*page);vm_size_t extent=0;
        vm_region_basic_info_data_64_t info{};mach_msg_type_number_t count=VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t object=MACH_PORT_NULL;
        assert(vm_region_64(mach_task_self(),&address,&extent,VM_REGION_BASIC_INFO_64,
               (vm_region_info_t)&info,&count,&object)==KERN_SUCCESS);
        if(object!=MACH_PORT_NULL)mach_port_deallocate(mach_task_self(),object);
        assert(count==VM_REGION_BASIC_INFO_COUNT_64 && address<=(vm_address_t)(owned+i*page));
        assert(info.protection==(VM_PROT_READ|VM_PROT_WRITE));
        assert(extent>=page && (vm_address_t)(owned+i*page)-address<=extent-page);
        if(i==0)assert(extent-(vm_address_t(owned)-address)<bytes);
    }
    bool accepted=query(owned,bytes,VM_PROT_READ|VM_PROT_WRITE);
    fprintf(stderr,"real owned split mapping: all three pages RW; full-range query accepted=%d\n",accepted);
    assert(accepted && "valid owned split mappings require a complete region walk");
    assert(mprotect(owned+page,page,PROT_READ)==0);
    assert(!query(owned,bytes,VM_PROT_READ|VM_PROT_WRITE));
    assert(mprotect(owned+page,page,PROT_READ|PROT_WRITE)==0);
    assert(query(owned,bytes,VM_PROT_READ|VM_PROT_WRITE));
    assert(munmap(owned+page,page)==0);
    assert(!query(owned,bytes,VM_PROT_READ|VM_PROT_WRITE));
    assert(munmap(owned,page)==0 && munmap(owned+2*page,page)==0);
    puts("PASS actual owned split mapping: complete RW span accepted; later permission mismatch and real hole rejected; no executable memory or debugger used");
}
'''
        self.run_fixture(fixture + operations + query + cases)


if __name__ == '__main__': unittest.main()
