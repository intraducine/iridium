"""Index a published Iridium IPA in its AltStore Classic source."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
REPO = "intraducine/iridium"
WORKFLOW = "build-unsigned-ipa.yml"
IPA = "Iridium-unsigned.ipa"
APP = "Payload/Iridium.app/"
VERSION = r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)"


def api(path):
    return json.loads(subprocess.check_output(
        ["gh", "api", f"repos/{REPO}/{path}"], text=True, timeout=30))


def package_info(path):
    with zipfile.ZipFile(path) as archive:
        info = plistlib.loads(archive.read(APP + "Info.plist"))
        privacy = {}
        for name in [APP + "Info.plist", *(
                name for name in archive.namelist()
                if re.fullmatch(re.escape(APP) + r"PlugIns/[^/]+\.appex/Info\.plist", name))]:
            plist = plistlib.loads(archive.read(name))
            privacy.update({key: value for key, value in plist.items()
                            if re.fullmatch(r"NS.+UsageDescription", key)})
    if info["CFBundleIdentifier"] != "software.iridium":
        raise ValueError("Expected the Iridium app bundle identifier")
    return info, privacy


def check_nightly(run, revision, info):
    if (run["path"] != ".github/workflows/" + WORKFLOW
            or run["event"] != "workflow_dispatch" or run["conclusion"] != "success"
            or run["head_branch"] != "main"
            or run["head_repository"]["full_name"] != REPO
            or run["head_sha"] != revision
            or info.get("IridiumRootRevision") != revision
            or info.get("IridiumSourceState") != "Committed source"
            or info["CFBundleVersion"] != f'{run["run_number"]}.{run["run_attempt"]}'):
        raise ValueError("Nightly requires the exact successful main build and its committed-source IPA")


def index(tag, path, run_id):
    nightly = run_id is not None
    if not re.fullmatch("v" + VERSION + (r"-nightly\.[1-9][0-9]*\.[1-9][0-9]*" if nightly else ""), tag):
        raise ValueError("Expected a stable vX.Y.Z tag or vX.Y.Z-nightly.RUN.ATTEMPT with --run")
    release = api(f"releases/tags/{tag}")
    if release["draft"] or release["prerelease"] != nightly:
        raise ValueError("Expected a published release for the selected channel")
    assets = {asset["name"]: asset for asset in release["assets"] if asset["state"] == "uploaded"}
    if (not {IPA, "Iridium-source-guide.zip", "SHA256SUMS"} <= assets.keys()
            or not any(re.fullmatch(r"Iridium-corresponding-source\.tar\.gz(?:\.part01)?", name)
                       for name in assets)):
        raise ValueError("The published release must include its IPA, source, guide and checksums")

    ipa = assets[IPA]
    with path.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    if ipa["size"] != path.stat().st_size or ipa["digest"] != "sha256:" + digest:
        raise ValueError("Local IPA size or SHA-256 differs from the published asset")
    info, privacy = package_info(path)
    version, build = info["CFBundleShortVersionString"], info["CFBundleVersion"]
    if tag != f"v{version}" + (f"-nightly.{build}" if nightly else ""):
        raise ValueError("Release tag differs from the packaged app version or build")
    if nightly:
        revision = api(f"commits/{tag}")["sha"]
        run = api(f"actions/runs/{run_id}/attempts/{build.split('.')[1]}")
        check_nightly(run, revision, info)
        sources = api(f"actions/runs/{run_id}/artifacts?name=Iridium-source-{revision}")["artifacts"]
        if not any(asset["name"] == f"Iridium-source-{revision}" for asset in sources):
            raise ValueError("Nightly requires the matching release-mode source artifact")

    channel = "nightly" if nightly else "stable"
    source_path = ROOT / "altstore" / (channel + ".json")
    source = json.loads(source_path.read_text())
    app = source["apps"][0] if source["apps"] else json.loads(
        (ROOT / "altstore/stable.json").read_text())["apps"][0]
    versions = app["versions"] if source["apps"] else []
    permissions = app["appPermissions"]
    permissions["privacy"] = privacy
    entry = {
        "version": version, "buildVersion": build, "date": release["published_at"],
        "downloadURL": f"https://github.com/{REPO}/releases/download/{tag}/{IPA}",
        "size": ipa["size"], "minOSVersion": info["MinimumOSVersion"], "sha256": digest,
    }
    for previous in versions:
        if previous["downloadURL"] == entry["downloadURL"] and previous != entry:
            raise ValueError("Published IPA metadata changed for an existing tag")
    if nightly:
        if versions and numbers(versions[0]["buildVersion"]) > numbers(build):
            raise ValueError("Refusing to replace Nightly with an older build")
        app["name"] = "Iridium Nightly"
        app["versions"] = [entry]
    else:
        if versions and numbers(versions[0]["version"]) > numbers(version):
            raise ValueError("Refusing to replace Stable with an older version")
        app["versions"] = [entry]
    source["apps"] = [app]
    with tempfile.TemporaryDirectory(dir=source_path.parent) as temp:
        staged = Path(temp) / source_path.name
        staged.write_text(json.dumps(source, indent=2) + "\n")
        staged.replace(source_path)
    print(f"Updated AltStore {channel} source for {tag}")


def numbers(value):
    return tuple(map(int, value.split(".")))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("tag")
    parser.add_argument("ipa", type=Path)
    parser.add_argument("--run", type=int, help="Actions run ID for a Nightly prerelease")
    args = parser.parse_args()
    try:
        index(args.tag, args.ipa, args.run)
    except (KeyError, OSError, ValueError, plistlib.InvalidFileException,
            subprocess.SubprocessError, zipfile.BadZipFile) as error:
        parser.exit(1, f"AltStore source update failed: {error}\n")
