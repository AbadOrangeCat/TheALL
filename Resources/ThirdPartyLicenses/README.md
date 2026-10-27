# Third-party software in TheAll 0.1.5

TheAll includes the Ghostty terminal engine, the Sparkle updater, and third-party
libraries and assets. The original license texts in this directory apply to
those components independently of TheAll's own license. Original copyright
statements have been retained. `provenance.json` records each license's exact
source and SHA-256 hash.

Portions of this software are copyright © 1996–2023 The FreeType Project
(www.freetype.org). All rights reserved. TheAll uses FreeType under the FreeType
License in `FreeType/FTL.TXT`; notices for its contributed modules are retained.

## Corresponding source and replacement rights

The GNU gettext **libintl 0.24** runtime is distributed as the separate,
replaceable `TheAll.app/Contents/Frameworks/libintl.8.dylib`, under the GNU Lesser
General Public License version 2.1 or later. The license is in
`libintl-COPYING.LIB.txt`. You may modify this library, replace it with an
interface-compatible version, and reverse-engineer the combined work to debug
such modifications, as provided by that license. TheAll's own license does not
limit those rights. Re-signing a locally modified application may be required
by macOS; no Apple-issued certificate is required to build the replacement.

The z2d **0.10.0** rendering library is used under the Mozilla Public License 2.0,
with its included Cairo and Pixman notices. Its license texts are in `z2d/`.
The corresponding z2d source files are unmodified.

The versioned release provides `TheAll-0.1.5-third-party-sources.tar.gz` alongside
the application downloads, at no charge:

https://github.com/AbadOrangeCat/TheALL/releases/tag/v0.1.5

The source archive includes the complete original gettext 0.24 source archive,
the exact z2d package used by Ghostty, license texts, Ghostty's libintl headers
and build configuration, and instructions for rebuilding and replacing libintl.
See also the repository's `docs/third-party-components.md` for exact source
URLs, hashes, and the native component inventory.

The bundled fonts retain their upstream font licenses. The full Sparkle license
also contains its incorporated third-party notices. No third-party project is
represented as endorsing TheAll.
