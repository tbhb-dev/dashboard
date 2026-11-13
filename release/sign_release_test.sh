#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

# Exercise a private copy with stub tools. Never invoke Apple tools.
set -euo pipefail
python3 - "$1" <<'PYTHON'
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import zipfile

SOURCE = Path(sys.argv[1]).resolve().read_text()
COMMIT = "a" * 40
STUB = r'''import os
from pathlib import Path
import sys
import zipfile

root = Path(sys.argv[0]).resolve().parent.parent
name = Path(sys.argv[0]).name
args = sys.argv[1:]
scenario = (root / "scenario").read_text()
assert "GH_TOKEN" not in os.environ
assert "GIT_CONFIG_COUNT" not in os.environ
assert "DYLD_LIBRARY_PATH" not in os.environ
assert os.environ["HOME"] == str(root / "home")
assert os.environ["GH_CONFIG_DIR"] == str(root / "home/.config/gh-agent")
with (root / "calls").open("a") as trace:
    trace.write(name + " " + repr(args) + "\n")
if scenario == name + "_failure":
    sys.exit(1)
if name == "git":
    if "fetch" in args:
        assert args[2:] == ["-c", "remote.origin.fetch=+refs/heads/main:refs/remotes/origin/main", "fetch", "origin", "main"]
    else:
        assert args[2:] == ["merge-base", "--is-ancestor", "a" * 40, "origin/main"]
        sys.exit(1 if scenario == "not_main" else 0)
elif name == "gh":
    if args[:2] == ["attestation", "verify"]:
        assert args[3:] == ["--repo", "tbhb-dev/dashboard", "--source-digest", "a" * 40, "--deny-self-hosted-runners"]
        assert Path(args[2]).read_bytes() == (root / "input.zip").read_bytes()
        sys.exit(1 if scenario == "attestation" else 0)
    assert args[0] == "api"
    assert "--method" not in args and "-X" not in args
    assert "--field" not in args and "--raw-field" not in args
    endpoint = args[1]
    if "/commits/" in endpoint:
        assert args[2:] == ["--paginate", "--jq", ".[].number"]
        if scenario != "no_pr":
            print("7")
    elif endpoint.endswith("/reviews"):
        assert args[2] == "--paginate"
        assert args[3] == "--jq"
        assert args[4] == '.[] | select(.state == "APPROVED" and .commit_id == "' + "b" * 40 + '") | .id'
        if scenario not in ("no_review", "stale_review"):
            print("9")
    else:
        assert endpoint.endswith("/pulls/7")
        assert args[2] == "--jq"
        assert '.merged == true' in args[3]
        assert '.merge_commit_sha == "' + "a" * 40 + '"' in args[3]
        assert '.base.ref == "main"' in args[3]
        assert '.base.repo.full_name == "tbhb-dev/dashboard"' in args[3]
        if scenario != "unmerged":
            print("b" * 40)
elif name == "getconf":
    assert args == ["DARWIN_USER_TEMP_DIR"]
    print(str(root / "temp") + "/")
elif name == "stat":
    if args[1] == "%u:%Lp":
        print("0:644" if scenario != "writable_allow_list" else "0:666")
    else:
        assert args[1] == "%Lp"
        print(oct(Path(args[2]).stat().st_mode & 0o777)[2:])
elif name == "plutil":
    if args[1] == "status":
        assert args[:5] == ["-extract", "status", "raw", "-o", "-"]
        print("Invalid" if scenario == "notary_invalid" else "Accepted")
    else:
        assert args[:5] == ["-extract", "CFBundleIdentifier", "raw", "-o", "-"]
        print("dev.tbhb.unknown" if scenario == "unknown_app" else "dev.tbhb.dashboard.macos")
elif name == "ditto":
    if args[:2] == ["-x", "-k"]:
        if scenario == "extraction_failure":
            sys.exit(1)
        with zipfile.ZipFile(args[2]) as archive:
            archive.extractall(args[3])
    else:
        assert args[:3] == ["-c", "-k", "--keepParent"]
        bundle, output = map(Path, args[3:])
        with zipfile.ZipFile(output, "w") as archive:
            for path in sorted(bundle.rglob("*")):
                if path.is_file():
                    archive.write(path, str(path.relative_to(bundle.parent)))
            archive.writestr("stub-result", "signed and stapled")
elif name == "codesign":
    assert args[:8] == ["--force", "--options", "runtime", "--timestamp", "--keychain", str(root / "scratch.keychain-db"), "--sign", "Developer ID Application"]
    assert "--deep" not in args
elif name == "xcrun":
    if args[:2] == ["notarytool", "submit"]:
        assert args[3:] == ["--wait", "--keychain-profile", "agent-notary", "--keychain", str(root / "scratch.keychain-db"), "--output-format", "json"]
        print('{"status":"Accepted"}')
    else:
        assert args[:2] == ["stapler", "staple"]
        if scenario == "stapling_failure":
            sys.exit(1)
elif name == "file":
    assert args[0] == "-b"
    print("Mach-O 64-bit executable" if Path(args[1]).name == "executable" else "XML document")
else:
    raise AssertionError(name)
'''


