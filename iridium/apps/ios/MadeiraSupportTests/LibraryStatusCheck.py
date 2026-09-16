#!/usr/bin/env python3
from pathlib import Path

root = Path(__file__).resolve().parents[1]
source = (root / "Iridium/Views/LibraryView.swift").read_text()

assert "isShowingLiveContainerRelaunchRequired" in source
assert '.alert("Restart Iridium"' in source
assert "launchStatus.launchWithJITEnabled != liveContainerStatus.launchWithJITEnabled" in source
assert "liveContainerIntegrationMessage = nil" in source
assert "liveContainerStatus.setupFeedback(" not in source
assert "if liveContainerRepairRequiresRelaunch {" in source
assert "isShowingLiveContainerRelaunchRequired = true" in source

print("Library LiveContainer status UI: transient relaunch guidance verified")
