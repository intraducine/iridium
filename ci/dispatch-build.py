"""Dispatch a build of HEAD and verify GitHub selected that exact commit."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
REPO = "intraducine/iridium"
WORKFLOW = "build-unsigned-ipa.yml"


def check_commit(expected, actual):
    if not re.fullmatch(r"[0-9a-f]{40}", expected) or expected != actual:
        raise ValueError(f"Build commit mismatch: expected {expected}, got {actual}")


def gh(*args):
    return subprocess.check_output(["gh", *args], cwd=ROOT, text=True)


def dispatch(ref, expected):
    check_commit(expected, expected)
    token = uuid.uuid4().hex
    gh("workflow", "run", WORKFLOW, "--repo", REPO, "--ref", ref,
       "-f", f"expected_sha={expected}", "-f", f"dispatch_id={token}")
    # A unique title identifies this request, even with concurrent dispatches.
    for _ in range(30):
        runs = json.loads(gh("api", f"repos/{REPO}/actions/workflows/{WORKFLOW}/runs?event=workflow_dispatch&per_page=100"))["workflow_runs"]
        matches = [run for run in runs if run["display_title"].endswith(f" · {token}")]
        if matches:
            if len(matches) != 1:
                raise RuntimeError("Multiple runs matched this dispatch; inspect GitHub Actions.")
            run = matches[0]
            try:
                check_commit(expected, run["head_sha"])
            except ValueError:
                gh("api", "--method", "POST", f"repos/{REPO}/actions/runs/{run['id']}/cancel")
                raise
            return run["html_url"]
        time.sleep(2)
    raise RuntimeError(f"Could not verify dispatch {token}. Do not start another build; inspect GitHub Actions.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Check workflow inputs before any compilation")
    args = parser.parse_args()
    if args.check:
        check_commit(os.environ.get("EXPECTED_SHA", ""), os.environ.get("GITHUB_SHA", ""))
        return
    expected = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    ref = subprocess.check_output(["git", "symbolic-ref", "--short", "HEAD"], cwd=ROOT, text=True).strip()
    print(dispatch(ref, expected))


if __name__ == "__main__":
    main()
