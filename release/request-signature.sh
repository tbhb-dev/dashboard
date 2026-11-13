#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns
#
# Request a signature for one successful release run.
set -euo pipefail
umask 077
# Honor a caller's GitHub CLI config. Default to the agent config, never the personal one.
export GH_CONFIG_DIR="${GH_CONFIG_DIR:-$HOME/.config/gh-agent}"

die() {
  printf 'request-signature: %s\n' "$1" >&2
  exit 1
}

if [[ $# != 3 ]]; then
  printf 'usage: %s <run-id> <ssh-target> <output.zip>\n' "${0##*/}" >&2
  exit 2
fi
RUN_ID=$1
TARGET=$2
OUTPUT=$3
[[ $RUN_ID =~ ^[1-9][0-9]*$ ]] || die 'invalid run ID'
# Reject ssh options and whitespace before passing the destination to ssh.
[[ -n $TARGET && $TARGET != -* && $TARGET != *[[:space:]]* ]] || die 'invalid ssh target'
[[ $OUTPUT == *.zip && ! -e $OUTPUT && ! -L $OUTPUT ]] || die 'output must be a new zip file'

WORK=""
STAGE=""
finish() {
  local status=$?
  trap - EXIT HUP INT TERM PIPE
  if [[ -n $WORK ]]; then
    rm -rf -- "$WORK" || status=1
  fi
  if [[ -n $STAGE ]]; then
    rm -f -- "$STAGE" || status=1
  fi
  exit "$status"
}
trap finish EXIT
trap 'exit 1' HUP INT TERM PIPE
WORK=$(mktemp -d "${TMPDIR:-/tmp}/request-signature.XXXXXX")
chmod 700 "$WORK"

METADATA=$(gh api "repos/tbhb-dev/dashboard/actions/runs/$RUN_ID" \
  --jq '[.head_sha, .head_branch, .conclusion, .path, .event, .run_attempt] | @tsv') || die 'cannot read run'
IFS=$'\t' read -r COMMIT BRANCH CONCLUSION WORKFLOW_PATH EVENT ATTEMPT <<<"$METADATA"
[[ $ATTEMPT =~ ^[1-9][0-9]*$ ]] || die 'invalid run attempt'
[[ $COMMIT =~ ^[0-9a-f]{40}$ && $BRANCH == main && $CONCLUSION == success ]] || die 'run must succeed on main'
# The run's path can carry an @ref suffix. Only a manual run of the release workflow counts.
[[ ${WORKFLOW_PATH%%@*} == .github/workflows/release.yml && $EVENT == workflow_dispatch ]] || die 'run is not a release dispatch'
NAME="dashboard-macos-$COMMIT"
gh run download "$RUN_ID" --repo tbhb-dev/dashboard -n "$NAME" \
  --dir "$WORK" >/dev/null 2>&1 || die 'cannot download artifact'
[[ -f $WORK/$NAME.zip && ! -L $WORK/$NAME.zip ]] || die 'artifact zip is missing'

# Verify the build provenance here too. The signer workflow and source ref bind
# the attestation to the release workflow on main. The certificate's run
# invocation then binds it to the run checked above, because another run of the
# same workflow at the same commit passes the flags alone.
INVOCATIONS=$(gh attestation verify "$WORK/$NAME.zip" --repo tbhb-dev/dashboard \
  --signer-workflow tbhb-dev/dashboard/.github/workflows/release.yml \
  --source-digest "$COMMIT" --source-ref refs/heads/main --deny-self-hosted-runners \
  --format json --jq '.[].verificationResult.signature.certificate.runInvocationURI' \
  2>/dev/null) || die 'attestation check failed'
EXPECTED="https://github.com/tbhb-dev/dashboard/actions/runs/$RUN_ID/attempts/$ATTEMPT"
[[ $'\n'$INVOCATIONS$'\n' == *$'\n'"$EXPECTED"$'\n'* ]] || die 'attestation is for another run'

# Keep partial output private, and suppress diagnostics that name the target.
# Both remote arguments contain only validated commit and artifact characters.
# shellcheck disable=SC2029
ssh "$TARGET" sign-release "$COMMIT" "$NAME.zip" \
  <"$WORK/$NAME.zip" >"$WORK/signed.zip" 2>/dev/null || die 'signature request failed'
# Stage the copy beside the output. A write error then leaves no truncated
# output, and the stage name is a dotfile that the finish trap removes.
STAGE=$(mktemp "$(dirname -- "$OUTPUT")/.request-signature.XXXXXX") || die 'cannot stage output'
cp "$WORK/signed.zip" "$STAGE" || die 'cannot stage output'
# Publish with one no-replace link, then let the finish trap unlink the stage.
# link(1) calls link(2) directly, so it fails on any existing path, including a
# file, directory, or symlink made while ssh ran, and never links into a directory.
# The ./ prefix keeps a leading dash from reading as an option.
[[ $OUTPUT == /* ]] || OUTPUT=./$OUTPUT
link "$STAGE" "$OUTPUT" || die 'cannot create output'
