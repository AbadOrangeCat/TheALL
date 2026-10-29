#!/usr/bin/env python3
"""Keep every published version number equal to MARKETING_VERSION in project.yml.

  ./scripts/sync-version.py 0.1.7    # set the version (build number +1), then sync
  ./scripts/sync-version.py          # sync after editing project.yml by hand
  ./scripts/sync-version.py --check  # read-only; exit 1 on drift (CI, check-doc-drift.sh)

Synced: the Xcode project, desktop/package.json and its lockfile, current-release
links and labels in the READMEs, Windows and third-party docs, the bundled license
notice and the website, and the website
PNGs rendered from their SVG sources (including the social card's version pill).

A line containing `version:keep` (written as `<!-- version:keep -->` in Markdown and
HTML) describes one particular release, such as "New in v0.1.6" or "keep v0.1.4 or
later". Those lines are never rewritten; update them when writing release notes.

Rendering a PNG needs Google Chrome (or set CHROME). Run it on macOS so the
artwork's Avenir Next font is available. --check never renders.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import zlib

ROOT = Path(__file__).resolve().parent.parent
PROJECT = ROOT / 'project.yml'
XCODE_PROJECT = ROOT / 'TheAll.xcodeproj/project.pbxproj'
# Every vX.Y.Z / TheAll-X.Y.Z / TheAll X.Y.Z in these files must be the current version unless kept.
TEXT_FILES = ['README.md', 'README.zh-CN.md', 'docs/windows.md', 'docs/third-party-components.md',
              'Resources/ThirdPartyLicenses/README.md',
              'landing-page/index.html', 'landing-page/assets/social-card.svg']
# JSON files and the key paths that hold the desktop app version.
JSON_FILES = {'desktop/package.json': [('version',)],
              'desktop/package-lock.json': [('version',), ('packages', '', 'version')]}
# PNG artwork rendered from an SVG source; the PNG records the source hash it came from.
RENDERED = [('landing-page/assets/social-card.svg', 'landing-page/assets/social-card.png'),
            ('landing-page/assets/overview.svg', 'landing-page/assets/overview.png')]
KEEP_MARKER = 'version:keep'
VERSION = re.compile(r'\b(v|TheAll[- ])(\d+\.\d+\.\d+)\b|("softwareVersion"\s*:\s*")(\d+\.\d+\.\d+)')
SOURCE_KEY = 'TheAll-Source-SHA256'
PNG_SIGNATURE = b'\x89PNG\r\n\x1a\n'


class Sync:
    def __init__(self, version, build, check):
        self.version, self.build, self.check = version, build, check
        self.problems, self.changed, self.kept = [], [], []

    def write(self, path, data):
        if isinstance(data, str):
            path.write_text(data, encoding='utf-8')
        else:
            path.write_bytes(data)
        self.changed.append(path.relative_to(ROOT).as_posix())

    def drift(self, message):
        self.problems.append(message)

    def xcode_project(self):
        text = XCODE_PROJECT.read_text(encoding='utf-8')
        expected = {'MARKETING_VERSION': self.version, 'CURRENT_PROJECT_VERSION': self.build}
        updated = text
        for key, value in expected.items():
            found = set(re.findall(rf'\b{key} = ([^;]+);', text))
            if not found:
                sys.exit(f'sync-version: {key} not found in {XCODE_PROJECT.name}')
            if found != {value}:
                self.drift(f'TheAll.xcodeproj: {key} is {", ".join(sorted(found))}, expected {value}')
                updated = re.sub(rf'(\b{key} = )[^;]+;', rf'\g<1>{value};', updated)
        if updated != text and not self.check:
            self.write(XCODE_PROJECT, updated)

    def json_file(self, name, keys):
        path = ROOT / name
        text = path.read_text(encoding='utf-8')
        data = json.loads(text)
        wrong = [key for key in keys if lookup(data, key) != self.version]
        for key in wrong:
            self.drift(f'{name}: {".".join(key) or "version"} is {lookup(data, key)}, expected {self.version}')
        if not wrong or self.check:
            return
        # Rewrite in place to keep npm's formatting. The listed keys are the first
        # "version" entries in document order; the re-parse below proves it.
        updated = re.sub(r'("version"\s*:\s*")[^"]*"', rf'\g<1>{self.version}"', text, count=len(keys))
        for key in keys:
            lookup(data, key[:-1])[key[-1]] = self.version
        if json.loads(updated) != data:
            sys.exit(f'sync-version: unexpected layout in {name}; update its version by hand')
        self.write(path, updated)

    def text_file(self, name):
        path = ROOT / name
        lines = path.read_text(encoding='utf-8').splitlines(keepends=True)
        for number, line in enumerate(lines, 1):
            versions = {m.group(2) or m.group(4) for m in VERSION.finditer(line)}
            if KEEP_MARKER in line:
                if versions - {self.version}:
                    self.kept.append(f'{name}:{number}: {line.strip()[:100]}')
                continue
            stale = versions - {self.version}
            if stale:
                self.drift(f'{name}:{number}: {", ".join(sorted(stale))} should be {self.version}')
                lines[number - 1] = VERSION.sub(
                    lambda m: (m.group(1) or m.group(3)) + self.version, line)
        updated = ''.join(lines)
        if not self.check and updated != path.read_text(encoding='utf-8'):
            self.write(path, updated)

    def rendered(self, source_name, png_name, chrome):
        source, png = ROOT / source_name, ROOT / png_name
        digest = hashlib.sha256(source.read_bytes()).hexdigest()
        if png.exists() and png_text(png.read_bytes(), SOURCE_KEY) == digest:
            return
        self.drift(f'{png_name} was not rendered from the current {source.name}')
        if self.check:
            return
        if not chrome:
            sys.exit('sync-version: Google Chrome is needed to render '
                     f'{png_name}; install it or set CHROME to its executable')
        self.write(png, with_png_text(render(source, chrome), SOURCE_KEY, digest))


def lookup(data, key):
    for part in key:
        data = data.get(part) if isinstance(data, dict) else None
    return data


def png_chunks(data):
    if not data.startswith(PNG_SIGNATURE):
        raise ValueError('not a PNG file')
    offset = len(PNG_SIGNATURE)
    while offset < len(data):
        length, kind = struct.unpack('>I4s', data[offset:offset + 8])
        yield offset, kind, data[offset + 8:offset + 8 + length]
        offset += length + 12


def png_text(data, key):
    for _, kind, body in png_chunks(data):
        name, _, value = body.partition(b'\0')
        if kind == b'tEXt' and name == key.encode('latin-1'):
            return value.decode('latin-1')
    return None


def with_png_text(data, key, value):
    body = key.encode('latin-1') + b'\0' + value.encode('latin-1')
    chunk = struct.pack('>I', len(body)) + b'tEXt' + body + struct.pack('>I', zlib.crc32(b'tEXt' + body))
    for offset, kind, _ in png_chunks(data):
        if kind == b'IEND':
            return data[:offset] + chunk + data[offset:]
    raise ValueError('PNG has no IEND chunk')


def find_chrome():
    candidates = [os.environ.get('CHROME'), '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
                  shutil.which('google-chrome'), shutil.which('chromium'), shutil.which('chromium-browser')]
    return next((c for c in candidates if c and Path(c).is_file()), None)


def render(source, chrome):
    svg = source.read_text(encoding='utf-8')
    size = re.search(r'<svg\b[^>]*\bwidth="(\d+)"[^>]*\bheight="(\d+)"', svg)
    if not size:
        sys.exit(f'sync-version: {source.name} needs integer width and height attributes')
    width, height = int(size.group(1)), int(size.group(2))
    # Inline the SVG so relative images resolve and text uses the same smoothing
    # and whitespace handling as the original artwork.
    page = ('<!doctype html><html><head><meta charset="utf-8">'
            f'<base href="{source.parent.as_uri()}/">'
            '<style>html,body{margin:0;padding:0;-webkit-font-smoothing:antialiased}'
            'svg{display:block}text{white-space:pre}</style></head>'
            f'<body>{svg}</body></html>')
    work = Path(tempfile.mkdtemp(prefix='theall-render-'))
    try:
        (work / 'page.html').write_text(page, encoding='utf-8')
        shot = work / 'shot.png'
        result = subprocess.run(
            [chrome, '--headless=new', '--disable-gpu', '--hide-scrollbars', '--no-first-run',
             '--force-device-scale-factor=1', f'--window-size={width},{height}',
             '--virtual-time-budget=3000', f'--user-data-dir={work / "profile"}',
             f'--screenshot={shot}', (work / 'page.html').as_uri()],
            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True, timeout=120)
        if result.returncode or not shot.exists():
            sys.exit(f'sync-version: Chrome could not render {source.name}\n{result.stderr[-2000:]}')
        data = shot.read_bytes()
    finally:
        shutil.rmtree(work, ignore_errors=True)
    _, _, header = next(png_chunks(data))
    if struct.unpack('>II', header[:8]) != (width, height):
        sys.exit(f'sync-version: rendered {source.name} has the wrong size')
    return data


def project_values():
    text = PROJECT.read_text(encoding='utf-8')
    version = re.findall(r'^[ \t]+MARKETING_VERSION:[ \t]*"?(\d+\.\d+\.\d+)"?\s*$', text, re.M)
    build = re.findall(r'^[ \t]+CURRENT_PROJECT_VERSION:[ \t]*"?(\d+)"?\s*$', text, re.M)
    if len(version) != 1 or len(build) != 1:
        sys.exit('sync-version: expected one MARKETING_VERSION and one CURRENT_PROJECT_VERSION in project.yml')
    return text, version[0], build[0]


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('version', nargs='?', help='new version, for example 0.1.7')
    parser.add_argument('--check', action='store_true', help='only report drift')
    args = parser.parse_args()
    if args.version and args.check:
        parser.error('--check cannot be combined with a new version')
    if args.version and not re.fullmatch(r'\d+\.\d+\.\d+', args.version):
        parser.error('version must look like 0.1.7')

    text, version, build = project_values()
    if args.version and args.version != version:
        build = str(int(build) + 1)
        text = re.sub(r'^([ \t]+MARKETING_VERSION:[ \t]*).*$', rf'\g<1>"{args.version}"', text, flags=re.M)
        text = re.sub(r'^([ \t]+CURRENT_PROJECT_VERSION:[ \t]*).*$', rf'\g<1>"{build}"', text, flags=re.M)
        PROJECT.write_text(text, encoding='utf-8')
        print(f'project.yml: {version} -> {args.version} (build {build})')
        version = args.version

    sync = Sync(version, build, args.check)
    sync.xcode_project()
    for name, keys in JSON_FILES.items():
        sync.json_file(name, keys)
    for name in TEXT_FILES:
        sync.text_file(name)
    chrome = None if args.check else find_chrome()
    for source, png in RENDERED:
        sync.rendered(source, png, chrome)

    if args.check:
        if sync.problems:
            prefix = '::error::' if os.environ.get('GITHUB_ACTIONS') else ''
            for problem in sync.problems:
                print(f'{prefix}{problem}', file=sys.stderr)
            print(f'{prefix}run ./scripts/sync-version.py to sync to v{version}', file=sys.stderr)
            return 1
        print(f'version in sync: v{version} (build {build})')
        return 0
    for name in sync.changed:
        print(f'updated {name}')
    print(f'version in sync: v{version} (build {build})')
    if sync.kept:
        print('\nRelease-specific lines (version:keep) still name another version; '
              'update them with the release notes if needed:')
        for line in sync.kept:
            print(f'  {line}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
