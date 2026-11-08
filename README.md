# HackDigest

Hacker News, in your language — a reader built for people who don't read
English comfortably enough to enjoy HN raw.

[![CI](https://github.com/turlamai/hackdigest/actions/workflows/ci.yml/badge.svg)](https://github.com/turlamai/hackdigest/actions/workflows/ci.yml) [![License](https://img.shields.io/badge/license-AGPL--3.0-blue)](LICENSE)

**English** · [中文](README.zh-CN.md)

Hacker News is arguably the best tech front page on the internet — and for
hundreds of millions of developers, a wall of English. HackDigest tears that
wall down: every story, article TL;DR, and comment thread, translated and
digested on demand.

## Start here

All client features are free with your own model key; provider charges apply. Hosted translation is not open for purchase. Desktop previews for macOS, Windows and Linux on Glaze. All three platforms run the native transport by default (HTTP stays the explicit dev adapter) and the release pipeline runs a packaged native selftest on every platform; secret-storage parity is still pending (#2).

[Installation, first use, privacy, backup and recovery](docs/USER-GUIDE.md) · [简体中文](docs/USER-GUIDE.zh-CN.md)

## Download

Grab the latest build from
[GitHub Releases](https://github.com/turlamai/hackdigest/releases/latest) —
every asset is built from source by GitHub CI and launch-smoke-tested on all
three platforms:

| Platform | Artifacts |
|---|---|
| macOS (Apple Silicon / Intel) | `hackdigest-<version>-macos-<arch>.dmg` + portable `.zip` (both architectures) |
| Linux (x64 / arm64) | `hackdigest-<version>-linux-<arch>`: `.tar.gz` + `.deb` + `.rpm` + `.AppImage` + portable `.zip` — every format on both architectures |
| Windows 10/11 (x64) | `hackdigest-<version>-windows-x64.msi` + portable `.zip` |

Every release includes one checked `SHA256SUMS` covering all versioned binaries and the Ed25519-signed `update-manifest.json`. Individual checksum sidecars remain CI artifacts; duplicate versionless installers are not published.

> macOS builds are ad-hoc signed and not notarized: on first launch,
> right-click → Open. The Windows MSI is unsigned, so SmartScreen may show
> a warning on first install — choose More info → Run anyway.

Translation and digests need an LLM API key — set one in Settings (GLM,
DeepSeek, Qwen, Kimi, OpenAI, or a local Ollama; all OpenAI-compatible).

Updates are built in as of v0.3.0: on startup the app fetches an
Ed25519-signed update manifest from GitHub Releases, and portable installs
on macOS and Windows swap themselves in place (with an automatic relaunch).
On Linux the app downloads the archive and reveals it in the file manager
for a hand extraction — the family rule for archive installs. Installer
channels (DMG / MSI / deb / rpm) point you at the Releases page instead:
the app cannot rewrite those without elevation.

## Keyboard-first

HN veterans get their muscle memory back: **j/k** move the selection,
**Enter/o** open, **s** bookmark, **t** translate the selected title,
**r** refresh, **1–6** switch feeds, **/** search. On a story page:
**←/u** back, **t** translate, **Shift+T** translate all comments,
**d** AI digest. Press **?** anytime for the cheat sheet.

## The three digests

1. **Story digest** — the linked article (often 5,000 words of English)
   condensed to a few paragraphs in your language.
2. **Thread digest** — the real gold of HN is the comments. A thread with
   800 replies becomes the top arguments on each side, who said what, and
   where the community landed.
3. **Daily digest** — this morning's front page as a two-minute read in your
   language, before you decide what's worth opening.

## Free / hosted plan

All client features remain free with your own model key; your provider charges and limits apply. Hosted translation/digests are a planned capped subscription, not on sale. No lifetime hosting, device trials, mobile or sync entitlement is included in the launch design. See [PRICING.md](PRICING.md) for target prices, exact account quotas, length limits and cost gates. The hosted config surface in the app (device trials, desktop activation) was removed while hosted is not on sale; legacy hosted settings remap to a working custom endpoint. BYOK keys now default to the OS keyring (Keychain / Credential Manager / Secret Service) with an explicit opt-out; mobile is not a prerequisite.

## Tech stack

**Glaze + React + TypeScript** — a Racket host (via
[Glaze](https://github.com/turlamai/glaze)) serves the React frontend
in the platform webview. One repo: `backend/` + `apps/desktop/` +
`packages/core`. HackDigest is a content app — story pages, rich comment
trees, typeset text — and for content, the web rendering engine is the best
text engine available; the app shell, storage, LLM proxy, and update checks
live in the Racket backend.

- `packages/core` — pure TypeScript, runs everywhere: the HN API client
  (official Firebase API + Algolia search), BYOK presets for any
  OpenAI-compatible endpoint (GLM, DeepSeek, Qwen, Kimi, OpenAI, Claude …)
  so mainland users can plug in a domestically reachable API, and the
  storage/settings layer the components talk to.
- Frontend — React + Vite + zustand + Tailwind 4; progressively-loaded
  feeds and comment trees, light/dark. In-app it talks to the backend over
  the native GLZ1 message channel — no TCP port; `HACKDIGEST_TRANSPORT=http`
  remains the explicit dev adapter, and plain-browser dev keeps an IndexedDB
  fallback.
- Backend — Racket: SQLite storage (kv store, translations, HN item cache —
  a translated thread is never translated twice) plus settings/library data
  files. The translation/digest pipeline (prompt building, 30-title batches,
  comment self-healing bisection) runs here, so LLM API keys stay in the
  backend and never enter the webview; LLM calls stream through the backend
  proxy with retries and a 60-second timeout.
- Network — HN data comes straight from the official
  [Hacker News API](https://github.com/HackerNews/API) and Algolia search —
  no scraping.
- Updates — the backend fetches the Ed25519-signed update manifest on
  startup, verifies the artifact against the signed feed, and swaps
  portable installs in place on macOS and Windows; Linux installs get the
  downloaded archive revealed, and installer-based installs (DMG / MSI)
  are pointed at the release page.

## Repo layout

```
hackdigest/
├── backend/          Racket host on Glaze: storage, LLM proxy, app shell
├── apps/desktop/     React frontend (built to dist/, served by the host)
├── apps/mobile/      Phase 3
├── packages/core/    shared TypeScript core: HN API, storage, BYOK presets
└── docs/
```

## License & business model

AGPL-3.0 — the client is open source, forever. Hosted translation, digest
compute are the planned hosted subscription. Sync is not included in the launch offer. The source is available for review; users are welcome to
self-host their own keys.
