import importlib.util
from pathlib import Path
import unittest

PACKAGER_PATH = Path(__file__).with_name("package-unsigned-ipa.py")
spec = importlib.util.spec_from_file_location("unsigned_packager_marker_tests", PACKAGER_PATH)
packager = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packager)

PRIVATE_KEY_BEGIN = b"-----BEGIN " + b"PRIVATE KEY-----"
PRIVATE_KEY_END = b"-----END " + b"PRIVATE KEY-----"


class PrivateKeyMarkerTests(unittest.TestCase):
    def test_nul_terminated_parser_marker_is_allowed(self):
        data = b"prefix" + PRIVATE_KEY_BEGIN + b"\x00suffix"
        self.assertFalse(packager.has_private_key_material(data))

    def test_newline_terminated_parser_marker_without_key_body_is_allowed(self):
        data = b"prefix" + PRIVATE_KEY_BEGIN + b"\nError parsing private key\x00suffix"
        self.assertFalse(packager.has_private_key_material(data))

    def test_complete_private_key_pem_is_rejected(self):
        body = b"A" * 64 + b"\n" + b"B" * 64 + b"\n"
        data = PRIVATE_KEY_BEGIN + b"\n" + body + PRIVATE_KEY_END + b"\n"
        self.assertTrue(packager.has_private_key_material(data))

    def test_encrypted_private_key_pem_is_rejected(self):
        body = b"Proc-Type: 4,ENCRYPTED\nDEK-Info: AES-256-CBC,0123456789ABCDEF\n\n" + b"C" * 96 + b"\n"
        data = PRIVATE_KEY_BEGIN + b"\n" + body + PRIVATE_KEY_END + b"\n"
        self.assertTrue(packager.has_private_key_material(data))

    def test_truncated_private_key_with_substantial_payload_is_rejected(self):
        data = PRIVATE_KEY_BEGIN + b"\n" + b"D" * 160 + b"\n"
        self.assertTrue(packager.has_private_key_material(data))

    def test_mixed_parser_marker_and_real_pem_is_rejected(self):
        parser = PRIVATE_KEY_BEGIN + b"\nparser-only diagnostic\x00"
        body = b"E" * 80 + b"\n"
        pem = PRIVATE_KEY_BEGIN + b"\n" + body + PRIVATE_KEY_END
        self.assertTrue(packager.has_private_key_material(parser + pem))

    def test_marker_at_eof_is_allowed(self):
        self.assertFalse(packager.has_private_key_material(b"prefix" + PRIVATE_KEY_BEGIN))


if __name__ == "__main__":
    unittest.main()
