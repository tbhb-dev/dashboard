#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns
#
# One-time setup of the agent signing identity on the signing host.
#
# Run it as the `signer` user, in a terminal on the host's console login, not
# over plain ssh. The keychain prompts (`-P` and `-u`) open GUI dialogs, and the
# portal steps need the Account Holder's sign-in. `--check` changes nothing and
# reports each step's state. A rerun skips every step that is already done. Environment
# for a full run:
#   API_KEY_PATH, API_KEY_ID, API_ISSUER  App Store Connect API key (notarization)
#   AGENT_PUBKEY_PATH                     file with the agents' public ssh key,
#                                         exactly one line, no options prefix
set -euo pipefail

KEYCHAIN="$HOME/Library/Keychains/agent-signing.keychain-db"
NOTARY_PROFILE="agent-notary"
WRAPPER="/usr/local/libexec/sign-release"
AUTHORIZED_KEYS="$HOME/.ssh/authorized_keys"
CSR="$HOME/agent-signing.csr"

usage() {
  printf 'usage: %s [--check]\n' "${0##*/}"
}
CHECK=0
case "${1:-}" in
"") ;;
--check) CHECK=1 ;;
-h | --help)
  usage
  exit 0
  ;;
*)
  usage >&2
  exit 2
  ;;
