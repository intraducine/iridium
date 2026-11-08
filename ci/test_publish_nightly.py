import base64
import importlib.util
import hashlib
import json
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch
from urllib.error import HTTPError
import zipfile

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("nightly", ROOT / "ci/publish-nightly.py")
NIGHTLY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(NIGHTLY)
DISPATCH_SPEC = importlib.util.spec_from_file_location("dispatch", ROOT / "ci/dispatch-build.py")
DISPATCH = importlib.util.module_from_spec(DISPATCH_SPEC)
DISPATCH_SPEC.loader.exec_module(DISPATCH)


class NightlyTests(unittest.TestCase):
    def setUp(self):
        self.revision = "a" * 40
        self.env = {"GITHUB_REPOSITORY": NIGHTLY.REPO, "GITHUB_REF": "refs/heads/main",
                    "GITHUB_SHA": self.revision, "GITHUB_RUN_NUMBER": "199", "GITHUB_RUN_ATTEMPT": "2",
                    "NIGHTLY_IPA_ID": "42", "NIGHTLY_SOURCE_ID": "43", "GH_TOKEN": "test"}
        self.temp = self.enterContext(tempfile.TemporaryDirectory())
        self.ipa = Path(self.temp) / "test.ipa"
        self.info = {"CFBundleIdentifier": "software.iridium", "CFBundleVersion": "199.2",
                     "CFBundleShortVersionString": "0.3.0", "MinimumOSVersion": "18.0",
                     "IridiumRootRevision": self.revision, "IridiumSourceState": "Committed source",
                     "NSMicrophoneUsageDescription": "Microphone"}
        self.write_ipa()

    def write_ipa(self):
        with zipfile.ZipFile(self.ipa, "w") as archive:
            archive.writestr(NIGHTLY.APP + "Info.plist", plistlib.dumps(self.info))
        self.env["NIGHTLY_IPA_DIGEST"] = hashlib.sha256(self.ipa.read_bytes()).hexdigest()

    def test_feed_uses_exact_ipa_and_source_artifacts(self):
        result = NIGHTLY.prepare(self.ipa, self.env)
        app = result["apps"][0]
        entry = app["versions"][0]
        self.assertEqual(entry["buildVersion"], "199.2")
        self.assertTrue(entry["downloadURL"].endswith("/actions/artifacts/42.zip"))
        self.assertIn("/actions/artifacts/43.zip", app["localizedDescription"])
        self.assertEqual(entry["size"], self.ipa.stat().st_size)
        self.assertEqual(app["appPermissions"]["privacy"], {"NSMicrophoneUsageDescription": "Microphone"})

    def test_prepare_rejects_wrong_branch_and_revision(self):
        with patch.dict(self.env, GITHUB_REF="refs/heads/topic"):
            with self.assertRaisesRegex(ValueError, "main branch"):
                NIGHTLY.prepare(self.ipa, self.env)
        self.info["IridiumRootRevision"] = "b" * 40
        self.write_ipa()
        with self.assertRaisesRegex(ValueError, "does not match"):
            NIGHTLY.prepare(self.ipa, self.env)

    def test_prepare_rejects_changed_artifact(self):
        self.env["NIGHTLY_IPA_DIGEST"] = "0" * 64
        with self.assertRaisesRegex(ValueError, "differs from the checked IPA"):
            NIGHTLY.prepare(self.ipa, self.env)

    def test_publication_never_replaces_a_newer_build(self):
        proposed = NIGHTLY.prepare(self.ipa, self.env)
        current = json.loads(json.dumps(proposed))
        current["apps"][0]["versions"][0]["buildVersion"] = "200.1"
        response = {"sha": "file-sha", "content": base64.b64encode(json.dumps(current).encode()).decode()}
        with patch.object(NIGHTLY, "api", side_effect=[{}, response]) as api:
            NIGHTLY.publish(proposed, self.env)
        self.assertEqual(api.call_count, 2)

    def test_publication_updates_the_feed_branch(self):
        proposed = NIGHTLY.prepare(self.ipa, self.env)
        current = json.loads(json.dumps(proposed))
        current["apps"][0]["versions"][0]["buildVersion"] = "198.1"
        response = {"sha": "file-sha", "content": base64.b64encode(json.dumps(current).encode()).decode()}
        with patch.object(NIGHTLY, "api", side_effect=[{}, response, {}]) as api:
            NIGHTLY.publish(proposed, self.env)
        method, path, token, payload = api.call_args.args
        self.assertEqual((method, path, token), ("PUT", "contents/altstore/nightly.json", "test"))
        self.assertEqual(payload["branch"], "altstore-nightly")
        self.assertEqual(json.loads(base64.b64decode(payload["content"])), proposed)

    def test_first_publication_creates_the_feed_branch(self):
        proposed = NIGHTLY.prepare(self.ipa, self.env)
        missing = HTTPError("https://api.github.com", 404, "missing", {}, None)
        with patch.object(NIGHTLY, "api", side_effect=[missing, {}, missing, {}]) as api:
            NIGHTLY.publish(proposed, self.env)
        self.assertEqual(api.call_args_list[1].args[1], "git/refs")
        self.assertEqual(api.call_args_list[1].args[3]["sha"], self.revision)
        self.assertEqual(api.call_args_list[3].args[1], "contents/altstore/nightly.json")

    def test_workflow_keeps_direct_artifacts_and_source_in_same_run(self):
        workflow = (ROOT / ".github/workflows/build-unsigned-ipa.yml").read_text()
        self.assertIn("archive: false", workflow)
        self.assertIn("NIGHTLY_SOURCE_ID: ${{ steps.source_artifact.outputs.artifact-id }}", workflow)
        self.assertIn("NIGHTLY_IPA_ID: ${{ steps.nightly_ipa.outputs.artifact-id }}", workflow)
        self.assertIn("needs: build", workflow)

    def test_dispatch_rejects_a_non_main_nightly(self):
        with patch.object(DISPATCH, "gh") as gh:
            with self.assertRaisesRegex(ValueError, "require main"):
                DISPATCH.dispatch("codex/topic", self.revision, nightly=True)
        gh.assert_not_called()
