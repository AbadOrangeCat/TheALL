# Third-party components and corresponding source

TheAll 0.1.4's Apple Silicon release includes Ghostty's native terminal engine,
Sparkle, and the dependencies and assets documented below. The original license
texts ship in `TheAll.app/Contents/Resources/ThirdPartyLicenses/` and alongside
the app in the release archive. These components retain their own licenses;
TheAll's license does not replace or restrict their terms.

Portions of this software are copyright © 1996–2023 The FreeType Project
(www.freetype.org). All rights reserved. FreeType is used under the FreeType
License, with its contributed-module notices retained.

## Source downloads

The [v0.1.4 release](https://github.com/AbadOrangeCat/TheALL/releases/tag/v0.1.4)
provides **TheAll-0.1.4-third-party-sources.tar.gz** next to the DMG and ZIP,
at no charge. It contains complete original source archives for gettext 0.24
and z2d 0.10.0, license texts, the exact Ghostty libintl build configuration and
headers, a rebuild recipe, and a copy of the original libintl object archive with debug information
removed (`libintl-no-debug.a`) as a convenience. That binary archive is
supplemental; the complete source is included.

| Component | Original source used | SHA-256 of original source archive |
| --- | --- | --- |
| GNU gettext / libintl 0.24 | [gettext-0.24.tar.gz](https://deps.files.ghostty.org/gettext-0.24.tar.gz) | `c918503d593d70daf4844d175a13d816afacb667c06fba1ec9dcd5002c1518b7` |
| z2d 0.10.0 | [Exact Ghostty package](https://deps.files.ghostty.org/z2d-0.10.0-j5P_Hu-6FgBsZNgwphIqh17jDnj8_yPtD8yzjO6PpHRQ.tar.gz) | `69f21da2efd5ee0937fe55c4d09e48afc4fb2f91a01ef167c8c275ae046797f7` |

Ghostty's source baseline is commit
[`81af65766f319a954a26196b4812d159496d4f00`](https://github.com/ghostty-org/ghostty/tree/81af65766f319a954a26196b4812d159496d4f00).
The source bundle retains the actual `pkg/libintl` and `pkg/apple-sdk` files
used for this build, including the generated configuration. Sparkle is version
2.9.1, commit
[`066e75a8b3e99962685d6a90cdd5293ebffd9261`](https://github.com/sparkle-project/Sparkle/tree/066e75a8b3e99962685d6a90cdd5293ebffd9261).

The `provenance.json` file in
[`Resources/ThirdPartyLicenses`](../Resources/ThirdPartyLicenses/) records the
exact upstream archive/tag/commit for each retained notice and its SHA-256.
Notices from upstream archives are copied verbatim; where a license exists only
inside a source file, its original comment block is retained separately.

## Native dependency and asset inventory

This inventory covers dependencies and resources supplied to the native build.
The linker may remove unused functions; carrying their original notices does
not imply that every optional feature is enabled in TheAll.

| Component | Version or pinned source | Notice in `ThirdPartyLicenses/` |
| --- | --- | --- |
| Ghostty | `81af65766f319a954a26196b4812d159496d4f00` | `Ghostty-LICENSE.txt` (MIT) |
| Sparkle | 2.9.1 | `Sparkle-LICENSE.txt` (full license and incorporated third-party notices) |
| libxev | `34fa50878aec6e5fa8f532867001ab3c36fae23e` | `libxev-LICENSE.txt` |
| libvaxis | `7dbb9fd3122e4ffad262dd7c151d80d863b68558` | `vaxis-LICENSE.txt` |
| zig-objc | `f356ed02833f0f1b8e84d50bed9e807bf7cdc0ae` | `zig-objc-LICENSE.txt` |
| uucode / Unicode / Hoehrmann UTF-8 decoder | 0.2.0 | `uucode/` (all three notices) |
| zf | `3c52637b7e937c5ae61fd679717da3e276765b23` | `zf-LICENSE.txt` |
| z2d / incorporated Cairo and Pixman code | 0.10.0 | `z2d/LICENSE`, `z2d/COPYING` (MPL 2.0 and incorporated notices) |
| GNU gettext libintl | 0.24 | `libintl-COPYING.LIB.txt` (LGPL 2.1 or later) |
| FreeType | 2.13.2 | `FreeType/` (FTL and contributed-module notices) |
| HarfBuzz | 11.0.0 | `HarfBuzz-COPYING.txt` |
| libpng | 1.6.43 | `libpng-LICENSE.txt` |
| zlib | source pinned by Ghostty `pkg/zlib/build.zig.zon` | `zlib-LICENSE.txt` |
| Oniguruma | 6.9.9 | `Oniguruma-COPYING.txt` |
| glslang | source pinned by Ghostty `pkg/glslang/build.zig.zon` | `glslang-LICENSE.txt` (full upstream collection) |
| SPIRV-Cross | source pinned by Ghostty `pkg/spirv-cross/build.zig.zon` | `SPIRV-Cross-LICENSE.txt` |
| Highway | `66486a10623fa0d72fe91260f96c892e41aceb06` | `Highway-LICENSE.txt`, `Highway-LICENSE-BSD3.txt` |
| simdutf | 9.0.0 (version embedded in vendored header) | `simdutf-LICENSE-MIT.txt` |
| Dear ImGui | 1.92.5 docking | `ImGui-LICENSE.txt` |
| Dear Bindings | 0.17 | `DearBindings-LICENSE.txt` |
| Sentry Native | 0.7.8 | `Sentry-LICENSE.txt` |
| Breakpad | `b99f444ba5f6b98cac261cbb391d8766b34a5918` | `Breakpad-LICENSE.txt` (including incorporated notices) |
| Wuffs | source pinned by Ghostty `pkg/wuffs/build.zig.zon` | `Wuffs-LICENSE-MIT.txt` |
| stb image and image resize | Ghostty vendored headers at the above commit | `stb-stb_image.h.LICENSE.txt`, `stb-stb_image_resize.h.LICENSE.txt` (MIT option) |
| Zig runtime | 0.15.2 | `Zig-LICENSE.txt` |
| JetBrains Mono | 2.304 | `JetBrainsMono-OFL.txt` |
| Nerd Fonts Symbols Only | 3.4.0 | `NerdFontsSymbolsOnly-LICENSE.txt`, `NerdFonts-LICENSE.txt` |
| iTerm2 color schemes for Ghostty | release `20260427-153600-5e4d1de` | `Themes-LICENSE.txt` |

## Rebuilding and replacing libintl

The release dynamically links `@rpath/libintl.8.dylib`, bundled at
`TheAll.app/Contents/Frameworks/libintl.8.dylib`. The matching gettext objects
are removed from the release copy of `libghostty.a`; the original vendor
archive is preserved. `scripts/prepare-release-runtime.py` performs this
separation and rejects ambiguous object names and build-machine dependencies.
The dynamic runtime uses the existing gettext 0.24 build, not Homebrew's gettext.

The GNU Lesser General Public License permits modifications to this library,
replacement with an interface-compatible version, and reverse engineering of
the combined work to debug those modifications. TheAll's own license does not
limit those rights. The complete license is included with the application.

After extracting the corresponding-source archive on an Apple Silicon Mac with
Python 3 and Xcode command line tools:

```sh
cd TheAll-0.1.4-third-party-sources
python3 rebuild-libintl.py
```

This builds `build/libintl.8.dylib` from the included gettext source, with the
original source selection and generated headers, a macOS 14 deployment target,
and the same install name and compatibility version as the shipped runtime.
It uses Apple Clang; the original object archive was compiled with Zig 0.15.2.
The rebuild is intended to reproduce the public interface, not byte-identical
object files. Edit the extracted gettext source to make library modifications
and run the same script again.

Replace the runtime in a copy of the app, then sign that modified copy as
required by macOS. The app permits library replacement through its
`com.apple.security.cs.disable-library-validation` entitlement. If re-signing
the full app, sign its credential helper and outer app with the same persistent
local certificate: that helper deliberately validates the app's identity.
A different signing identity creates a different credential-store namespace,
so its connection settings must be entered again. Apple Developer ID membership
is not required to build this library or sign a local modified copy.

## z2d source

The exact z2d 0.10.0 source archive is included, with its original MPL 2.0,
Cairo, and Pixman notices. The covered z2d source files used in this release are
unmodified. Extract `z2d-0.10.0.tar.gz` to inspect or modify them. They remain
available under the MPL 2.0 independently of the larger application's license.

## Release verification

Before distributing a build:

- Keep `ThirdPartyLicenses/` in the app and DMG/ZIP, and upload the corresponding
  source archive next to the binaries in the same release.
- Confirm `otool -L TheAll.app/Contents/MacOS/TheAll` imports
  `@rpath/libintl.8.dylib`; `nm` must not show defined `libintl_*` implementation
  symbols in the app. Check the dylib's minimum macOS version and dependencies.
- Preserve all upstream license texts and the source-archive SHA-256 entries.
- When updating Ghostty or a dependency, refresh this inventory, notices, and
  corresponding sources from that exact build; do not reuse a version label
  without checking the embedded source.
