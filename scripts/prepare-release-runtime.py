#!/usr/bin/env python3
"""Separate gettext from a Ghostty archive for a replaceable macOS runtime.

Use the libintl.a produced by the SAME Ghostty build as libghostty.a.
Original vendor artifacts are never modified. See docs/third-party-components.md.
"""
import argparse
import collections
from pathlib import Path
import shutil
import subprocess
import tempfile


def output(*command):
    return subprocess.check_output(command, text=True).strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--ghostty', type=Path, required=True)
    parser.add_argument('--intl', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    ghostty, intl, destination = args.ghostty.resolve(), args.intl.resolve(), args.output.resolve()
    if destination.exists():
        parser.error('Output directory must be new; existing build artifacts are preserved.')
    for archive in (ghostty, intl):
        if output('lipo', '-archs', str(archive)) != 'arm64':
            parser.error('This release recipe expects arm64 archives from the same build.')
    members = [name for name in output('ar', '-t', str(intl)).splitlines() if name.endswith('.o')]
    counts = collections.Counter(output('ar', '-t', str(ghostty)).splitlines())
    if not members or len(set(members)) != len(members) or any(counts[name] != 1 for name in members):
        parser.error('Cannot uniquely identify the gettext objects in the Ghostty archive.')
    destination.mkdir(parents=True)
    stripped = destination / 'libghostty.a'
    shutil.copy2(ghostty, stripped)
    subprocess.run(['ar', '-d', str(stripped), *members], check=True)
    subprocess.run(['ranlib', str(stripped)], check=True)
    library = destination / 'libintl.8.dylib'
    clang = output('xcrun', '--find', 'clang')
    sdk = output('xcrun', '--sdk', 'macosx', '--show-sdk-path')
    # Zig archives can use four-byte member alignment; Apple ld expects eight.
    # Linking the same objects directly avoids rewriting any of their code.
    with tempfile.TemporaryDirectory(prefix='theall-intl-objects-') as temporary:
        subprocess.run(['ar', '-x', str(intl)], cwd=temporary, check=True)
        objects = [str(Path(temporary) / name) for name in members]
        for obj in objects:
            Path(obj).chmod(0o644)
        subprocess.run([clang, '-isysroot', sdk, '-arch', 'arm64', '-mmacosx-version-min=14.0',
                        '-dynamiclib', *objects, '-Wl,-install_name,@rpath/libintl.8.dylib',
                        '-Wl,-compatibility_version,8.0.0', '-Wl,-current_version,8.4.0',
                        '-liconv', '-framework', 'CoreFoundation', '-framework', 'CoreServices',
                        '-o', str(library)], check=True)
    subprocess.run(['strip', '-S', str(library)], check=True)
    remaining = output('nm', '-g', str(stripped))
    if any(' T ' in line and 'libintl_' in line for line in remaining.splitlines()):
        raise RuntimeError('Static gettext definitions remain in the release archive.')
    dependencies = '\n'.join(output('otool', '-L', str(library)).splitlines()[1:])
    if '/opt/homebrew/' in dependencies or '/Users/' in dependencies:
        raise RuntimeError('The runtime has a dependency on this build machine.')
    print('Prepared arm64 Ghostty and replaceable libintl runtime at', destination)


if __name__ == '__main__':
    main()
