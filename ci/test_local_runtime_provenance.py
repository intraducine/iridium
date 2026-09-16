import importlib.util
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "local_runtime_provenance", ROOT / "ci/check-local-runtime-provenance.py"
)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class LocalRuntimeProvenanceTests(unittest.TestCase):
    def test_parses_ci_runtime_producer(self):
        self.assertEqual(MODULE.producer_from_version("ci-54daddedca86"), "54daddedca86")
        with self.assertRaises(ValueError):
            MODULE.producer_from_version("0.0.0-imported")

    def test_native_contract_includes_fex_handoff_and_app_bridge(self):
        reuse = MODULE.load_reuse()
        paths = set(MODULE.native_contract_inputs(reuse))
        self.assertIn("ci/patches/rpmalloc-host-arena.patch", paths)
        self.assertIn("iridium/apps/ios/MadeiraSupport/NativePool.c", paths)
        self.assertIn("testrepos/Madeira/app/Madeira/Winios/Winios.m", paths)
        self.assertIn("testrepos/Madeira/FEX", paths)
        self.assertIn("testrepos/Madeira/wine", paths)


if __name__ == "__main__":
    unittest.main()
