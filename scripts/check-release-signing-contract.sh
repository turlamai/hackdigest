#!/usr/bin/env bash
# Offline contract guard. The real Ed25519 private key must never enter PR CI.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
release="$ROOT/.github/workflows/release.yml"
backend="$ROOT/backend/update.rkt"
signer="$ROOT/scripts/make-update-manifest.sh"
require() { grep -Fq -- "$1" "$release" || { echo "missing release guard: $1" >&2; exit 1; }; }
require 'Require Ed25519 update signing secret before packaging'
require "if: github.event_name == 'push'"
require 'Sign and require trusted update feed (update-manifest.json)'
require 'scripts/make-update-manifest.sh "$GITHUB_REF_NAME" dist "$KEY_PEM"'
require 'test -s dist/update-manifest.json'
require 'refusing unsigned release'
if grep -Fq 'release ships without an update manifest' "$release"; then
  echo 'unsafe optional update manifest fallback remains' >&2; exit 1
fi
grep -Fq 'https://github.com/turlamai/hackdigest/releases' "$backend"
grep -Fq 'https://github.com/turlamai/hackdigest/releases/download' "$signer"
if grep -Fq 'turinglambdaai/hackdigest' "$backend" "$signer"; then
  echo 'legacy update origin remains' >&2; exit 1
fi
echo 'release-signing: mandatory Ed25519 feed and canonical update URLs verified'