def require(condition, detail):
    if not condition:
        raise AssertionError(detail)


def run_case(scenario, command=None, expected=3, reason=None, archive_kind=None, repeat=1, arguments=()):
    with tempfile.TemporaryDirectory(prefix="sign-release-test-") as directory:
        root = Path(directory)
        (root / "bin").mkdir()
        (root / "temp").mkdir()
        (root / "home").mkdir()
        (root / "clone/.git").mkdir(parents=True)
        (root / "scenario").write_text(scenario)
        (root / "allow-list").write_text("dev.tbhb.dashboard.macos\n")
        (root / "calls").touch()
        for name in ("git", "gh", "getconf", "stat", "plutil", "ditto", "codesign", "xcrun", "file"):
            path = root / "bin" / name
            path.write_text("#!" + sys.executable + "\n" + STUB)
            path.chmod(0o755)
        # Exercise real archive listings, hashing, and file operations on Linux.
        tool_path = str(root / "bin") + ":/usr/bin:/bin"
        replacements = {
            "CLONE=": 'CLONE="' + str(root / "clone") + '"',
            "ALLOW_LIST=": 'ALLOW_LIST="' + str(root / "allow-list") + '"',
            "LOG=": 'LOG="' + str(root / "audit.log") + '"',
            "HOME=": 'HOME="' + str(root / "home") + '"',
            "KEYCHAIN=": 'KEYCHAIN="' + str(root / "scratch.keychain-db") + '"',
            "PATH=": 'PATH="' + tool_path + '"',
        }
        copy = "\n".join(next((value for key, value in replacements.items() if line.startswith(key)), line) for line in SOURCE.splitlines()) + "\n"
        wrapper = root / "sign-release"
        wrapper.write_text(copy)
        wrapper.chmod(0o755)
        payload = root / "input.zip"
        with zipfile.ZipFile(payload, "w") as archive:
            def entry(name, content="fixture", mode=0o100644):
                info = zipfile.ZipInfo(name)
                info.create_system = 3
                info.external_attr = mode << 16
                archive.writestr(info, content)
            entry("Fixture.app/Contents/Info.plist", "<plist/>")
            entry("Fixture.app/Contents/Resources/", "", 0o40755)
            entry("Fixture.app/Contents/MacOS/executable", mode=0o100755)
            entry("Fixture.app/Contents/Frameworks/Nested.framework/executable", mode=0o100755)
            if archive_kind == "traversal":
                entry("Fixture.app/../../escape")
            elif archive_kind == "symlink":
                entry("Fixture.app/link", "../../escape", 0o120777)
            elif archive_kind == "multiple":
                entry("Other.app/Contents/Info.plist")
        env = dict(os.environ, SSH_ORIGINAL_COMMAND=command if command is not None else "sign-release " + COMMIT + " fixture.zip",
                    HOME="/ignored", GH_TOKEN="ignored", GH_HOST="ignored", GIT_CONFIG_COUNT="1",
                    GIT_CONFIG_KEY_0="core.sshCommand", GIT_CONFIG_VALUE_0="false",
                    DYLD_LIBRARY_PATH="ignored", BASH_ENV=str(root / "startup"), PATH=tool_path)
        (root / "startup").write_text("exit 99\n")
        for attempt in range(repeat):
            result = subprocess.run([str(wrapper), *arguments], input=payload.read_bytes(), env=env, capture_output=True, check=False)
            require(result.returncode == expected, (scenario, result.returncode, result.stderr.decode()))
        lines = (root / "audit.log").read_text().splitlines()
        require(len(lines) == repeat, (scenario, lines))
        log = json.loads(lines[0])
        require(log["outcome"] == ("passed" if expected == 0 else "failed" if expected == 1 else "refused"), log)
        if reason:
            require(log["reason"] == reason, log)
        require((root / "audit.log").stat().st_mode & 0o777 == 0o644, "log mode")
        require(not list((root / "temp").iterdir()), "temporary directory leaked")
        calls = (root / "calls").read_text()
        if expected == 0:
            output = root / "output.zip"
            output.write_bytes(result.stdout)
            with zipfile.ZipFile(output) as archive:
                require(archive.read("stub-result") == b"signed and stapled", "output")
            require(log["commit"] == COMMIT and log["artifact"] == "fixture.zip", log)
            require(log["bundle_identifier"] == "dev.tbhb.dashboard.macos", log)
            require(len(log["sha256"]) == 64, log)
            signed = [line for line in calls.splitlines() if line.startswith("codesign ")]
            require(len(signed) == 4 * repeat, signed)
            nested_code = next(i for i, line in enumerate(signed) if "Nested.framework/executable" in line)
            nested_bundle = next(i for i, line in enumerate(signed) if "Nested.framework'" in line)
            require(nested_code < nested_bundle, signed)
            require("Fixture.app'" in signed[-1], signed)
            require(calls.index("notarytool") < calls.index("stapler"), calls)
        else:
            require(result.stdout == b"", (scenario, "unexpected stdout"))
            if expected == 3:
                require("codesign " not in calls and "xcrun " not in calls, calls)
        if reason == "malformed_command":
            require(calls == "", calls)
            require(log["commit"] == "" and log["artifact"] == "", log)
        print("PASS", scenario)


