"""Check FEX's host CPU index against the guest CPU table."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class CPUIndexTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which('c++'), 'C++ compiler required')
    def test_host_core_numbers_stay_in_the_guest_table(self):
        source = (ROOT / 'testrepos/Madeira/FEX/FEXCore/Source/Interface/Core/CPUID.h').read_text()
        start = source.index('  uint32_t WrapCPUIndex(')
        end = source.index('\n  // Functions', start)
        program = '''
#include <cassert>
#include <cstdint>
#include <cstddef>
#include <vector>
struct Probe {
  std::vector<int> PerCPUData;
  uint32_t cpu;
  uint32_t GetCPUID() const { return cpu; }
''' + source[start:end] + '''
};
int main() {
  Probe p;
  for (size_t size : {0, 1, 6, 8, 64}) {
    p.PerCPUData.resize(size);
    for (uint32_t cpu : {0U, 1U, 5U, 8U, 63U, UINT32_MAX}) {
      p.cpu = cpu;
      assert(p.CurrentCPUIndex() == (size <= 1 ? 0 : cpu % size));
    }
  }
}
'''
        with tempfile.TemporaryDirectory() as temp:
            binary = str(Path(temp) / 'cpuid')
            subprocess.run(['c++', '-std=c++20', '-x', 'c++', '-', '-o', binary],
                           input=program, text=True, capture_output=True, check=True)
            subprocess.run([binary], capture_output=True, check=True, timeout=5)
