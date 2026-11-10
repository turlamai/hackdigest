#!/usr/bin/env bash
# Offline version gate: every place that states the release version must
# agree — the VERSION file, package.json, the backend app-version and the
# CHANGELOG section — and the git tag (when releasing) must agree too.
# Mirrors the release.yml validate job so the contract runs on every
# push/PR instead of only at tag time.
#   bash scripts/check-release-version.sh            -> internal consistency only
#   bash scripts/check-release-version.sh v1.2.3     -> tag must match too
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# VERSION file: bare semver on a single line, newline-terminated.
grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' VERSION || {
  echo "::error::VERSION must be bare semver (x.y.z)" >&2; exit 1; }
[ "$(tail -c 1 VERSION | wc -l)" -eq 1 ] || {
  echo "::error::VERSION must end with a newline" >&2; exit 1; }
file_version="$(cat VERSION)"

root_version="$(node -p "require('./package.json').version")"
backend_version="$(sed -n 's/.*(define app-version "\([^"]*\)").*/\1/p' backend/main.rkt)"
[ -n "$backend_version" ] || { echo "::error::backend/main.rkt has no app-version"; exit 1; }

version="$root_version"
agree() { # source actual
  [ "$2" = "$version" ] || { echo "::error::$1 ($2) != package.json ($version)"; exit 1; }
}
agree "VERSION" "$file_version"
agree "backend app-version" "$backend_version"
grep -q "^## $version" CHANGELOG.md || {
  echo "::error::CHANGELOG.md has no '## $version' section"; exit 1; }

if [ $# -ge 1 ]; then
  tag="${1#v}"
  [ "$tag" = "$version" ] || {
    echo "::error::tag $1 does not match repository version $version"; exit 1; }
fi

echo "check-release-version: VERSION / package.json / backend app-version / CHANGELOG agree on $version${1:+ (tag $1)}"
