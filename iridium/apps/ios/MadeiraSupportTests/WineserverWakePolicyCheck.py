from pathlib import Path

root = Path(__file__).resolve().parents[1]
source = (root / "MadeiraSupport" / "MadeiraRuntimeAdapter.swift").read_text()

policy = 'setenv("MADEIRA_SRV_NOSEM", "1", 0)'
start = 'guard wineserver_start(prefix.path) == 0 else {'

assert source.count(policy) == 1, "expected one default wineserver wake policy"
assert start in source, "wineserver startup call not found"
assert source.index(policy) < source.index(start), "wake policy must be set before wineserver startup"

print("PASS: iOS wineserver defaults to non-semaphore wake path before startup")
