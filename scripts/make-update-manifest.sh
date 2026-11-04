#!/usr/bin/env bash
# Build and sign update-manifest.json for a HackDigest release — the family
# feed format (taskly/syncpilot): a single self-contained signed wrapper
#   { schema, payload(base64), signature{algorithm: ed25519, key_id, value} }
# whose signature covers the exact payload bytes, so every family client
# (rivet/distribution and glaze/update alike) verifies it.
#
#   scripts/make-update-manifest.sh <tag> <dist-dir> [key-path]
#
#   <tag>       release tag, e.g. v1.1.0 (must match package.json)
#   <dist-dir>  directory containing the release artifacts:
#                 hackdigest-<ver>-macos-arm64.zip   hackdigest-<ver>-macos-x64.zip
#                 hackdigest-<ver>-windows-x64.zip   hackdigest-<ver>-linux-x64.tar.gz
#                 hackdigest-<ver>-linux-arm64.tar.gz
#   <key-path>  Ed25519 private key PEM or DER
#               (default: $UPDATE_KEY_PATH, then
#                ~/.hackdigest/update-signing-key.pem)
#
# Signing runs through the `crypto` package (the libcrypto FFI bundled with
# the Racket distribution), so no system openssl binary is needed — stock
# macOS ships LibreSSL, which cannot do Ed25519 at all. Requires racket with
# glaze and crypto installed (the release publish job provisions both).
set -euo pipefail

TAG="${1:?usage: make-update-manifest.sh <tag> <dist-dir> [key-path]}"
DIST="${2:?usage: make-update-manifest.sh <tag> <dist-dir> [key-path]}"
KEY="${3:-${UPDATE_KEY_PATH:-$HOME/.hackdigest/update-signing-key.pem}}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${TAG#v}"
PKG_VERSION="$(node -p "require('$ROOT/package.json').version")"
[[ "$VERSION" == "$PKG_VERSION" ]] || {
  echo "error: tag $TAG does not match package.json '$PKG_VERSION'" >&2; exit 1; }

for artifact in "$DIST/hackdigest-$VERSION-macos-arm64.zip" \
                "$DIST/hackdigest-$VERSION-macos-x64.zip" \
                "$DIST/hackdigest-$VERSION-windows-x64.zip" \
                "$DIST/hackdigest-$VERSION-linux-x64.tar.gz" \
                "$DIST/hackdigest-$VERSION-linux-arm64.tar.gz"; do
  [[ -f "$artifact" ]] || { echo "error: missing $artifact" >&2; exit 1; }
done
[[ -f "$KEY" ]] || {
  echo "error: missing signing key $KEY (see scripts/update-keys.sh)" >&2; exit 1; }

BASE_URL="${RELEASE_ASSET_BASE_URL:-https://github.com/turlamai/hackdigest/releases/download/$TAG}"
KEY_ID="hackdigest-2026-10"

SCRIPT="$(mktemp /tmp/hackdigest-manifest-XXXXXX.rkt)"
trap 'rm -f "$SCRIPT"' EXIT

cat > "$SCRIPT" <<'RKT'
#lang racket/base
;; args: <version> <base-url> <dist-dir> <repo-root> <key-path> <key-id>
(require crypto
         (only-in crypto/libcrypto libcrypto-factory)
         glaze/update
         json
         net/base64
         racket/file
         racket/format
         racket/list
         racket/string)
(crypto-factories (list libcrypto-factory))

(define version (vector-ref (current-command-line-arguments) 0))
(define base-url (vector-ref (current-command-line-arguments) 1))
(define dist (path->complete-path (vector-ref (current-command-line-arguments) 2)))
(define root (path->complete-path (vector-ref (current-command-line-arguments) 3)))
(define key-path (path->complete-path (vector-ref (current-command-line-arguments) 4)))
(define key-id (vector-ref (current-command-line-arguments) 5))

(define (b64 value) (string-trim (bytes->string/utf-8 (base64-encode value ""))))

