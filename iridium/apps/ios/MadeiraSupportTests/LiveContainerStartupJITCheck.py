#!/usr/bin/env python3
"""Protect the hosted LiveContainer JIT launch policy used by Madeira games."""
from pathlib import Path

root = Path(__file__).resolve().parents[1]
source = (root / "Iridium/LiveContainerIntegration.swift").read_text()

# The real hosted repair must arrange JIT before Iridium guest code starts.
repair_current = source[source.index("static func repairCurrentProcessConfiguration"):source.index("@discardableResult\n    static func repair(", source.index("static func repairCurrentProcessConfiguration"))]
assert "launchWithJIT: true" in repair_current

# Keep the lower-level helper reusable/backward-compatible, but write the
# caller-selected policy rather than hardcoding the late-attach path again.
repair = source[source.index("static func repair(\n"):]
assert "launchWithJIT: Bool = false" in repair
assert 'configuration["isJITNeeded"] = launchWithJIT' in repair
assert 'configuration["isJITNeeded"] = false' not in repair

# A saved launch-policy change requires a relaunch before it can be treated as
# active, and a startup-JIT process can be identified as StikDebug-backed.
assert "launchStatus.launchWithJITEnabled == launchWithJITEnabled" in source
assert "guard status.isHosted, status.jitConfigured" in source
assert "filePickerConfigured && jitScriptMatches && usesLiveContainerBundleID" in source

print("PASS hosted LiveContainer repair enables startup JIT without game-specific policy")
