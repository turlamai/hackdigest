#!/usr/bin/env bash
set -euo pipefail
key="$(realpath "$1")"
cd "$(dirname "$0")/.."
expected="$(python3 -c 'import re,pathlib; print(re.search(r"""define update-public-key-b64\s+"([^"]+)" """.strip(), pathlib.Path("backend/update.rkt").read_text()).group(1))')" 
actual="$(openssl pkey -in "$key" -pubout -outform DER | openssl base64 -A)"
[[ -n "$expected" && "$actual" == "$expected" ]] || { echo "Update key mismatch" >&2; exit 1; }
echo "Update key matches embedded trust root"
