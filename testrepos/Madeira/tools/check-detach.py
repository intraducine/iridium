#!/usr/bin/env python3
"""Check that cleanup cannot issue a second debugger breakpoint after detach."""
from pathlib import Path
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'app/Madeira/StikJITHelper.swift').read_text()
match = re.search(r'    static func detachDebugger\(\) \{.*?\n    \}', source, re.S)
assert match
stub = '''
import Foundation
var detachCount = 0
func jit26_detach() { detachCount += 1 }
struct LogStore {
    static let shared = LogStore()
    enum Level { case success }
    func log(_ message: String, level: Level = .success) {}
}
'''
check = '''
unsetenv("MADEIRA_DETACHED")
detachDebugger()
detachDebugger()
assert(detachCount == 1)
assert(String(cString: getenv("MADEIRA_DETACHED")!) == "1")
print("Repeated detach: passed")
'''
with tempfile.TemporaryDirectory() as directory:
    path = Path(directory) / 'check.swift'
    path.write_text(stub + match.group().replace('static func', 'func', 1) + check)
    subprocess.run(['xcrun', 'swift', str(path)], check=True)
