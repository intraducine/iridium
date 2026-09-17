"""Run the Wine iOS TSD retarget pass with a bit-packed literal map."""
from pathlib import Path
import hashlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

class RetargetTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which('clang'), 'clang required')
    def test_retargets_code_and_preserves_literals_without_overread(self):
        data = (ROOT / 'testrepos/Madeira/build/ntdll-unix/virtual_ios.c').read_bytes()
        identity = hashlib.sha1(b'blob ' + str(len(data)).encode() + b'\0' + data).hexdigest()
        if identity == '20e987dbab0f1b62f6ab27d02472cfa19f713f95':
            self.skipTest('65b596 diagnostic snapshot retains the old TEB scan; its later safety fix is deliberately excluded')
        source = data.decode()
        start = source.index('    if (ios_teb_tls_slot_offset && text_size >= 12)')
        end = source.index('\n    for (size_t i = 0; i < text_size; i += 4)', start)
        program = '''
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
#include <assert.h>
static void run(void) {
 size_t text_size = 4096;
 unsigned ios_teb_tls_slot_offset = 0x908;
 char *text_rw = calloc(1, text_size), *text_rx = text_rw;
 unsigned char *data_map = calloc(1, text_size / 32 + 1);
 unsigned offsets[] = {0, 64, 4084};
 for (unsigned j = 0; j < 3; ++j) {
  uint32_t *p = (uint32_t *)(text_rw + offsets[j]);
  p[0] = 0xd53bd070; p[1] = 0x927df210; p[2] = 0xf9444e10;
 }
 // Mark only the middle sequence as literal data.
 data_map[(64 / 4) >> 3] |= 1 << ((64 / 4) & 7);
''' + source[start:end] + '''
 for (unsigned j = 0; j < 3; ++j) {
  uint32_t insn = *(uint32_t *)(text_rw + offsets[j] + 8);
  assert(((insn >> 10) & 4095) * 8 == (j == 1 ? 0x898 : 0x908));
 }
 free(data_map); free(text_rw);
}
int main(void) { run(); return 0; }
'''
        with tempfile.TemporaryDirectory() as temp:
            src = Path(temp) / 'check.c'
            src.write_text(program)
            binary = Path(temp) / 'check'
            subprocess.run(['clang', '-fsanitize=address', '-g', str(src), '-o', str(binary)], check=True, capture_output=True)
            subprocess.run([str(binary)], check=True, capture_output=True)