run_case("passed", expected=0)
for scenario, reason in (("not_main", "not_main"), ("no_review", "no_review"),
                          ("stale_review", "no_review"), ("no_pr", "no_review"),
                          ("unmerged", "no_review"), ("attestation", "attestation"),
                          ("unknown_app", "bundle_identifier")):
    run_case(scenario, reason=reason)
for kind in ("traversal", "symlink", "multiple"):
    run_case(kind, archive_kind=kind, reason="archive")
for index, command in enumerate(("sign-release " + COMMIT + " fixture.zip extra",
                                  "sign-release abc fixture.zip",
                                  "sign-release " + COMMIT + " ../fixture.zip",
                                  "sign-release " + COMMIT.upper() + " fixture.zip",
                                  "sign-release " + COMMIT + ' bad".zip', "", "sign-release\n" + COMMIT + " fixture.zip")):
    run_case("malformed_" + str(index), command=command, reason="malformed_command")
for tool, reason in (("git", "fetch"), ("gh", "github_api"),
                      ("codesign", "signing"), ("xcrun", "notarization"),
                      ("getconf", "temporary_directory")):
    run_case(tool + "_failure", expected=1, reason=reason)
run_case("writable_allow_list", expected=1, reason="configuration")
run_case("notary_invalid", expected=1, reason="notarization")
run_case("stapling_failure", expected=1, reason="stapling")
run_case("extraction_failure", reason="archive")
run_case("passed", expected=0, repeat=2)
run_case("arguments", arguments=("--help",), reason="malformed_command")
PYTHON
