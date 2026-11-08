import base64
import importlib.util
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
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
                    "GITHUB_RUN_ID": "42", "GH_TOKEN": "test"}
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

    def test_feed_uses_exact_ipa_and_source_release(self):
        result = NIGHTLY.prepare(self.ipa, self.env)
        app = result["apps"][0]
        entry = app["versions"][0]
        self.assertEqual(entry["buildVersion"], "199.2")
        self.assertTrue(entry["downloadURL"].endswith("/nightly-42-2/Iridium-unsigned.ipa"))
        self.assertIn("/releases/tag/nightly-42-2", app["localizedDescription"])
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

    def test_release_uploads_and_verifies_each_asset_before_publish(self):
        feed = NIGHTLY.prepare(self.ipa, self.env)
        root = Path(self.temp) / "release"
        (root / "ipa").mkdir(parents=True)
        (root / "source").mkdir()
        shutil.copyfile(self.ipa, root / "ipa/Iridium-unsigned.ipa")
        archive = root / "source/Iridium-corresponding-source.tar.gz"
        archive.write_bytes(b"source")
        (root / "source/SOURCE-SHA256SUMS").write_text(hashlib.sha256(b"source").hexdigest() + "  " + archive.name + "\n")
        (root / "source/COMPONENT-MANIFEST.json").write_text("{}")
        record = {"id": 1, "tag_name": "nightly-42-2", "target_commitish": self.revision,
                  "draft": True, "prerelease": True, "assets": []}

        def call_api(method, path, token, data=None):
            if path.startswith("releases?"):
                return [record]
            if path.startswith("commits/"):
                return {"sha": self.revision}
            if method == "PATCH":
                record["draft"] = False
            return record

        def run(command, **kwargs):
            path = Path(command[command.index("--input") + 1])
            record["assets"].append({"name": path.name, "digest": "sha256:" + NIGHTLY.file_digest(path), "state": "uploaded"})

        with patch.object(NIGHTLY, "api", side_effect=call_api), patch.object(NIGHTLY.subprocess, "run", side_effect=run) as cli:
            NIGHTLY.release(feed, root, self.env)
        self.assertEqual(len(record["assets"]), 5)
        self.assertEqual(cli.call_count, 5)
        self.assertFalse(record["draft"])

    def test_release_rejects_ipa_changed_after_build(self):
        feed = NIGHTLY.prepare(self.ipa, self.env)
        root = Path(self.temp) / "release"
        (root / "ipa").mkdir(parents=True)
        (root / "ipa/Iridium-unsigned.ipa").write_bytes(b"changed")
        with self.assertRaisesRegex(ValueError, "does not match"):
            NIGHTLY.release(feed, root, self.env)

    def test_release_rejects_source_checksum_mismatch(self):
        feed = NIGHTLY.prepare(self.ipa, self.env)
        root = Path(self.temp) / "release"
        (root / "ipa").mkdir(parents=True)
        (root / "source").mkdir()
        shutil.copyfile(self.ipa, root / "ipa/Iridium-unsigned.ipa")
        archive = root / "source/Iridium-corresponding-source.tar.gz"
        archive.write_bytes(b"source")
        (root / "source/SOURCE-SHA256SUMS").write_text("0" * 64 + "  " + archive.name + "\n")
        with patch.object(NIGHTLY, "api") as api:
            with self.assertRaisesRegex(ValueError, "source archive checksum"):
                NIGHTLY.release(feed, root, self.env)
        api.assert_not_called()

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

    def test_workflow_keeps_ipa_and_source_in_same_run(self):
        workflow = (ROOT / ".github/workflows/build-unsigned-ipa.yml").read_text()
        self.assertIn("name: Iridium-source-${{ github.sha }}", workflow)
        self.assertIn("name: Iridium-unsigned-${{ github.sha }}", workflow)
        self.assertLess(workflow.index("python3 ci/publish-nightly.py release"),
                        workflow.index("python3 ci/publish-nightly.py publish"))
        self.assertIn("needs: build", workflow)

    def test_dispatch_rejects_a_non_main_nightly(self):
        with patch.object(DISPATCH, "gh") as gh:
            with self.assertRaisesRegex(ValueError, "require main"):
                DISPATCH.dispatch("codex/topic", self.revision, nightly=True)
        gh.assert_not_called()
