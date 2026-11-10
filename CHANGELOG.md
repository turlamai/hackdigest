# Changelog

All notable changes to HackDigest are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning is
semver. The Tauri line's history (v0.1.0–v0.5.1) lives in git history; its
releases and tags were withdrawn.

## Unreleased

### Added

- Flatpak bundles (`hackdigest-<version>-linux-<arch>.flatpak`, x64 and
  arm64) join the Linux release set — the last format of the Linux
  distribution contract (deb+rpm+AppImage+Flatpak+tar.gz). The bundle
  runs the payload against the GNOME 50 runtime; readelf shows the
  payload needs no modules beyond the runtime (glibc + libz only,
  WebKitGTK/GTK3 and OpenSSL 3 ship in the runtime). `SHA256SUMS` now
  covers 18 versioned payloads. A `flatpak-smoke` workflow builds and
  boots the bundle against the latest release whenever `flatpak/` or
  the release pipeline changes.

### Changed

- The release workflow's tag validation now calls
  `scripts/check-release-version.sh` (the same offline gate CI runs on
  every push) instead of an inline copy of the same checks.

## 0.5.0 - 2026-11-10

Maintenance release: a data-robustness fix, the glaze dependency caught
up to its first tagged release, and the product site moves onto the
family design system. No new features; the app's settings schema and
routes are unchanged.

### Fixed

