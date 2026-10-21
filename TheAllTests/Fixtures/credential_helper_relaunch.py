"""Cross-build Keychain regression, exclusively isolated identities and fake data."""
import hashlib
import os
import pathlib
import plistlib
import shutil
import subprocess
import tempfile
import uuid

repo = pathlib.Path(__file__).resolve().parents[2]
root = pathlib.Path(tempfile.mkdtemp(prefix='TheAllCredentialRebuild-'))
os.chmod(root, 0o700)
keychain = pathlib.Path.home() / 'Library/Keychains' / ('TheAllCredentialFixture-' + uuid.uuid4().hex + '.keychain')
signing_keychain = root / 'signing.keychain'
password = 'fake-test-keychain-password'
created = []

def run(label, args, **kwargs):
    result = subprocess.run([str(x) for x in args], stdin=subprocess.DEVNULL,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=60, **kwargs)
    if result.returncode:
        raise RuntimeError(label + '\n' + result.stdout.decode(errors='replace'))
    print(label + ': passed', flush=True)
    return result.stdout

try:
    config = root / 'openssl.cnf'
    config.write_text('[req]\nprompt=no\ndistinguished_name=dn\nx509_extensions=signing\n[dn]\nCN=TheAll Fixture ' + uuid.uuid4().hex + '\n[signing]\nbasicConstraints=critical,CA:false\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=critical,codeSigning\n')
    run('create fixture certificate', ['/usr/bin/openssl', 'req', '-new', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '2', '-sha256', '-config', config, '-keyout', root/'key.pem', '-out', root/'cert.pem'])
    run('package fixture identity', ['/usr/bin/openssl', 'pkcs12', '-export', '-inkey', root/'key.pem', '-in', root/'cert.pem', '-passout', 'pass:'+password, '-out', root/'identity.p12'])
    for path in [keychain, signing_keychain]:
        run('create isolated keychain', ['/usr/bin/security', 'create-keychain', '-p', password, path]); created.append(path)
        run('unlock isolated keychain', ['/usr/bin/security', 'unlock-keychain', '-p', password, path])
    run('import fixture identity', ['/usr/bin/security', 'import', root/'identity.p12', '-k', signing_keychain, '-P', password, '-T', '/usr/bin/codesign'])
    certificate = run('read fixture public certificate', ['/usr/bin/openssl', 'x509', '-in', root/'cert.pem', '-outform', 'DER'])
    fingerprint = hashlib.sha1(certificate).hexdigest()
    swiftc = '/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc'
    sdk = '/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk'
    shared = repo/'TheAll/AI/AICredentialHelperProtocol.swift'
    def sign(path, identifier):
        run('sign fixture '+path.name, ['/usr/bin/codesign', '--force', '--timestamp=none', '--options', 'runtime', '--sign', fingerprint, '--keychain', signing_keychain, '--identifier', identifier, path])
    helper = root/'TheAllCredentialHelper'
    run('compile production helper', [swiftc, '-sdk', sdk, '-target', 'arm64-apple-macos14.0', shared, repo/'CredentialHelper/main.swift', '-o', helper])
    identifier = 'com.theall.credential-relaunch-fixture'
    sign(helper, identifier+'.credential-helper')
    main = root/'main.swift'
    main.write_text((repo/'TheAllTests/Fixtures/credential_client.swift.txt').read_text())
    clients = []
    for version in [1, 2, 3]:
        app = root/f'Client{version}.app'; binary = app/'Contents/MacOS/Client'
        binary.parent.mkdir(parents=True)
        (app/'Contents/Helpers').mkdir()
        shutil.copy2(helper, app/'Contents/Helpers/TheAllCredentialHelper')
        appid = identifier if version < 3 else identifier+'.unauthorized'
        (app/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': appid, 'CFBundleExecutable': 'Client', 'CFBundlePackageType': 'APPL'}))
        flags = ['-D', 'CLIENT_SECOND'] if version == 2 else []
        run('compile client '+str(version), [swiftc, '-sdk', sdk, '-target', 'arm64-apple-macos14.0', *flags, shared, repo/'TheAll/AI/AIConnection.swift', repo/'TheAll/AI/PersistentAICredentialStore.swift', main, '-o', binary])
        sign(app, appid); clients.append(binary)
    installed = root/'installed'
    suite = 'TheAllFixture.'+uuid.uuid4().hex
    def client(index, operation, *extra):
        return run(f'client {index+1} {operation}', [clients[index], keychain, installed, suite, operation, *extra])
    client(0, 'save')
    original = next(installed.rglob('TheAllCredentialHelper'))
    original_bytes = original.read_bytes()
    client(0, 'load'); client(0, 'load')
    client(1, 'load'); client(1, 'load')
    assert original.read_bytes() == original_bytes, 'Installed helper must remain byte-for-byte unchanged'
    client(2, 'raw', original)
    client(1, 'delete'); client(0, 'absent')
    print('PASS: same-build relaunch, changed app binary, unchanged helper, rejected unauthorized parent, delete.', flush=True)
finally:
    for path in reversed(created):
        subprocess.run(['/usr/bin/security', 'delete-keychain', str(path)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=15)
    shutil.rmtree(root)