esac
if (($# > 1)); then
  usage >&2
  exit 2
fi

step() { printf '\n== %s\n' "$1"; }
ok() { printf 'ok:   %s\n' "$1"; }
todo() { printf 'todo: %s\n' "$1"; }
die() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

have_keychain() { security show-keychain-info "$KEYCHAIN" >/dev/null 2>&1; }
have_identity() {
  security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null |
    grep -q "Developer ID Application"
}
# A private key record in the keychain, with or without a certificate.
have_private_key() {
  security dump-keychain "$KEYCHAIN" 2>/dev/null | grep -Eq "class: 0x(0000000F|00000010)"
}
have_profile() {
  xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" \
    --keychain "$KEYCHAIN" >/dev/null 2>&1
}
# Lines of authorized_keys that start with the forced command. With KEY_BLOB
# set, only the lines that also carry the agents' key.
restricted_lines() {
  awk -v p="command=\"$WRAPPER\",restrict " -v b="${KEY_BLOB:-}" \
    'index($0, p) == 1 && (b == "" || index($0, b) > 0)' "$AUTHORIZED_KEYS" 2>/dev/null
}
have_ssh_restriction() {
  restricted_lines | grep -q .
}
# The wrapper runs, and it and its folder are root-owned and not writable by
# the signer user.
have_wrapper() {
  local dir=${WRAPPER%/*} file_owner dir_owner
  [[ -x $WRAPPER && ! -w $WRAPPER && ! -w $dir ]] || return 1
  file_owner=$(/usr/bin/stat -f '%u' "$WRAPPER")
  dir_owner=$(/usr/bin/stat -f '%u' "$dir")
  [[ ${file_owner} == 0 && ${dir_owner} == 0 ]]
}
WRAPPER_OK="$WRAPPER and its folder are root-owned, and the signer can't write them"
# report <check function> <message if present> <message if missing>
report() {
  if "$1"; then ok "$2"; else todo "$3"; fi
}
require() {
  if "$1"; then ok "$2"; else die "$3"; fi
}

step "Host"
OS=$(uname -s)
[[ ${OS} == "Darwin" ]] || die "this script runs on macOS only"
for tool in security xcrun openssl ssh-keygen getconf; do
  command -v "$tool" >/dev/null || die "$tool is missing"
done
ok "macOS with security, xcrun, openssl and ssh-keygen"
ME=$(id -un)
if [[ ${ME} == "signer" ]]; then
  ok "running as signer"
else
  todo "run as the signer user (this is ${ME})"
  ((CHECK)) || die "refusing to create the keychain as ${ME}"
fi

if ((CHECK)); then
  KEY_BLOB=""
  if [[ -n ${AGENT_PUBKEY_PATH:-} && -r ${AGENT_PUBKEY_PATH} ]]; then
    KEY_BLOB=$(awk '{print $2}' "$AGENT_PUBKEY_PATH")
  fi
  step "Keychain"
  report have_keychain "$KEYCHAIN exists" "create $KEYCHAIN"
  step "Identity"
  report have_identity "Developer ID Application identity present" \
    "generate the key, upload the request, import the certificate"
  step "Notary profile"
  echo "note: this check calls Apple over the network and may prompt for keychain access"
  report have_profile "$NOTARY_PROFILE works" "store $NOTARY_PROFILE"
  step "Agent ssh key"
  report have_ssh_restriction "authorized_keys forces $WRAPPER" \
    "restrict the agents' key to $WRAPPER"
  step "Wrapper"
  report have_wrapper "$WRAPPER_OK" \
    "install $WRAPPER, root-owned, in a root-owned folder (the wrapper change covers it)"
  exit 0
fi

: "${API_KEY_PATH:?set API_KEY_PATH}" "${API_KEY_ID:?set API_KEY_ID}"
: "${API_ISSUER:?set API_ISSUER}" "${AGENT_PUBKEY_PATH:?set AGENT_PUBKEY_PATH}"

# Validate the agents' key before changing anything.
[[ -f $AGENT_PUBKEY_PATH ]] || die "$AGENT_PUBKEY_PATH is not a file"
KEY_LINES=$(grep -c . "$AGENT_PUBKEY_PATH" || true)
[[ ${KEY_LINES} == 1 ]] || die "$AGENT_PUBKEY_PATH must hold exactly one key line"
AGENT_PUBKEY=$(grep . "$AGENT_PUBKEY_PATH")
[[ ${AGENT_PUBKEY} =~ ^(ssh-|ecdsa-|sk-) ]] ||
  die "the key line starts with options or isn't a public key"
ssh-keygen -l -f "$AGENT_PUBKEY_PATH" >/dev/null || die "ssh-keygen rejects the key"

step "1. Dedicated keychain, no auto-lock"
if have_keychain; then
  ok "$KEYCHAIN exists"
else
  # -P prompts for the password, so it never appears in a process list.
  security create-keychain -P "$KEYCHAIN"
  security set-keychain-settings "$KEYCHAIN"
fi
security unlock-keychain -u "$KEYCHAIN"

step "2 and 3. Key pair, certificate request, and certificate"
if have_identity; then
  ok "identity present, so no new key or request"
else
  if have_private_key; then
    ok "key present without a certificate, so no new key or request"
    printf 'Use the request already uploaded, or %s if it is still there.\n' "$CSR"
  else
    # The key passes through a file for a moment. The directory is private to
    # signer, and the trap removes the key at once, including on failure.
    TEMP_ROOT=$(getconf DARWIN_USER_TEMP_DIR)
    WORK=$(mktemp -d "${TEMP_ROOT}agent-signing.XXXXXX")
    trap 'rm -P "$WORK"/* || true; rmdir "$WORK" || true' EXIT
    MODE=$(/usr/bin/stat -f '%Lp' "$WORK")
    [[ ${MODE} == 700 ]] || die "$WORK has mode ${MODE}, not 700"
    openssl genrsa -out "$WORK/key.pem" 2048
    openssl req -new -key "$WORK/key.pem" -subj "/CN=agent-signing" -out "$CSR"
    # -x marks the imported private key non-extractable.
    security import "$WORK/key.pem" -k "$KEYCHAIN" -x -T /usr/bin/codesign
    printf 'Request written to %s\n' "$CSR"
    echo "Upload it in the Apple Developer portal as a Developer ID Application"
    echo "certificate, then download the certificate."
  fi
  read -rp "Path to the downloaded .cer: " CER_PATH
  security import "$CER_PATH" -k "$KEYCHAIN"
  require have_identity "Developer ID Application identity present" \
    "the imported certificate is not a Developer ID Application identity for this key"
fi

step "4. Only Apple's tools use the private key without a prompt"
# set-key-partition-list takes the password only through -k.
read -rsp "Keychain password: " KEYCHAIN_PASSWORD
echo
security set-key-partition-list -S apple-tool:,apple: -s \
  -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
unset KEYCHAIN_PASSWORD

step "5. Notarization credential"
if have_profile; then
  ok "$NOTARY_PROFILE works"
else
  xcrun notarytool store-credentials "$NOTARY_PROFILE" \
    --key "$API_KEY_PATH" --key-id "$API_KEY_ID" --issuer "$API_ISSUER" \
    --keychain "$KEYCHAIN"
fi

step "6. Restrict the agents' ssh key to the wrapper"
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
KEY_BLOB=$(awk '{print $2}' "$AGENT_PUBKEY_PATH")
FOUND=""
if [[ -f $AUTHORIZED_KEYS ]]; then
  FOUND=$(grep -nF -- "$KEY_BLOB" "$AUTHORIZED_KEYS" || true)
fi
if [[ -n ${FOUND} ]]; then
  # The script never rewrites the file. The operator removes a bad line.
  FOUND_COUNT=$(printf '%s\n' "${FOUND}" | wc -l)
  if ((FOUND_COUNT == 1)) && have_ssh_restriction; then
    ok "the key is already in authorized_keys with the forced command"
  else
    FOUND_LINES=$(printf '%s\n' "${FOUND}" | cut -d: -f1 | tr '\n' ' ')
    die "the key is in $AUTHORIZED_KEYS without exactly one forced-command line. Remove line(s) ${FOUND_LINES}and rerun."
  fi
else
  # Start the new line on its own line if the file lacks a final newline.
  LAST=""
  if [[ -s $AUTHORIZED_KEYS ]]; then
    LAST=$(tail -c1 "$AUTHORIZED_KEYS")
  fi
  [[ -z ${LAST} ]] || printf '\n' >>"$AUTHORIZED_KEYS"
  printf 'command="%s",restrict %s\n' "$WRAPPER" "$AGENT_PUBKEY" >>"$AUTHORIZED_KEYS"
fi
chmod 600 "$AUTHORIZED_KEYS"
report have_wrapper "$WRAPPER_OK" \
  "$WRAPPER isn't installed yet (the wrapper change covers it)"

step "Result"
require have_identity "Developer ID Application identity present" "identity missing"
require have_profile "$NOTARY_PROFILE works" "notary profile missing"
require have_ssh_restriction "authorized_keys forces $WRAPPER for the agents' key" "ssh restriction missing"
