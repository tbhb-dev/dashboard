#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

# Exercise the request with stub tools. Never contact a signing service.
set -euo pipefail
python3 - "$1" <<'PYTHON'
import os
from pathlib import Path
import subprocess
import sys
import tempfile

SCRIPT = Path(sys.argv[1]).resolve()
STUB = r'''import os
from pathlib import Path
import sys

root = Path(sys.argv[0]).resolve().parent.parent
name = Path(sys.argv[0]).name
args = sys.argv[1:]
scenario = (root / "scenario").read_text()
with (root / "calls").open("a") as trace:
    trace.write(name + "\n")
assert os.environ["GH_CONFIG_DIR"] == str(Path(os.environ["HOME"]) / ".config/gh-agent")
commit = "a" * 40
artifact = "dashboard-macos-" + commit
if name == "gh":
    if args[:2] == ["attestation", "verify"]:
        assert Path(args[2]).read_bytes() == b"unsigned fixture"
        assert args[3:] == ["--repo", "tbhb-dev/dashboard", "--signer-workflow",
                            "tbhb-dev/dashboard/.github/workflows/release.yml",
                            "--source-digest", "a" * 40, "--deny-self-hosted-runners"]
        sys.exit(1 if scenario == "attestation_failure" else 0)
    elif args[:2] == ["run", "view"]:
        assert args == ["run", "view", "42", "--repo", "tbhb-dev/dashboard",
                        "--json", "headSha,headBranch,conclusion", "--jq",
                        "[.headSha, .headBranch, .conclusion] | @tsv"]
        if scenario == "view_failure":
            sys.exit(1)
        print("\t".join(["invalid" if scenario == "invalid_commit" else commit,
                        "topic" if scenario == "not_main" else "main",
                        "failure" if scenario == "not_success" else "success"]))
    else:
        assert args[:7] == ["run", "download", "42", "--repo", "tbhb-dev/dashboard", "-n", artifact]
        assert args[7] == "--dir" and len(args) == 9
        work = Path(args[8])
        assert work.parent == root / "temp"
        assert work.stat().st_mode & 0o777 == 0o700
        if scenario == "download_failure":
            sys.exit(1)
        if scenario != "missing_artifact":
            (work / (artifact + ".zip")).write_bytes(b"unsigned fixture")
elif name == "ssh":
    assert args == ["fixture-destination", "sign-release", commit, artifact + ".zip"]
    assert sys.stdin.buffer.read() == b"unsigned fixture"
    # Even a failed connection may write partial data and name its destination.
    print(args[0], file=sys.stderr)
    sys.stdout.buffer.write(b"partial fixture" if scenario == "ssh_failure" else b"signed fixture")
    if scenario == "output_race":
        (root / "output.zip").write_bytes(b"existing fixture")
    sys.exit(1 if scenario == "ssh_failure" else 0)
else:
    raise AssertionError(name)
'''


def require(condition, detail):
    if not condition:
        raise AssertionError(detail)


def run_case(scenario, expected=1, arguments=None):
    with tempfile.TemporaryDirectory(prefix="request-signature-test-") as directory:
        # Resolve macOS temporary-directory aliases before comparing paths.
        root = Path(directory).resolve()
        (root / "bin").mkdir()
        (root / "temp").mkdir()
        (root / "scenario").write_text(scenario)
        (root / "calls").touch()
        for name in ("gh", "ssh"):
            stub = root / "bin" / name
            stub.write_text("#!" + sys.executable + "\n" + STUB)
            stub.chmod(0o755)
        output = root / "output.zip"
        if scenario == "existing_output":
            output.write_bytes(b"existing fixture")
        elif scenario == "output_link":
            output.symlink_to(root / "absent.zip")
        env = dict(os.environ, PATH=str(root / "bin") + ":" + os.environ["PATH"],
                    TMPDIR=str(root / "temp"))
        args = arguments if arguments is not None else ["42", "fixture-destination", str(output)]
        result = subprocess.run([str(SCRIPT), *args], env=env, capture_output=True, check=False)
        require(result.returncode == expected, (scenario, result.returncode, result.stderr.decode()))
        require(result.stdout == b"", (scenario, "unexpected stdout"))
        require(b"fixture-destination" not in result.stderr, (scenario, "destination disclosed"))
        require(not list((root / "temp").iterdir()), (scenario, "temporary directory leaked"))
        calls = (root / "calls").read_text().splitlines()
        if expected == 0:
            require(output.read_bytes() == b"signed fixture", scenario)
            require(output.stat().st_mode & 0o777 == 0o600, "output mode")
            require(calls == ["gh", "gh", "gh", "ssh"], calls)
        elif scenario in ("existing_output", "output_race"):
            require(output.read_bytes() == b"existing fixture", scenario)
        elif scenario == "output_link":
            require(output.is_symlink() and not output.exists(), scenario)
        else:
            require(not output.exists(), (scenario, "partial output published"))
        if scenario in ("existing_output", "output_link", "usage", "invalid_run", "invalid_target"):
            require(calls == [], calls)
        elif scenario not in ("passed", "ssh_failure", "output_race"):
            require("ssh" not in calls, calls)
        print("PASS", scenario)


run_case("passed", expected=0)
for scenario in ("not_main", "not_success", "ssh_failure", "existing_output",
                  "view_failure", "invalid_commit", "download_failure", "missing_artifact",
                  "output_race", "output_link", "attestation_failure"):
    run_case(scenario)
run_case("usage", expected=2, arguments=[])
run_case("invalid_run", arguments=["bad", "fixture-destination", "output.zip"])
run_case("invalid_target", arguments=["42", "-V", "output.zip"])
PYTHON