;; Accept the PEM (or raw DER) form scripts/update-keys.sh generates.
(define (load-private-key path)
  (define raw (file->bytes path))
  (define der
    (if (regexp-match? #"-----BEGIN" raw)
        (let* ([text (bytes->string/utf-8 raw)]
               [lines
                (for/list ([line (in-list (string-split text "\n"))]
                           #:when (regexp-match? #px"^[A-Za-z0-9+/]+={0,2}$" (string-trim line)))
                  (string-trim line))])
          (base64-decode (string->bytes/utf-8 (string-append* lines))))
        raw))
  (datum->pk-key der 'OneAsymmetricKey))

(define private-key (load-private-key key-path))

;; Release guard: the key signing this manifest must be the one the app
;; embeds, or the release would ship a feed every client rejects.
(define embedded-b64
  (let* ([src (file->bytes (build-path root "backend" "update.rkt"))]
         [m (regexp-match #px"define update-public-key-b64\\s+\"([^\"]+)\""
                          (bytes->string/utf-8 src))])
    (or (and m (second m))
        (error 'make-update-manifest
               "embedded public key not found in backend/update.rkt"))))
(define public-key
  (datum->pk-key (pk-key->datum private-key 'rkt-public) 'rkt-public))
(unless (string=? (b64 (pk-key->datum public-key 'SubjectPublicKeyInfo))
                  embedded-b64)
  (error 'make-update-manifest
         "signing key does not match the public key embedded in backend/update.rkt"))

(define (sha256-file/hex path)
  (bytes->hex-string
   (call-with-input-file path (lambda (in) (digest 'sha256 in)) #:mode 'binary)))

(define (artifact platform architecture file installer)
  (define path (build-path dist file))
  (unless (file-exists? path)
    (error 'make-update-manifest "missing installer: ~a" path))
  (update-artifact platform architecture
                   (string-append base-url "/" file)
                   (string-downcase (sha256-file/hex path))
                   (file-size path)
                   installer
                   '()
                   #f))

;; published-at: RFC 3339, second precision, UTC
(define (published-at)
  (define d (seconds->date (current-seconds) #f))
  (define (p2 n) (~r n #:min-width 2 #:pad-string "0"))
  (format "~a-~a-~aT~a:~a:~aZ"
          (date-year d) (p2 (date-month d)) (p2 (date-day d))
          (p2 (date-hour d)) (p2 (date-minute d)) (p2 (date-second d))))

(define manifest
  (update-manifest "io.glaze.HackDigest"
                   version
                   1
                   'stable
                   (published-at)
                   "0.0.0"
                   #f
                   #t
                   100
                   (list (artifact 'macos 'arm64
                                   (format "hackdigest-~a-macos-arm64.zip" version) 'zip)
                         (artifact 'macos 'x64
                                   (format "hackdigest-~a-macos-x64.zip" version) 'zip)
                         (artifact 'windows 'x64
                                   (format "hackdigest-~a-windows-x64.zip" version) 'zip)
                         (artifact 'linux 'x64
                                   (format "hackdigest-~a-linux-x64.tar.gz" version) 'targz)
                         (artifact 'linux 'arm64
                                   (format "hackdigest-~a-linux-arm64.tar.gz" version) 'targz))))

;; update-manifest->payload-bytes validates the struct against the manifest
;; schema before signing, so a malformed manifest fails the release instead
;; of shipping something every client would reject.
(define payload (update-manifest->payload-bytes manifest))
(define signature (pk-sign private-key payload))
(define wrapper
  (hasheq 'schema 1
          'payload (b64 payload)
          'signature
          (hasheq 'algorithm "ed25519" 'key_id key-id 'value (b64 signature))))

;; Self-check through the client code path: parse the wrapper back and
;; verify the signature before declaring success.
(define-values (rechecked re-payload re-key-id re-signature)
  (read-signed-update-manifest (open-input-bytes
                                (string->bytes/utf-8 (jsexpr->string wrapper)))))
(unless (and (equal? (update-manifest-version rechecked) version)
             (pk-verify public-key re-payload
                        (base64-decode (string->bytes/utf-8 re-signature))))
  (error 'make-update-manifest "self-check failed; refusing to write the manifest"))

(define out-path (build-path dist "update-manifest.json"))
(call-with-output-file out-path
  #:exists 'truncate/replace
  (lambda (out)
    (write-json wrapper out)
    (newline out)))
(printf "manifest: ~a (5 artifacts, key-id ~a)\n" out-path key-id)
RKT

racket "$SCRIPT" "$VERSION" "$BASE_URL" "$DIST" "$ROOT" "$KEY" "$KEY_ID"
