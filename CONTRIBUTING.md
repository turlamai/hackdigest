# Contributing to HackDigest

Thank you for looking under the hood. HackDigest is free software
(AGPL-3.0, see [LICENSE](LICENSE)): by submitting a pull request you
agree your contribution is licensed under AGPL-3.0.

## Ground rules

1. **The glaze schema is the contract.** `glaze.rktd` and
   `glaze-schema.json` own the reviewed application contract between
   the Racket backend and the hosts. Before changing routes run
   `raco glaze schema check --json`; update the baseline only for an
   intentional reviewed contract change, in the same commit.
2. **Native transport is the product.** All three platforms default to
   the native webview; `HACKDIGEST_TRANSPORT=http` is the explicit dev
   adapter (`GLAZE_API_TOKEN` applies to that adapter only). Do not
   replace a failed native WebView with an external browser. The
   release pipeline runs a packaged native selftest
   (`HACKDIGEST_SELFTEST=1`) on every platform before publishing.
3. **Fail honestly.** A missing keyring degrades only through the
   explicit `plaintext-optout` path; a failed update verification
   aborts the update and the running version keeps working. No silent
   fallbacks.
4. **Privacy is a feature.** Story and comment content goes to the HN/
   Algolia APIs and your configured LLM endpoint and nowhere else;
   bookmarks, history and the translation cache stay in the local
   SQLite database; the BYOK key lives in the system keyring. New
   storage stays under the platform data directory.
5. **The signing contract is guarded, not remembered.**
   `scripts/check-release-signing-contract.sh` pins the mandatory
   Ed25519 update feed and the canonical update URLs; never weaken it,
   and extend it when a new file joins the update path.
6. **Bilingual is one product.** `README.zh-CN.md` and
   `docs/USER-GUIDE.zh-CN.md` must keep reciprocal updates with their
   English counterparts whenever installation, privacy, prices or
   supported platforms change.
7. **Tests pin contracts.** If you change behavior a test covers,
   change the test in the same commit and say why.

## Before you push

```bash
raco test backend/                                  # backend contract tests
raco glaze schema check --json                      # application schema
pnpm test                                           # frontend unit tests
pnpm check                                          # type-check
pnpm build                                          # frontend build
bash scripts/check-release-signing-contract.sh      # update-origin guard
bash scripts/check-release-version.sh               # version consistency gate
```

These mirror the CI `frontend` and `backend` jobs. First-time setup
installs the pinned Glaze (`v0.18.0`) and crypto packages. The
packaged-native matrix compiles per platform in its own CI job; if you
touch the packaging or platform paths, say whether you were able to
build locally.

## Product site

`docs/` is the published product site: GitHub Pages serves it straight
from `main` (`/docs`, CNAME `hackdigest.jrtx.site`), so a push to main
is a site deploy. Keep `docs/` self-contained — site-kit assets live in
`docs/fonts/` and `docs/assets/`, versions pinned in `site-kit.version`
— and never edit the generated `family.css` / `family.js` per-site;
they come from [site-kit](https://github.com/turlamai/site-kit).
`CNAME` must not move, and links stay relative: the site runs at a
subdomain root.

## Reporting issues

Include: OS + version, HackDigest version, installation shape (DMG /
portable zip / MSI / deb / rpm / AppImage / tar.gz),
steps to reproduce, and for translation/digest issues the provider,
model and the error text from the banner. Security issues go through
[SECURITY.md](SECURITY.md), not public issues.
