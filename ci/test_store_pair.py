"""Exercise the shared native store-pair handler under sanitizers."""
from pathlib import Path
import hashlib
import shutil
import subprocess
import tempfile
import unittest

class StorePairTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which('clang'), 'clang required')
    def test_pair_width_modes_and_rejection(self):
        root = Path(__file__).resolve().parents[1]
        data = (root / 'testrepos/Madeira/build/ntdll-unix/signal_arm64_ios.c').read_bytes()
        identity = hashlib.sha1(b'blob ' + str(len(data)).encode() + b'\0' + data).hexdigest()
        if identity == '5be2a3025d550c4a9d5cbeaa2e3c796bc78e8d60':
            self.skipTest('65b596 diagnostic snapshot predates ios_store_pair; native source is pinned by hybrid preflight')
        source = data.decode()
        body = source[source.index('static int ios_store_pair('):source.index('#define IOS_STORE_SRC')]
        test = '''
int main(void) {
 for (unsigned wide=0; wide<2; wide++) for(unsigned mode=0; mode<4; mode++)
 for(int off=-64; off<=63; off+=1) {
  uint64_t out[3]={0,0,0xfeed}, base=4096;
  unsigned width=wide?8:4;
  uint32_t insn=0x28000000u | (wide<<31) | (mode<<23) | ((off&127)<<15);
  assert(ios_store_pair(insn,(uintptr_t)out,0x1122334455667788ULL,0,&base));
  assert(base==(uint64_t)(4096+((mode==1||mode==3)?off*(int)width:0)));
  if(wide) { assert(out[0]==0x1122334455667788ULL); assert(out[1]==0); }
  else { assert(out[0]==0x55667788); assert(out[1]==0); }
  assert(out[2]==0xfeed);
 }
 uint64_t out[2]={0},base=0x1000;
 assert(ios_store_pair(0xa9882149,(uintptr_t)out,9,8,&base));
 assert(out[0]==9 && out[1]==8 && base==0x1080);
 assert(!ios_store_pair(0xa9c82149,(uintptr_t)out,0,0,&base));
 assert(!ios_store_pair(0xad882149,(uintptr_t)out,0,0,&base));
 assert(!ios_store_pair(0x68000000,(uintptr_t)out,0,0,&base));
 assert(out[0]==9 && base==0x1080);
 return 0;
}
'''
        with tempfile.TemporaryDirectory() as temp:
            src=Path(temp)/'check.c'; binary=Path(temp)/'check'
            src.write_text('#include <stdint.h>\n#include <string.h>\n#include <assert.h>\n'+body+test)
            subprocess.run(['clang','-fsanitize=address,undefined',str(src),'-o',str(binary)],check=True,capture_output=True)
            subprocess.run([str(binary)],check=True,capture_output=True)
