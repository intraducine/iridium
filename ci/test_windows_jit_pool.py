"""Reuse complete Windows image layouts without reusing live code or losing execute access."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import madeira_threads

ROOT = Path(__file__).resolve().parents[1]
HEADER = ROOT / 'iridium/apps/ios/RuntimeBridge/IRWindowsJITPool.h'


class WindowsJITPoolTests(unittest.TestCase):
    def test_native_allocation_retirement_and_source_changes(self):
        original = (ROOT / 'vendor/Madeira/build/ntdll-unix/virtual_ios.c').read_text()
        source = madeira_threads.apply_virtual(original)
        self.assertIn(str(HEADER), source)
        self.assertEqual(source.count('ios_pool_alloc_image(image_base, image_size, alloc_size,'), 2)
        self.assertIn('ir_windows_image_note(off, alloc_size, ios_jit_current_peb(), ir_windows_session_epoch())', source)
        retirement = source[source.index('void ios_jit_reclaim_process('):source.index('static void clear_arm64ec_range( const void *addr, size_t size )\n{')]
        self.assertLess(retirement.index('clear_arm64ec_range('), retirement.index('ir_windows_image_retire('))
        self.assertLess(retirement.index('ir_windows_image_retire('), retirement.index('ios_pool_free_put('))
        self.assertIn('ir_windows_image_accessible, ir_windows_image_live', source)
        for changed in [original.replace('static size_t ios_pool_alloc_range_ex(', 'static size_t other_pool(', 1),
                        original.replace('            /* ios_image_reload_mode:', '            /* changed_image_reload_mode:', 1)]:
            with self.assertRaises(ValueError): madeira_threads.apply_virtual(changed)

    @unittest.skipUnless(shutil.which('cc'), 'C compiler required')
    def test_repeated_images_keep_data_holes_and_reject_unsafe_reuse(self):
        fixture = r'''
#include <assert.h>
#include <stdio.h>
#include "IRWindowsJITPool.h"
static unsigned char pe[0x14000];
static unsigned rights[256];
static bool query_failed,live;
static void put(size_t at,uint32_t value,size_t n){for(size_t i=0;i<n;i++)pe[at+i]=(value>>(8*i))&255;}
static bool access_range(size_t off,size_t size,bool writable){
 if(query_failed || off>sizeof(rights)/sizeof(*rights)*0x4000 || size>sizeof(rights)/sizeof(*rights)*0x4000-off)return false;
 for(size_t p=off/0x4000;p<(off+size+0x3fff)/0x4000;p++)
  if(writable?rights[p]!=3:!(rights[p]&4))return false;
 return true;
}
static bool overlap(size_t off,size_t size){(void)off;(void)size;return live;}
int main(void){
 put(0,0x5a4d,2);put(0x3c,0x80,4);put(0x80,0x4550,4);
 put(0x86,3,2);put(0x94,0xf0,2);put(0x98,0x20b,2);put(0x98+56,sizeof(pe),4);
 size_t sections=0x188;
 put(sections+8,0x7000,4);put(sections+12,0x1000,4);put(sections+36,0x60000020,4);
 put(sections+40+8,0x4000,4);put(sections+40+12,0x8000,4);put(sections+40+36,0xc0000040,4);
 put(sections+80+8,0x8000,4);put(sections+80+12,0xc000,4);put(sections+80+36,0x40000040,4);
 struct ir_windows_image_request request={pe,sizeof(pe),0,0x4000};
 const size_t off=0x40000,capacity=0x18000,limit=0x200000;
 for(size_t i=0;i<sizeof(rights)/sizeof(*rights);i++)rights[i]=5;
 rights[(off+0x8000)/0x4000]=3;
 assert(ir_windows_image_fits(&request,off,capacity,access_range));
 ir_windows_image_note(off,capacity,(void*)1,1);
 uint64_t epoch=1;
 for(unsigned i=0;i<500;i++){
  size_t wanted=capacity;
  assert(ir_windows_image_take(&request,limit,&wanted,epoch+1,access_range,overlap)==SIZE_MAX);
  assert(!ir_windows_image_retire(off,capacity,(void*)2));
  assert(ir_windows_image_retire(off,capacity,(void*)1));
  assert(!ir_windows_image_retire(off,capacity,(void*)1));
  assert(ir_windows_image_take(&request,limit,&wanted,epoch,access_range,overlap)==SIZE_MAX);
  live=true;assert(ir_windows_image_take(&request,limit,&wanted,epoch+1,access_range,overlap)==SIZE_MAX);live=false;
  assert(ir_windows_image_take(&request,limit,&wanted,++epoch,access_range,overlap)==off && wanted==capacity);
  ir_windows_image_note(off,capacity,(void*)1,epoch);
 }
 assert(!ir_windows_image_slots->next); /* No growing cache per launch. */
 assert(ir_windows_image_retire(off,capacity,(void*)1));
 size_t wanted=capacity;
 query_failed=true;assert(ir_windows_image_take(&request,limit,&wanted,epoch+1,access_range,overlap)==SIZE_MAX);query_failed=false;
 assert(ir_windows_image_take(&request,off+capacity-1,&wanted,epoch+1,access_range,overlap)==SIZE_MAX);
 wanted=capacity+0x4000;assert(ir_windows_image_take(&request,limit,&wanted,epoch+1,access_range,overlap)==SIZE_MAX);
 put(sections+12,0x8000,4);assert(!ir_windows_image_fits(&request,off,capacity,access_range));put(sections+12,0x1000,4);
 put(sections+40+12,0x4000,4);assert(!ir_windows_image_fits(&request,off,capacity,access_range));put(sections+40+12,0x8000,4);
 rights[(off+0x14000)/0x4000]=3;assert(!ir_windows_image_fits(&request,off,capacity,access_range));rights[(off+0x14000)/0x4000]=5;
 put(0x3c,UINT32_MAX,4);assert(!ir_windows_image_fits(&request,off,capacity,access_range));put(0x3c,0x80,4);
 put(0x86,97,2);assert(!ir_windows_image_fits(&request,off,capacity,access_range));put(0x86,3,2);
 put(sections+8,UINT32_MAX,4);assert(!ir_windows_image_fits(&request,off,capacity,access_range));put(sections+8,0x7000,4);
 request.size=63;assert(!ir_windows_image_fits(&request,off,capacity,access_range));request.size=sizeof(pe);
 request.delta=1;assert(!ir_windows_image_fits(&request,off,capacity,access_range));request.delta=0;
 assert(!ir_windows_image_fits(&request,SIZE_MAX-1,capacity,access_range));
 assert(ir_windows_image_fits(&request,off,capacity,access_range));
 /* A 4 KB PE section can need a 12 KB shift to fit the host's 16 KB pages. */
 request.delta=0x3000;request.size=0xd000;put(0x98+56,request.size,4);
 put(sections+8,0x4000,4);put(sections+40+12,0x5000,4);
 put(sections+80+12,0x9000,4);put(sections+80+8,0x4000,4);
 assert(ir_windows_image_fits(&request,off,capacity,access_range));
 request.trampolines=SIZE_MAX;assert(!ir_windows_image_fits(&request,off,capacity,access_range));
 request.trampolines=0x4000;wanted=capacity;
 assert(ir_windows_image_take(&request,limit,&wanted,epoch+1,access_range,overlap)==off);
 /* Reserving a slot must work even when the caller cannot append its ledger entry. */
 assert(ir_windows_image_take(&request,limit,&wanted,epoch+1,access_range,overlap)==SIZE_MAX);
 free(ir_windows_image_slots);
 return 0;
}
'''
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / 'pool.c'
            binary = Path(directory) / 'pool'
            source.write_text(fixture)
            subprocess.run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', '-fsanitize=address,undefined',
                            '-I', str(HEADER.parent), str(source), '-o', str(binary)], check=True)
            subprocess.run([str(binary)], check=True, timeout=15)
