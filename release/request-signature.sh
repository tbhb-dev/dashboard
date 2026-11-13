#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns
#
# Request a signature for one successful release run.
set -euo pipefail
umask 077
export GH_CONFIG_DIR="$HOME/.config/gh-agent"

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
finish() {
  local status=$?
  trap - EXIT HUP INT TERM PIPE
  if [[ -n $WORK ]]; then
    rm -rf -- "$WORK" || status=1
  fi
  exit "$status"
}
trap finish EXIT
trap 'exit 1' HUP INT TERM PIPE
WORK=$(mktemp -d "${TMPDIR:-/tmp}/request-signature.XXXXXX")
chmod 700 "$WORK"

METADATA=$(gh run view "$RUN_ID" --repo tbhb-dev/dashboard \
  --json headSha,headBranch,conclusion \
  --jq '[.headSha, .headBranch, .conclusion] | @tsv') || die 'cannot read run'
IFS=$'\t' read -r COMMIT BRANCH CONCLUSION <<<"$METADATA"
[[ $COMMIT =~ ^[0-9a-f]{40}$ && $BRANCH == main && $CONCLUSION == success ]] || die 'run must succeed on main'
NAME="dashboard-macos-$COMMIT"
gh run download "$RUN_ID" --repo tbhb-dev/dashboard -n "$NAME" \
  --dir "$WORK" >/dev/null 2>&1 || die 'cannot download artifact'
[[ -f $WORK/$NAME.zip && ! -L $WORK/$NAME.zip ]] || die 'artifact zip is missing'

# Keep partial output private, and suppress diagnostics that name the target.
# Both remote arguments contain only validated commit and artifact characters.
# shellcheck disable=SC2029
ssh "$TARGET" sign-release "$COMMIT" "$NAME.zip" \
  <"$WORK/$NAME.zip" >"$WORK/signed.zip" 2>/dev/null || die 'signature request failed'
# Exclusive creation also refuses an output created while ssh was running.
(
  set -C
  cat "$WORK/signed.zip" >"$OUTPUT"
) || die 'cannot create output'
