# HackDigest user guide

**English** · [简体中文](USER-GUIDE.zh-CN.md)

Read Hacker News with on-demand title translation, article digests and thread summaries.

## Availability

All client features are free with your own model key; provider charges apply. Hosted translation is not open for purchase.

## Platforms and installation

Desktop previews for macOS, Windows and Linux on Glaze. All three platforms run the native transport by default — HTTP is the explicit dev adapter (`HACKDIGEST_TRANSPORT=http`) — and release CI packaged-native selftests every platform. Model API keys are stored in the system keyring by default (macOS Keychain, Windows Credential Manager, Linux Secret Service), with an explicit plaintext opt-out.

Use [official Releases](https://github.com/turlamai/hackdigest/releases), select an explicitly listed OS/architecture asset, read its release notes and check supplied checksums. An absent asset/platform is not a delivery promise. Preview builds may lack publisher signing or notarization; do not disable system-wide security protections to install them.

## Your first successful session

1. Open a feed and read one story in its original form.
2. If you want translation, configure your own compatible model endpoint/key and test one title first.
3. Request one article or thread digest, compare it with the original and review provider usage before starting bulk requests.

## Data, backup and recovery

Back up local settings/bookmarks and the application data directory after quitting. Translation caches may contain article/comment text; settings contain your API key only if you explicitly opted out of the system keyring. Inspect backups before syncing or sharing them.

## Network, keys and privacy

Feeds/search contact HN and search services. Translation and summaries send requested titles, article text or comments to your configured model provider. AI summaries can omit context or make errors; open the original source for verification.

## Known limits

If the system keyring is unavailable (for example a locked Linux collection), the app keeps the key in `settings.json` and marks the choice explicitly (`plaintext-optout`) instead of failing silently; Settings shows which storage is active and offers move/opt-out actions. No mobile or hosted-sync service is included.

## Updates and removal

Back up data and read the destination release notes first. An in-app update check does not necessarily install an update for your channel; follow the manual for portable, installer and source paths. Never bypass a failed signature check or replace the program with an untrusted artifact. On failure, preserve data and the error, then recover with a trusted release. Removing the program does not necessarily erase its separate data directory; verify your backup before deleting personal data.

## Get help

Report problems in [GitHub Issues](https://github.com/turlamai/hackdigest/issues), in English or Chinese. Include the version, OS/architecture, installation channel, steps, expected result and actual result. Reproduce with synthetic input first; do not attach keys, credentials, databases, private source documents or complete logs. Public support has no guaranteed response time.

## Further reading

- [Detailed manual](../site/guide.html)
- [Project overview and development](../README.md)
- [Current licence](../LICENSE)
