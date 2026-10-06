#!/usr/bin/env python3
"""Run the production controller bridge with deterministic platform snapshots."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / "MadeiraSupport/MadeiraController.swift").read_text()
with tempfile.TemporaryDirectory(prefix="iridium-controller-routing-") as directory:
    source_path = Path(directory) / "MadeiraController.swift"
    source_path.write_text(source.replace("import GameController\n", "").replace("import UIKit\n", ""))
    binary = Path(directory) / "check"
    subprocess.run(["xcrun", "swiftc", "-swift-version", "5",
                    str(root / "Iridium/Input/PhysicalControllerMapping.swift"),
                    str(root / "MadeiraSupport/MadeiraControllerMappingState.swift"),
                    str(source_path), str(root / "MadeiraSupportTests/ControllerRoutingCheck.swift"),
                    "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
