# Third-party notices

HackDigest builds on the components below. Each entry names where the
component enters the shipped artifacts and the license it is
distributed under; consult the upstream license files for full terms.
The Glaze toolchain is a first-party TurLamAI project consumed as a
pinned package — not third-party code — so it is not listed here.

## Racket CS runtime

Every platform package embeds the statically linked Racket CS runtime
([racket/racket](https://github.com/racket/racket), 9.x). Racket is
distributed under the MIT license and the Apache License 2.0, at your
option; the Racket CS runtime system additionally embeds Chez Scheme,
distributed under the Apache License 2.0 (per Racket's `LICENSE.txt`).

## crypto (Racket package) and libcrypto

The updater verifies manifests through the
[racket/crypto](https://github.com/racket/crypto) package, licensed
under the MIT license and the Apache License 2.0, at your option,
driving the libcrypto library over FFI. On Linux the deb / rpm / tar.gz /
AppImage shapes take OpenSSL from the distribution (OpenSSL 3.x is
licensed under the Apache License 2.0; the deb `Depends` and rpm
`Requires` declare it); on macOS and Windows the libcrypto shipped
with the Racket distribution is used, carrying its own upstream terms.

## WebKitGTK and GTK (Linux)

The Linux host renders in a native WebKitGTK window. WebKitGTK and
GTK are licensed under the GNU Lesser General Public License, version
2.1 or later, and are not bundled: every Linux shape (deb / rpm /
tar.gz / AppImage / portable zip) takes them from the distribution as
runtime dependencies (the deb `Depends` and rpm `Requires` declare the
minimum set).

## WebView2 Loader (Windows)

The Windows host renders in the system's Microsoft Edge WebView2
runtime (an evergreen OS component, not shipped here) and packages the
WebView2Loader.dll from the Microsoft Windows App SDK
([microsoft/WindowsAppSDK](https://github.com/microsoft/WindowsAppSDK)),
licensed under the MIT license. The WiX toolset builds the MSI at
release time and does not ship inside it.

## React, React DOM and Zustand

The frontend is a React application; the built assets are served
inside the packaged app. React and React DOM
([facebook/react](https://github.com/facebook/react)) and Zustand
([pmndrs/zustand](https://github.com/pmndrs/zustand)) are licensed
under the MIT license.

## Build-time tooling (not shipped)

Vite, TypeScript, Tailwind CSS, Vitest and jsdom (all MIT) run only at
build/test time and contribute no code to the release artifacts; the
CSS Tailwind generates is HackDigest's own payload.
