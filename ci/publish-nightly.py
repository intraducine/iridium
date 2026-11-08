"""Prepare and publish the AltStore feed for a manual main-branch build."""
import base64
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
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
    run_id = env["GITHUB_RUN_ID"]
    if not re.fullmatch(r"[1-9][0-9]*", run_id):
        raise ValueError("Invalid build run ID")
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
    tag = f'nightly-{run_id}-{env["GITHUB_RUN_ATTEMPT"]}'
    stable = json.loads((ROOT / "altstore/stable.json").read_text())["apps"][0]
    source = json.loads((ROOT / FEED_PATH).read_text())
    stable["name"] = "Iridium Nightly"
    stable["localizedDescription"] = (
        "Iridium Nightly. Bring your own games. Matching source: "
        f"https://github.com/{REPO}/releases/tag/{tag}")
    stable["appPermissions"]["privacy"] = privacy
    stable["versions"] = [{
        "version": info["CFBundleShortVersionString"], "buildVersion": build,
        "date": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "downloadURL": f"https://github.com/{REPO}/releases/download/{tag}/Iridium-unsigned.ipa",
        "size": ipa.stat().st_size, "minOSVersion": info["MinimumOSVersion"], "sha256": digest,
    }]
    source["apps"] = [stable]
    return source


def file_digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def check_space(env):
    token = env["GH_TOKEN"]
    artifacts = api("GET", f'actions/runs/{env["GITHUB_RUN_ID"]}/artifacts?per_page=100', token)["artifacts"]
    names = {"Iridium-source-" + env["GITHUB_SHA"], "Iridium-unsigned-" + env["GITHUB_SHA"]}
    matches = [artifact for artifact in artifacts if artifact["name"] in names and not artifact["expired"]]
    if len(matches) != 2:
        raise ValueError("Missing matching source or IPA artifact")
    required = 20 * 1024**3 + 3 * sum(artifact["size_in_bytes"] for artifact in matches)
    if shutil.disk_usage(ROOT).free < required:
        raise ValueError("Insufficient free space for Nightly publishing")


def find_release(tag, token):
    page = 1
    while True:
        releases = api("GET", f"releases?per_page=100&page={page}", token)
        for record in releases:
            if record["tag_name"] == tag:
                return record
        if len(releases) < 100:
            return None
        page += 1


