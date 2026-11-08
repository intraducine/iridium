"""Prepare and publish the AltStore feed for a manual main-branch build."""
import base64
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import sys
import urllib.error
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
REPO = "intraducine/iridium"
BRANCH = "altstore-nightly"
FEED_PATH = "altstore/nightly.json"
APP = "Payload/Iridium.app/"


def prepare(ipa, env):
    revision = env["GITHUB_SHA"]
    if env["GITHUB_REPOSITORY"] != REPO or env["GITHUB_REF"] != "refs/heads/main":
        raise ValueError("Nightly requires the main branch of the Iridium repository")
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise ValueError("Invalid build revision")
    ipa_id, source_id = env["NIGHTLY_IPA_ID"], env["NIGHTLY_SOURCE_ID"]
    if not all(re.fullmatch(r"[1-9][0-9]*", item) for item in (ipa_id, source_id)):
        raise ValueError("Missing IPA or source artifact ID")
    with zipfile.ZipFile(ipa) as archive:
        names = archive.namelist()
        info = plistlib.loads(archive.read(APP + "Info.plist"))
        privacy = {}
        for name in names:
            if name == APP + "Info.plist" or re.fullmatch(re.escape(APP) + r"PlugIns/[^/]+\.appex/Info\.plist", name):
                values = plistlib.loads(archive.read(name))
                privacy.update({k: v for k, v in values.items() if re.fullmatch(r"NS.+UsageDescription", k)})
    build = env["GITHUB_RUN_NUMBER"] + "." + env["GITHUB_RUN_ATTEMPT"]
    if (info["CFBundleIdentifier"] != "software.iridium" or info["CFBundleVersion"] != build
            or info.get("IridiumRootRevision") != revision or info.get("IridiumSourceState") != "Committed source"):
        raise ValueError("IPA does not match the committed main build")
    with ipa.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    if env["NIGHTLY_IPA_DIGEST"] != digest:
        raise ValueError("Uploaded Nightly artifact differs from the checked IPA")
    stable = json.loads((ROOT / "altstore/stable.json").read_text())["apps"][0]
    source = json.loads((ROOT / FEED_PATH).read_text())
    stable["name"] = "Iridium Nightly"
    stable["localizedDescription"] = (
        "Iridium Nightly. Bring your own games. Matching source: "
        f"https://nightly.link/{REPO}/actions/artifacts/{source_id}.zip")
    stable["appPermissions"]["privacy"] = privacy
    stable["versions"] = [{
        "version": info["CFBundleShortVersionString"], "buildVersion": build,
        "date": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "downloadURL": f"https://nightly.link/{REPO}/actions/artifacts/{ipa_id}.zip",
        "size": ipa.stat().st_size, "minOSVersion": info["MinimumOSVersion"], "sha256": digest,
    }]
    source["apps"] = [stable]
    return source


def api(method, path, token, data=None):
    headers = {"Authorization": "Bearer " + token, "Accept": "application/vnd.github+json",
               "X-GitHub-Api-Version": "2022-11-28"}
    payload = json.dumps(data).encode() if data is not None else None
    request = urllib.request.Request(f"https://api.github.com/repos/{REPO}/{path}",
                                     data=payload, headers=headers, method=method)
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def publish(source, env):
    if env["GITHUB_REPOSITORY"] != REPO or env["GITHUB_REF"] != "refs/heads/main":
        raise ValueError("Nightly publication requires the Iridium main branch")
    token = env["GH_TOKEN"]
    try:
        api("GET", f"git/ref/heads/{BRANCH}", token)
    except urllib.error.HTTPError as error:
        if error.code != 404:
            raise
        try:
            api("POST", "git/refs", token, {"ref": "refs/heads/" + BRANCH, "sha": env["GITHUB_SHA"]})
        except urllib.error.HTTPError as create_error:
            if create_error.code != 422:
                raise
    proposed = source["apps"][0]["versions"][0]
    for _ in range(3):
        try:
            current = api("GET", f"contents/{FEED_PATH}?ref={BRANCH}", token)
        except urllib.error.HTTPError as error:
            if error.code != 404:
                raise
            current = None
        if current:
            previous = json.loads(base64.b64decode(current["content"]))
            if previous["apps"]:
                old_build = previous["apps"][0]["versions"][0]["buildVersion"]
                if tuple(map(int, old_build.split("."))) >= tuple(map(int, proposed["buildVersion"].split("."))):
                    print("A newer or identical Nightly is already published")
                    return
        content = base64.b64encode((json.dumps(source, indent=2) + "\n").encode()).decode()
        update = {"message": "Update Iridium Nightly source", "content": content, "branch": BRANCH}
        if current:
            update["sha"] = current["sha"]
        try:
            api("PUT", f"contents/{FEED_PATH}", token, update)
            print("Published Nightly source for build " + proposed["buildVersion"])
            return
        except urllib.error.HTTPError as error:
            if error.code not in (409, 422):
                raise
    raise ValueError("Nightly source changed repeatedly; retry publication")


if __name__ == "__main__":
    try:
        if sys.argv[1] == "prepare":
            feed = base64.b64encode(json.dumps(prepare(Path(sys.argv[2]), os.environ)).encode()).decode()
            with open(os.environ["GITHUB_OUTPUT"], "a") as output:
                output.write("feed=" + feed + "\n")
        elif sys.argv[1] == "publish":
            publish(json.loads(base64.b64decode(os.environ["NIGHTLY_FEED"])), os.environ)
        else:
            raise ValueError("Expected prepare or publish")
    except (KeyError, IndexError, OSError, ValueError, zipfile.BadZipFile) as error:
        raise SystemExit("Nightly source failed: " + str(error))
