# Security Policy

HackDigest keeps your reading on your machine: stories, bookmarks,
settings and the translation/digest cache live in a local SQLite
database under the platform data directory, and the only network
traffic is fetching Hacker News content, calling *your own* LLM
endpoint, and checking GitHub Releases for updates. Reports are taken
seriously and handled quickly.

## Reporting a vulnerability

Email **security@jrtx.site** (or open a GitHub security advisory on this
repository). Include reproduction steps, affected versions, and your
assessment of impact. You will get an acknowledgment within 72 hours.

Please do not open public issues for security problems.

## Scope

In scope:

- HN fetching and the translation/digest cache: what the app requests
  from Hacker News and Algolia (`packages/core/src/hn.ts`,
  `packages/core/src/algolia.ts`), what it sends to the configured LLM
  endpoint, and what it persists locally (`backend/db.rkt`,
  `backend/translate.rkt`). Story and comment content must go only to
  those two destinations — the HN/Algolia APIs and your LLM provider —
  and the cache to your own disk.
- The LLM API key (bring-your-own): custody in the system keyring
  (`backend/secure-store.rkt` — macOS Keychain via SecItem, Windows
  Credential Manager via advapi32, Linux via libsecret), the explicit
  `plaintext-optout` degradation path when no keyring exists, and its
  use as a Bearer credential sent only to the base URL you configured
  (`backend/llm.rkt`). Silently falling back to plaintext storage
  without the explicit opt-out is a bug.
- Update trust: verification of the Ed25519-signed
  `update-manifest.json`, artifact digest/size checks against the
  signed manifest, and key handling (`backend/update.rkt`,
  `backend/update-check.rkt`, `scripts/make-update-manifest.sh`,
  `scripts/update-keys.sh`; key id `hackdigest-2026-10`). The update
  channel resolves against the canonical `turlamai/hackdigest` GitHub
  Releases; anything that would redirect it elsewhere is a bug.
- The host/backend boundary: hosts render and drive the flow; the
  Racket backend (`backend/main.rkt`, contract in `glaze.rktd` /
  `glaze-schema.json`) decides. Crypto or policy sneaking into a host
  is a bug.

Out of scope: Hacker News / Algolia availability and content, and the
LLM provider's own handling of the prompts you send it — those belong
to the respective services.

## Design notes reviewers should know

- **The backend owns no public network listener.** The production
  transport is the native GLZ1 page served to the embedded webview;
  the explicit HTTP adapter is a development surface gated by
  `GLAZE_API_TOKEN`, loopback only.
- **Hosts never implement crypto.** The Ed25519 signature check, the
  SHA-256/size verification and the trust decision live in the Racket
  backend (glaze/update over the crypto package's libcrypto FFI);
  hosts only carry out installation steps the backend has verified.
- **Updates and installer trust are different layers.** The updater
  verifies the signed manifest and the downloaded artifact's size and
  SHA-256 before any swap. Portable installs on macOS and Windows swap
  themselves in place; on Linux the app downloads the archive and
  reveals it for hand extraction; installer channels (DMG / MSI / deb
  / rpm) point you at the Releases page — the app cannot rewrite those
  without elevation.
- The signed update feed **does not imply a publisher-signed
  installer**. macOS builds are ad-hoc signed (not notarized) and the
  Windows MSI is unsigned; releases publish a checked `SHA256SUMS`
  covering every versioned package plus the signed
  `update-manifest.json`, and CI publishes build provenance
  attestations. Do not represent the feed signature as an
  independently trusted publisher identity.
- Local data is a plain SQLite file (plus exports you create) under
  the platform data directory (`HACKDIGEST_DATA_DIR`). It is not
  encrypted; protection ultimately depends on OS user permissions and
  filesystem protection. Nothing here is telemetry: bookmarks,
  history and caches stay on disk and are never uploaded anywhere.

## Supported versions

Security fixes land on `main` first and ship with the next tagged
release. During the 0.x preview there is no LTS branch.
