#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns
#
# One-time setup of the agent signing identity on the signing host.
#
# Run it as the `signer` user, in a terminal, because the portal steps need
# the Account Holder's sign-in. `--check` changes nothing and reports each
# step's state. Environment for a full run:
#   API_KEY_PATH, API_KEY_ID, API_ISSUER  App Store Connect API key (notarization)
#   AGENT_PUBKEY_PATH                     public key of the agents' ssh key
set -euo pipefail

KEYCHAIN="agent-signing.keychain-db"
NOTARY_PROFILE="agent-notary"
WRAPPER="/usr/local/libexec/sign-release"
CHECK=0
[[ ${1:-} == "--check" ]] && CHECK=1

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
have_profile() {
  xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" \
    --keychain "$KEYCHAIN" >/dev/null 2>&1
}
have_ssh_restriction() {
  grep -qs "command=\"$WRAPPER\",restrict" "$HOME/.ssh/authorized_keys"
}
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
for tool in security xcrun openssl; do
  command -v "$tool" >/dev/null || die "$tool is missing"
done
ok "macOS with security, xcrun and openssl"
ME=$(id -un)
if [[ ${ME} == "signer" ]]; then
  ok "running as signer"
else
  todo "run as the signer user (this is ${ME})"
  ((CHECK)) || die "refusing to create the keychain as ${ME}"
fi

if ((CHECK)); then
  step "Keychain"
  report have_keychain "$KEYCHAIN exists" "create $KEYCHAIN"
  step "Identity"
  report have_identity "Developer ID Application identity present" \
    "generate the key, upload the request, import the certificate"
  step "Notary profile"
  report have_profile "$NOTARY_PROFILE works" "store $NOTARY_PROFILE"
  step "Agent ssh key"
  report have_ssh_restriction "authorized_keys forces $WRAPPER" \
    "restrict the agents' key to $WRAPPER"
  exit 0
fi

: "${API_KEY_PATH:?set API_KEY_PATH}" "${API_KEY_ID:?set API_KEY_ID}"
: "${API_ISSUER:?set API_ISSUER}" "${AGENT_PUBKEY_PATH:?set AGENT_PUBKEY_PATH}"
read -rsp "New keychain password: " KEYCHAIN_PASSWORD
echo

step "1. Dedicated keychain, no auto-lock"
if have_keychain; then
  ok "$KEYCHAIN exists"
else
  security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
  security set-keychain-settings "$KEYCHAIN"
fi
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"

step "2. Key pair and certificate signing request"
# The key passes through a file for a moment. umask 077 keeps it private to
# signer, and the trap removes it at once, including on failure.
WORK=$(mktemp -d)
trap 'rm -P "$WORK"/* 2>/dev/null || true; rmdir "$WORK" 2>/dev/null || true' EXIT
(
  umask 077
  openssl genrsa -out "$WORK/key.pem" 2048 2>/dev/null
  openssl req -new -key "$WORK/key.pem" -subj "/CN=agent-signing" \
    -out "$HOME/agent-signing.csr"
)
# -x marks the imported private key non-extractable.
security import "$WORK/key.pem" -k "$KEYCHAIN" -x -T /usr/bin/codesign
printf 'Request written to %s\n' "$HOME/agent-signing.csr"
echo "Upload it in the Apple Developer portal as a Developer ID Application"
echo "certificate, then download the certificate."
read -rp "Path to the downloaded .cer: " CER_PATH

step "3. Import the certificate"
security import "$CER_PATH" -k "$KEYCHAIN"

step "4. Only Apple's tools use the private key without a prompt"
security set-key-partition-list -S apple-tool:,apple: -s \
  -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null

step "5. Notarization credential"
xcrun notarytool store-credentials "$NOTARY_PROFILE" \
  --key "$API_KEY_PATH" --key-id "$API_KEY_ID" --issuer "$API_ISSUER" \
  --keychain "$KEYCHAIN"

step "6. Restrict the agents' ssh key to the wrapper"
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
AGENT_PUBKEY=$(<"$AGENT_PUBKEY_PATH")
printf 'command="%s",restrict %s\n' "$WRAPPER" "$AGENT_PUBKEY" \
  >>"$HOME/.ssh/authorized_keys"
chmod 600 "$HOME/.ssh/authorized_keys"

step "Result"
require have_identity "Developer ID Application identity present" "identity missing"
require have_profile "$NOTARY_PROFILE works" "notary profile missing"