- A UTF-8 BOM in `settings.json` (produced by BOM-emitting editors such as PowerShell 5.1's `Set-Content -Encoding UTF8` or legacy Notepad saves) made `read-json` throw, and the reader's error handler silently turned the whole configuration into an empty map — the provider config vanished with no diagnostics and the startup key migration saw no key. The data-file reader now strips a leading BOM once, for `settings.json` and `library.json` alike, and notes it on stderr (#47, regression-tested).
- Windows WebView2 controller creation failing with `E_ABORT` when several app instances or windows raced the machine-wide `glaze-webview2` user-data folder: absorbed by the glaze v0.18.0 pin (one data folder per process, `GLAZE_WEBVIEW2_DATA_DIR` for a stable cache path) together with automatic retries for transient controller aborts.

### Changed

- The glaze pin flips from the 0.4-era main head (`671ea4d`) to the **v0.18.0** release across CI and release workflows. Runtime deltas absorbed: per-process WebView2 data folders on Windows, atomic directory replacement in the updater, AppImage payload resolution through `$APPDIR`, Applications drop target and unique volume names for plain dmg builds, and a native Windows ARM64 webview backend. Schema compatibility verified (zero breaking changes); all four packaged-native CI legs selftest the v0.18.0 build.
- The product site homepage is rebuilt on the family site-kit (v1.0.3): family design system (terracotta accent, Newsreader display), browser-locale language detection with a persisted override, and a unified download resolver over the real release assets.

### Release infrastructure

- A keep-alive regression test locks in the #40 finding (the reported persistent-connection misframe was a mock artifact — `llm.rkt` opens a fresh connection per request and Racket sends `Connection: close` by default): 30 sequential titles batches against a real keep-alive server with server-side framing/parse assertions.

## 0.4.0 - 2026-11-08

### Added

- Secure BYOK key storage (issue #2 secret-custody slice): the key moves out of plain `settings.json` into the system keyring — macOS Keychain (SecItem), Windows Credential Manager (CredWriteW/CredReadW), Linux Secret Service (libsecret) — behind a product-side FFI (`backend/secure-store.rkt`). Startup migration moves an existing plaintext key into the keyring, or stamps an explicit `apiKeyStorage: "plaintext-optout"` marker when no keyring is available (never silently). Settings gains a status row (keyring / plaintext opt-out) with move/opt-out actions over the new `POST /api/settings/key-storage` route, plus a clear-saved-key button; hosted license keys are exempt (visible by design). Red-green artifact-scan tests: a canary key is written, migrated, and every file under the data dir scanned — green proves zero plaintext residue with resolution still working, red proves the scan catches the pre-migration leak. CI exercises the logic against an in-memory store; the real keyring FFIs are validated on the family VMs per platform.

- Commit the real backend Glaze schema baseline and project manifest, with a CI compatibility check that imports the API without opening a window or database. Document the current delivery priorities and bounded hosted-usage policy.
- `HACKDIGEST_SELFTEST=1` self-terminating launch assertion: the packaged app must open its WebView, render the served page from the controlled origin, and composite pixels (title poll + capture) before exiting 0; any failure or timeout exits non-zero with no browser fallback. Release CI runs it on every platform against the packaged artifact (app bundle, dist tree, MSI exe, AppImage), then re-probes the HTTP adapter (`HACKDIGEST_TRANSPORT=http`) over loopback.

### Changed

- Remove the superseded hosted config surface (issue #2 free-product gate check): the "HackDigest Pro（托管）" provider preset, license-key activation, device-bound 7-day trial, and the trial/lifetime/pro quota panel are gone while hosted remains not on sale, per the `2026-10-v2` pricing decision and the `2026-10-auth-1` authorization decision (account-bound entitlements, no desktop activation lease, no per-device trials). Legacy settings with `providerId: "hosted"` remap on load to a working custom endpoint (same base URL / key / model; cached `hostedStatus` dropped), and the auto-translate toggles that were stranded inside the hosted-only settings branch are now visible for every provider. `raco` backend untouched: the settings mask exception for legacy hosted keys stays until secure-storage migration.
- Native transport is the default on all three platforms — the packaged-native switch of the Glaze 1.0-plan G4 cycle closes the consumer transport gap (#2). `HACKDIGEST_TRANSPORT=http` remains the explicit development adapter; `GLAZE_API_TOKEN` applies to that adapter only. CI and release installs now pin Glaze at the main head that carries the G4 native-host conformance matrix (flip to the next tagged release when it exists).


### Fixed

- The key-storage route returned `migrated: null` for both no-op and refusal, so the settings page could show a fake success on machines with a locked or missing keyring; it now raises a user error the page can render.
- Every page-initiated non-streaming chat failed with an llm-contract internal error: the page always sent `maxTokens: null`, which arrived as the `'null` symbol and violated the contract; `chat-opts-from-jsexpr` now centralizes null-safe option parsing for both chat routes.

### Release infrastructure

- The CI packaged-native matrix now mirrors the shipped macOS flavors natively (arm64 on `macos-latest`, x64 on `macos-15-intel`) instead of selftesting an x86_64 build under Rosetta — the per-commit gate now exercises the flavors users actually receive.
- The Windows HTTP-adapter smoke runs on a fresh runner: the selftest instance can wedge mid-exit on GitHub runners (GPU-less teardown hang, filed upstream as glaze#124) and keep the single-instance mutex alive for minutes, which no cleanup script can reliably beat. The mutex-gated cleanup (`taskkill /F /T` + `Mutex.OpenExisting` probes) stays in the smoke's retry loop as defense.
- Transient-failure retries for the DMG `hdiutil attach` verification and the appimagetool digest fetch.

## 0.3.1 - 2026-10-14

Alignment release: the docs catch up with what v0.3.0 already ships, the
site joins the family dark-mode baseline, and the updater's download loop
gains a watchdog. No app-facing behavior changes beyond the hardening.

### Added

- Download watchdog in the updater: a transfer that stops making byte
  progress for 120 seconds, or that runs past a 30-minute wall-clock
  total, is broken out of its worker (`exn:break`), the `.partial` file is
  cleaned up, and the phase lands on error — the UI always gets a terminal
  state instead of resting on "downloading" forever.
- User guide: `docs/guide.html` on the product site — five-minute start,
  engine and BYOK setup, reading preferences, shortcuts, and FAQ
  (data location, privacy, platforms, updates incl. the 0.2.x path,
  uninstall). Bilingual via `data-i18n`, default Chinese.

### Changed

- README (English and Chinese) now describes the updater as it actually
  works since v0.3.0: startup fetch of the Ed25519-signed manifest,
  in-place swap on macOS/Windows portable installs, download-and-reveal on
  Linux, release page for installer channels — replacing the stale
  "in-place updates wait on glaze#47" wording. The download table shows
  the real v0.3.0 Linux matrix (tar.gz / deb / rpm / AppImage / zip, every
  format on both architectures, per-asset `.sha256` sidecars).
- CI and release workflows pin glaze to `v0.13.1` (`.git`-suffixed URL)
  instead of a floating branch install.
- Product site: palette aligned to the family values (`#faf7f2` /
  `#c15f3c` / `#e8e2d9` …), full dark mode with a manual toggle,
  localStorage persistence and a head anti-flash script, and download
  copy that matches the real update flow. `docs/GLAZE-MIGRATION.md` is
  marked as completed with a pointer to the CHANGELOG.

## 0.3.0 - 2026-10-11

Linux packaging closes the family benchmark gap format-for-format, and every
binary asset now carries a per-asset `.sha256` sidecar.

### Added

- Linux `.rpm` packages for x64 and arm64
  (`hackdigest-<version>-1-linux-x86_64.rpm`, `...-aarch64.rpm`),
  hand-rolled with `rpmbuild` from a generated spec that mirrors the deb
  layout (`/opt/hackdigest`, a `hackdigest` launcher, desktop entry,
  pixmaps icon) and rivet's recipe: no `%dist` tag and the libtinfo
  dependency exclusion that keeps the Ubuntu-built Racket runtime
  installable on Fedora. `Requires` names what the runtime FFI-loads
  (gtk3, webkit2gtk4.1, openssl-libs, xdg-utils)
- Linux `.zip` portable archives for both architectures — the same
  self-contained tree the tar.gz carries
- The AppImage now ships for arm64 too (per-arch `appimagetool` binary,
  same digest-verified fetch), with the launch smoke running on both
  architectures
- The signed update feed carries a Linux arm64 tar.gz entry, so arm64
  installs get in-app updates

### Changed

- Every binary asset on every platform ships a per-asset `.sha256`
  sidecar (macOS dmg/zip, Windows msi/zip, and the full Linux set);
  `SHA256SUMS` continues to aggregate them

## 0.2.0 - 2026-10-10

Linux packaging parity: the Linux line gets first-class installer assets,
matching the family bar on macOS and Windows. Nothing about the update feed
or the in-app updater changes — these are installer assets published beside
the portable tar.gz.

### Added

- Linux `.deb` packages for x64 and arm64, hand-rolled with `dpkg-deb`:
  the app installs to `/opt/hackdigest` with a `hackdigest` launcher on
  `PATH`, a desktop menu entry, and hicolor icons. `Depends` names what
  the runtime actually FFI-loads (WebKitGTK, GTK 3, OpenSSL 3 for the
  updater's signature checks, xdg-utils) instead of a laundry list, and
  release CI installs the package into a clean `ubuntu:22.04` container
  to prove the dependency set is sufficient.
- Linux AppImage (x64), assembled with `appimagetool` from the same
  distribution directory — same system-WebKitGTK requirement as the
  tar.gz and deb, so it stays honest about what it bundles.
- Linux arm64 builds: the release pipeline now runs its Linux leg on a
  native arm64 runner, shipping `hackdigest-<version>-linux-arm64.tar.gz`
  and `.deb` beside the x64 ones. Arm64 is an installer asset only for
  now — the signed update feed still carries the x64 tar.gz.

### Changed

- Release assets follow the family naming on Linux too:
  `hackdigest-<version>-linux-<arch>.<ext>` now covers `.tar.gz`, `.deb`
  and `.AppImage`, all covered by `SHA256SUMS` and build-provenance
  attestations.

## 0.1.0 - 2026-10-10

The in-app updater (R3 of the Glaze migration) and the 0.x epoch reset:
HackDigest can now update itself end to end, closing the gap v1.0.1
documented as "open the release page". The 1.x line's releases and tags
are withdrawn as the whole family enters its 0.x stage.

### Added

- Full update flow on portable installs: the backend fetches the release's
  Ed25519-signed `update-manifest.json`, verifies it against the embedded
  key, downloads this platform's artifact with a progress indicator, checks
  size and SHA-256 against the signed feed, and swaps the install:
  - macOS portable `.app`: ditto-unpack, atomic bundle swap with a
    `.old` backup, automatic relaunch.
  - Windows portable zip: unpack beside the install dir, `cmd` handover
    (waits for the app to exit, `.old` swap, restart); failures leave a
    marker that the next launch reports.
  - Linux: the downloaded tar.gz is revealed in the file manager — extract
    it over the app folder by hand (family rule for archive installs).
- Settings → About now offers the same flow with live progress; the
  startup banner drives it too.
- Release pipeline: `scripts/make-update-manifest.sh` signs the update
  feed from the portable artifacts before publishing (key supplied via the
  `UPDATE_ED25519_PRIVATE_KEY` secret; releases without it fall back to
  release-page-only updates), and the release workflow gained a
  concurrency group.

### Changed

- Updating honestly, by install type: portable macOS/Windows installs
  update in place; DMG/MSI installs point at the release page (the app
  cannot rewrite itself there without elevation); Linux downloads and
  reveals the archive. The check falls back to the v1.0-style
  release-page behavior whenever no signed manifest is published.
- Settings → About shows the packaged version reported by the backend
  (it previously showed a stale build number).

## 1.0.1 - 2026-10-09

Packaging-hygiene release — no app-behavior changes beyond honest update
wording.

### Added

- macOS builds now cover both architectures: Apple Silicon (arm64) and
  Intel (x64), each shipped as an installer `.dmg` and a portable `.app`
  `.zip`.
- Windows ships a portable `.zip` (the same payload the MSI installs,
  runnable from anywhere) beside the MSI.
- Linux release builds now run a packaged-app launch smoke under xvfb
  (API health + frontend served), the same bar macOS and Windows already
  held.

### Changed

- Release assets renamed to the family convention — all-lowercase
  `hackdigest-<version>-<os>-<arch>.<ext>`, with the macOS DMG
  arch-suffixed (`-macos-arm64` / `-macos-x64`) instead of the previous
  `HackDigest-v<version>-*` scheme.
- Update wording now says what the current updater actually does: detect a
  new version on startup and open the GitHub release page in your browser.
  Site, README, and in-app copy no longer imply in-app install/auto-update;
  the in-place updater is tracked upstream as glaze#47.

Install caveats carried over from 1.0.0: macOS builds are ad-hoc signed and
not notarized (right-click → Open on first launch); the Windows MSI is
unsigned (SmartScreen may warn — More info → Run anyway); Linux needs
libwebkit2gtk-4.1 present.

## 1.0.0 - 2026-10-09

First release of the Glaze line, on all three desktop platforms: macOS
(Apple Silicon) `.dmg`, Windows 10/11 (x64) `.msi`, and Linux (x64)
`.tar.gz`.

### Added

- Full backend rebuild on Glaze: the Tauri/Rust host is replaced by a Racket
  backend (`backend/`) serving the unchanged React frontend over HTTP —
  SQLite with the same schema (kv / translations / hn_items, WAL), settings
  and library JSON data files, window-state persistence, single-instance
  guard, external links in the default browser, and an HttpOnly-cookie
  WebView token.
- Translation and digest orchestration moved into the backend: prompt
  building, 30-title feed batches, comment-thread translation with
  self-healing bisection (20 per batch, two workers, failing batches split
  to single items), and the three digest prompts with daily-digest caching —
  streamed to the frontend over the same incremental protocol.
- LLM proxy: OpenAI-compatible streaming endpoint with the retry table
  (json-mode fallback on 400/422, one retry after 3 s on 429) and a 60-second
  per-round timeout. API keys configured in Settings are stored and used
  entirely backend-side — the webview never sees the key (BYOK fields render
  as a `__SAVED__` mask).
- One-time, idempotent migration of Tauri-era data (site.jrtx.hackdigest →
  sibling hackdigest directory, read-only copy).
- Windows installer: a WiX MSI built from the same packaged distribution,
  with a stable upgrade identity (`TuringLambda.HackDigest`) so in-place
  upgrades work from this first release on. Release CI validates the MSI
  (WiX validation + decompiled metadata) and smoke-tests the packaged
  binary (API health + frontend served) on all three platforms.
- Update check against GitHub Releases on startup with a go-to-download
  banner (the one-click updater returns in a later release).

### Changed

- Frontend components are unchanged; only the bridge layer was rewritten
  (fetch + streaming reader replacing Tauri `invoke`), with an IndexedDB
  fallback for plain-browser development.
- Feed-title translation now returns per request instead of per-30-item
  callback batches.

### Removed

- The Tauri 2 / Rust host (`src-tauri/`) and the in-place auto-update
  pipeline (minisign) that depended on it.
