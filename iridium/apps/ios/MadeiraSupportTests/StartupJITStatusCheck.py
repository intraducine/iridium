#!/usr/bin/env python3
from pathlib import Path

root = Path(__file__).resolve().parents[4]
helper = (root / "testrepos/Madeira/app/Madeira/StikJITHelper.swift").read_text()
view_model = (root / "iridium/apps/ios/Iridium/AppViewModel.swift").read_text()

assert "static var persistentScriptRequested: Bool" in helper
assert "if jit_check_debugged() { return true }" in helper
assert "CS_DEBUGGED is the" in helper
assert "if jit_check_debugged() && StikJITHelper.persistentScriptRequested" in view_model

print("Startup JIT status: CS_DEBUGGED is recognized without an in-app request marker")
