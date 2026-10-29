#!/usr/bin/env python3
"""Check a distributable app and its required corresponding-source archive."""
import argparse
from pathlib import Path
import plistlib
import re
import subprocess
import tarfile


def output(*args):
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('--sources', type=Path, required=True)
    args = parser.parse_args()
    app = args.app.resolve()
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    assert info['CFBundleIdentifier'] == 'com.theall.app', 'Unexpected application identity'
    assert not info.get('TheAllPreviousNamespace'), 'Local migration setting must not ship'
    project = (Path(__file__).resolve().parent.parent / 'project.yml').read_text()
    public_key = re.search(r'^\s+SUPublicEDKey:\s*["\']?([A-Za-z0-9+/]{43}=)', project, re.M)
    assert public_key and info.get('SUPublicEDKey') == public_key.group(1), 'Update signing public key is missing or mismatched'
    assert info.get('SUFeedURL') == 'https://github.com/AbadOrangeCat/TheALL/releases/latest/download/appcast.xml', 'Unexpected update source'
    assert info.get('SUEnableAutomaticChecks') is True, 'Automatic update checks must be enabled'
    assert info.get('SUAutomaticallyUpdate') is False, 'Updates must wait for an explicit download click'
    sparkle_info = plistlib.loads((app / 'Contents/Frameworks/Sparkle.framework/Resources/Info.plist').read_bytes())
    sparkle_version = tuple(int(part) for part in sparkle_info['CFBundleShortVersionString'].split('.'))
    assert sparkle_version >= (2, 9, 6), 'Sparkle 2.9.6 or newer is required'
    version = info['CFBundleShortVersionString']
    assert args.sources.name == f'TheAll-{version}-third-party-sources.tar.gz'
    with tarfile.open(args.sources, 'r:gz') as archive:
        names = archive.getnames()
        for suffix in ('/gettext-0.24.tar.gz', '/z2d-0.10.0.tar.gz', '/rebuild-libintl.py'):
            assert any(name.endswith(suffix) for name in names), f'Missing corresponding source: {suffix}'
    output('codesign', '--verify', '--deep', '--strict', str(app))
    executable = app / 'Contents/MacOS/TheAll'
    helper = app / 'Contents/Helpers/TheAllCredentialHelper'
    runtime = app / 'Contents/Frameworks/libintl.8.dylib'
    assert runtime.is_file(), 'Release requires replaceable gettext runtime'
    assert '@rpath/libintl.8.dylib' in output('otool', '-L', str(executable))
    symbols = output('nm', '-g', str(executable))
    assert not re.search(r'\b[TD] _?libintl_', symbols), 'Static gettext implementation remains'
    for binary in (executable, helper, runtime):
        assert output('lipo', '-archs', str(binary)).strip() == 'arm64'
        dependencies = '\n'.join(output('otool', '-L', str(binary)).splitlines()[1:])
        assert '/opt/homebrew/' not in dependencies and '/Users/' not in dependencies
    assert 'Identifier=com.theall.app.credential-helper\n' in output('codesign', '-dv', str(helper))
    licenses = app / 'Contents/Resources/ThirdPartyLicenses'
    assert (licenses / 'libintl-COPYING.LIB.txt').is_file()
    assert (licenses / 'z2d/LICENSE').is_file()
    assert (app / 'Contents/Resources/TheAll-LICENSE.txt').is_file()
    for path in app.rglob('*'):
        assert path.name not in {'.agents', '.claude', '__pycache__', '.pytest_cache', 'Local.xcconfig'}
        assert path.suffix not in {'.pyc', '.p12', '.key', '.xctest'}
    print(f'Verified TheAll {version}: arm64, signatures, runtime, notices and corresponding sources.')


if __name__ == '__main__':
    main()
