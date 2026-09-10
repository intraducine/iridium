#!/usr/bin/env python3
"""Run the production URL wrapper on the host and check lossless forwarding."""
from pathlib import Path
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'app/Madeira/StikJITHelper.swift').read_text()
match = re.search(r'    static func liveContainerURL\(for url: URL\) -> URL\? \{.*?\n    \}', source, re.S)
assert match, 'Production URL wrapper missing'
function = match.group().replace('static func', 'func', 1)
check = r'''
for value in ["stikjit://enable-jit?bundle-id=com.vibu.madeira&script-data=ab+/==", "stikjit://enable-jit?pid=123&script-data=%2B%2F%3D"] {
    let input = URL(string: value)!
    let output = liveContainerURL(for: input)!
    let components = URLComponents(url: output, resolvingAgainstBaseURL: false)!
    assert(components.scheme == "livecontainer2" && components.host == "open-url")
    let decoded = Data(base64Encoded: components.queryItems!.first!.value!)!
    assert(String(data: decoded, encoding: .utf8) == input.absoluteString)
}
print("LiveContainer URL forwarding: passed")
'''
with tempfile.TemporaryDirectory() as directory:
    path = Path(directory) / 'check.swift'
    path.write_text('import Foundation\n' + function + '\n' + check)
    subprocess.run(['xcrun', 'swift', str(path)], check=True)
