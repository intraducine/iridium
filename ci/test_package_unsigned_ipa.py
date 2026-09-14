import importlib.util
from pathlib import Path
import unittest

PACKAGER_PATH = Path(__file__).with_name("package-unsigned-ipa.py")
spec = importlib.util.spec_from_file_location("unsigned_packager_marker_tests", PACKAGER_PATH)
packager = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packager)

PRIVATE_KEY_MARKER = b"-----BEGIN " + b"PRIVATE KEY-----"


class PrivateKeyMarkerTests(unittest.TestCase):
    def test_nul_terminated_parser_marker_is_allowed(self):
        data = b"prefix" + PRIVATE_KEY_MARKER + b"\x00suffix"
        self.assertFalse(packager.has_unsafe_private_key_marker(data))

    def test_pem_marker_followed_by_newline_is_rejected(self):
        data = b"prefix" + PRIVATE_KEY_MARKER + b"\npayload"
        self.assertTrue(packager.has_unsafe_private_key_marker(data))

    def test_mixed_safe_and_unsafe_markers_is_rejected(self):
        data = PRIVATE_KEY_MARKER + b"\x00parser" + PRIVATE_KEY_MARKER + b"\r\nbody"
        self.assertTrue(packager.has_unsafe_private_key_marker(data))

    def test_marker_at_eof_is_rejected(self):
        self.assertTrue(packager.has_unsafe_private_key_marker(b"prefix" + PRIVATE_KEY_MARKER))


if __name__ == "__main__":
    unittest.main()