def release(source, directory, env):
    if env["GITHUB_REPOSITORY"] != REPO or env["GITHUB_REF"] != "refs/heads/main":
        raise ValueError("Nightly release requires the Iridium main branch")
    entry = source["apps"][0]["versions"][0]
    match = re.fullmatch(rf"https://github\.com/{REPO}/releases/download/(nightly-[1-9][0-9]*-[1-9][0-9]*)/Iridium-unsigned\.ipa", entry["downloadURL"])
    if not match or not match[1].startswith("nightly-" + env["GITHUB_RUN_ID"] + "-"):
        raise ValueError("Nightly feed has an invalid run-specific release URL")
    tag = match[1]
    ipa = directory / "ipa/Iridium-unsigned.ipa"
    source_dir = directory / "source"
    archive = source_dir / "Iridium-corresponding-source.tar.gz"
    manifest = source_dir / "COMPONENT-MANIFEST.json"
    source_sums = source_dir / "SOURCE-SHA256SUMS"
    if ipa.stat().st_size != entry["size"] or file_digest(ipa) != entry["sha256"]:
        raise ValueError("Downloaded IPA does not match the audited build")
    expected = source_sums.read_text().split()
    if len(expected) != 2 or expected[1] != archive.name or file_digest(archive) != expected[0]:
        raise ValueError("Downloaded source archive checksum does not match")
    if shutil.disk_usage(directory).free < 20 * 1024**3 + archive.stat().st_size:
        raise ValueError("Insufficient free space to split the source archive")
    with tempfile.TemporaryDirectory(prefix="parts-", dir=directory) as temp:
        parts = []
        with archive.open("rb") as stream:
            while True:
                chunk = stream.read(1024 * 1024)
                if not chunk:
                    break
                part = Path(temp) / f"Iridium-corresponding-source.tar.gz.part{len(parts) + 1:02d}"
                parts.append(part)
                with part.open("wb") as out:
                    out.write(chunk)
                    for _ in range(1899):
                        chunk = stream.read(1024 * 1024)
                        if not chunk:
                            break
                        out.write(chunk)
        if len(parts) + 4 > 1000:
            raise ValueError("Nightly release exceeds the GitHub asset limit")
        files = [ipa, *parts, manifest, source_sums]
        sums = Path(temp) / "SHA256SUMS"
        digests = {path.name: file_digest(path) for path in files}
        sums.write_text("".join(f"{digest}  {name}\n" for name, digest in digests.items()))
        files.append(sums)
        digests[sums.name] = file_digest(sums)
        token = env["GH_TOKEN"]
        record = find_release(tag, token)
        if record is None:
            notes = ("Automated Nightly build. Reassemble source parts in order, then verify "
                     "SOURCE-SHA256SUMS. Verify individual assets with SHA256SUMS.")
            record = api("POST", "releases", token, {
                "tag_name": tag, "target_commitish": env["GITHUB_SHA"], "draft": True,
                "prerelease": True, "make_latest": "false", "name": "Iridium Nightly " + entry["buildVersion"],
                "body": notes,
            })
        if not record["prerelease"] or record["target_commitish"] != env["GITHUB_SHA"]:
            raise ValueError("Existing Nightly tag does not match this build")
        try:
            tagged_sha = api("GET", f"commits/{tag}", token)["sha"]
        except urllib.error.HTTPError as error:
            if error.code != 404 or not record["draft"]:
                raise
        else:
            if tagged_sha != env["GITHUB_SHA"]:
                raise ValueError("Existing Nightly tag does not match this build")
        existing = {asset["name"]: asset for asset in record["assets"]}
        for path in files:
            asset = existing.get(path.name)
            if asset is None:
                if not record["draft"]:
                    raise ValueError("Published Nightly release is missing an asset")
                url = f'https://uploads.github.com/repos/{REPO}/releases/{record["id"]}/assets?name={path.name}'
                subprocess.run(["gh", "api", "--method", "POST", "--header", "Content-Type: application/octet-stream",
                                "--input", str(path), url], check=True, stdout=subprocess.DEVNULL)
            elif asset["digest"] != "sha256:" + digests[path.name]:
                raise ValueError("Existing Nightly release asset differs from this build")
        record = api("GET", f'releases/{record["id"]}', token)
        actual = {asset["name"]: asset for asset in record["assets"] if asset["state"] == "uploaded"}
        if any(name not in actual or actual[name]["digest"] != "sha256:" + digest for name, digest in digests.items()):
            raise ValueError("Nightly release assets did not pass checksum verification")
        if record["draft"]:
            api("PATCH", f'releases/{record["id"]}', token, {"draft": False, "make_latest": "false"})
        if api("GET", f"commits/{tag}", token)["sha"] != env["GITHUB_SHA"]:
            raise ValueError("Published Nightly tag does not match this build")


def api(method, path, token, data=None):
    headers = {"Authorization": "Bearer " + token, "Accept": "application/vnd.github+json",
               "X-GitHub-Api-Version": "2022-11-28"}
    if data is not None:
        headers["Content-Type"] = "application/json"
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
        elif sys.argv[1] == "release":
            release(json.loads(base64.b64decode(os.environ["NIGHTLY_FEED"])), Path(sys.argv[2]), os.environ)
        elif sys.argv[1] == "check-space":
            check_space(os.environ)
        else:
            raise ValueError("Expected prepare, release, publish or check-space")
    except (KeyError, IndexError, OSError, ValueError, subprocess.SubprocessError, zipfile.BadZipFile) as error:
        raise SystemExit("Nightly source failed: " + str(error))
