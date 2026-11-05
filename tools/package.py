#!/usr/bin/env python3
"""Build and personally sign the supplied LINE IPA; keep credentials out of the repo."""
import argparse
import datetime
import hashlib
import os
from pathlib import Path
import plistlib
import secrets
import shlex
import shutil
import subprocess
import tempfile
from macho_integrity import RUIN_LOAD_PATH, verify_packaged, verify_source

ROOT = Path(__file__).resolve().parents[1]


def run(*args, capture=False, **kwargs):
    # Never include argv in an exception: security import receives the password.
    result = subprocess.run([str(a) for a in args], capture_output=capture, **kwargs)
    if result.returncode:
        detail = result.stderr.decode(errors='replace') if capture and isinstance(result.stderr, bytes) else ''
        raise RuntimeError(f'{Path(args[0]).name} failed ({result.returncode}) {detail}')
    return result.stdout if capture else None


def profile_entitlements(profile):
    allowed = profile['Entitlements']
    app_id = allowed['application-identifier']
    team = allowed['com.apple.developer.team-identifier']
    if '*' in app_id or not app_id.startswith(team + '.'):
        raise ValueError('This package requires the supplied explicit app identifier.')
    ent = {k: allowed[k] for k in (
        'application-identifier', 'com.apple.developer.team-identifier', 'get-task-allow',
        'aps-environment', 'com.apple.security.application-groups',
        'com.apple.developer.usernotifications.communication',
        'com.apple.developer.usernotifications.time-sensitive',
        'com.apple.developer.siri', 'com.apple.developer.applesignin',
    ) if k in allowed}
    ent['keychain-access-groups'] = [app_id, team + '.com.linecorp.trident.shared']
    return app_id, ent


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--ipa', type=Path, required=True)
    p.add_argument('--profile', type=Path, required=True)
    p.add_argument('--p12', type=Path, required=True)
    p.add_argument('--password-file', type=Path, required=True)
    p.add_argument('--udid', required=True)
    p.add_argument('--dylib', type=Path, default=ROOT / 'build/RUIN.dylib')
    p.add_argument('--bundle-id', help='Optional CFBundleIdentifier override; signing entitlements remain profile-derived.')
    a = p.parse_args()
    profile = plistlib.loads(run('security', 'cms', '-D', '-i', a.profile, capture=True))
    now = datetime.datetime.now(datetime.timezone.utc)
    if profile['ExpirationDate'].replace(tzinfo=datetime.timezone.utc) <= now:
        raise ValueError('Provisioning profile has expired.')
    if a.udid not in profile.get('ProvisionedDevices', []):
        raise ValueError('Connected device is absent from this provisioning profile.')
    signing_app_id, ent = profile_entitlements(profile)
    out = ROOT / 'build/signed'
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    # ditto preserves executable permissions and bundle structure from the IPA.
    run('/usr/bin/ditto', '-x', '-k', a.ipa.resolve(), out)
    apps = list((out / 'Payload').glob('*.app'))
    if len(apps) != 1:
        raise ValueError('Expected exactly one app in Payload.')
    app = apps[0]
    info_path = app / 'Info.plist'
    info = plistlib.loads(info_path.read_bytes())
    original_bundle_id = info.get('CFBundleIdentifier')
    if not isinstance(original_bundle_id, str) or not original_bundle_id:
        raise ValueError('Input app has no CFBundleIdentifier.')
    if a.bundle_id is not None and not a.bundle_id:
        raise ValueError('--bundle-id must not be empty.')
    bundle_id = a.bundle_id if a.bundle_id is not None else original_bundle_id
    binary = app / info['CFBundleExecutable']
    original_executable = binary.read_bytes()
    verify_source(original_executable)
    # Extension signing/hosting has not yet been validated with this profile.
    for name in ('PlugIns', 'Extensions', 'Watch', 'SC_Info', '_MASReceipt'):
        shutil.rmtree(app / name, ignore_errors=True)
    for signature in app.rglob('_CodeSignature'):
        shutil.rmtree(signature)
    for old_profile in app.rglob('embedded.mobileprovision'):
        old_profile.unlink()
    info['CFBundleIdentifier'] = bundle_id
    info['CFBundleDisplayName'] = 'RUIN'
    info['RUINOriginalBundleIdentifier'] = original_bundle_id
    info['RUINSignedBundleIdentifier'] = bundle_id
    info['RUINSigningApplicationIdentifier'] = signing_app_id
    info['RUINSignedTeamIdentifier'] = ent['com.apple.developer.team-identifier']
    info['RUINPushEnvironment'] = ent.get('aps-environment', 'unavailable')
    info['RUINAppGroupMap'] = dict(zip([
        'group.com.linecorp.line', 'group.com.linecorp.Line.encrypted.app',
        'group.share.com.linecorp.line', 'group.com.linecorp.Line.encrypted.share',
        'group.ly-app.family',
    ], ent.get('com.apple.security.application-groups', [])))
    info_path.write_bytes(plistlib.dumps(info, fmt=plistlib.FMT_BINARY))
    for localized_info in app.glob('*.lproj/InfoPlist.strings'):
        localized = plistlib.loads(run('plutil', '-convert', 'xml1', '-o', '-', localized_info, capture=True))
        localized['CFBundleDisplayName'] = 'RUIN'
        localized_info.write_bytes(plistlib.dumps(localized, fmt=plistlib.FMT_BINARY))
    shutil.copy2(a.profile, app / 'embedded.mobileprovision')
    fishhook_notice = (ROOT / 'vendor/fishhook/fishhook.c').read_text().split('#include "fishhook.h"', 1)[0]
    (app / 'RUIN-ThirdPartyNotices.txt').write_text('fishhook - https://github.com/facebook/fishhook\n\n' + fishhook_notice)
    frameworks = app / 'Frameworks'
    frameworks.mkdir(exist_ok=True)
    shutil.copy2(a.dylib, frameworks / 'RUIN.dylib')
    os.chmod(frameworks / 'RUIN.dylib', 0o755)
    run(ROOT / 'build/insert_dylib', '--inplace', '--all-yes', '--strip-codesig',
        RUIN_LOAD_PATH, binary)
    # Feature behavior lives in RUIN.dylib. Only loading and signing metadata
    # may change; the app's code, constants and Swift metadata stay byte-exact.
    verify_packaged(original_executable, binary.read_bytes())
    ent_path = ROOT / 'build/entitlements.plist'
    ent_path.write_bytes(plistlib.dumps(ent))
    password = a.password_file.read_text().strip()
    keychain_password = secrets.token_urlsafe(32)
    identities = [hashlib.sha1(c).hexdigest().upper() for c in profile['DeveloperCertificates']]
    with tempfile.TemporaryDirectory(prefix='ruin-sign-') as temp:
        keychain = Path(temp) / 'sign.keychain-db'
        original_search_list = shlex.split(run('security', 'list-keychains', '-d', 'user', capture=True).decode())
        try:
            run('security', 'create-keychain', '-p', keychain_password, keychain, capture=True)
            run('security', 'unlock-keychain', '-p', keychain_password, keychain, capture=True)
            run('security', 'set-keychain-settings', '-lut', '7200', keychain, capture=True)
            # Normalize PKCS#12 for Apple's importer. The supplied container is
            # readable by OpenSSL but rejected by SecKeychainItemImport.
            pem = run('/usr/bin/openssl', 'pkcs12', '-in', a.p12, '-nodes',
                      '-passin', 'stdin', input=(password + '\n').encode(), capture=True)
            certificate = Path(temp) / 'certificate.pem'
            certificate.write_bytes(run('/usr/bin/openssl', 'x509', '-outform', 'PEM', input=pem, capture=True))
            normalized = Path(temp) / 'identity.p12'
            normalized.write_bytes(run('/usr/bin/openssl', 'pkcs12', '-export',
                '-in', certificate, '-inkey', '/dev/stdin',
                '-name', 'RUIN Signing',
                '-keypbe', 'PBE-SHA1-3DES', '-certpbe', 'PBE-SHA1-3DES', '-macalg', 'sha1',
                '-passout', 'env:RUIN_EXPORT_PASSWORD', input=pem,
                env={**os.environ, 'RUIN_EXPORT_PASSWORD': keychain_password}, capture=True))
            normalized.chmod(0o600)
            del pem
            run('security', 'import', normalized, '-k', keychain, '-P', keychain_password,
                '-T', '/usr/bin/codesign', capture=True)
            run('security', 'set-key-partition-list', '-S', 'apple-tool:,apple:,codesign:',
                '-s', '-k', keychain_password, keychain, capture=True)
            run('security', 'list-keychains', '-d', 'user', '-s', keychain, *original_search_list, capture=True)
            imported = run('security', 'find-certificate', '-a', '-Z', keychain, capture=True).decode()
            identity = next((i for i in identities if i in imported), None)
            if not identity:
                raise ValueError('P12 certificate is not included in the provisioning profile.')
            def sign(path, main_app=False):
                args = ['codesign', '--force', '--sign', identity, '--keychain', keychain,
                        '--timestamp=none', '--generate-entitlement-der']
                if main_app:
                    args += ['--entitlements', ent_path]
                run(*args, path, capture=True)
            for dylib in sorted(app.rglob('*.dylib'), key=lambda x: len(x.parts), reverse=True):
                sign(dylib)
            for framework in sorted(app.rglob('*.framework'), key=lambda x: len(x.parts), reverse=True):
                sign(framework)
            sign(app, main_app=True)
            run('codesign', '--verify', '--deep', '--strict', '--verbose=2', app)
            verify_packaged(original_executable, binary.read_bytes())
        finally:
            try:
                run('security', 'list-keychains', '-d', 'user', '-s', *original_search_list, capture=True)
            finally:
                if keychain.exists():
                    run('security', 'delete-keychain', keychain, capture=True)
    dist = ROOT / 'dist'
    dist.mkdir(exist_ok=True)
    ipa = dist / 'RUIN-LINE-26.16.0.ipa'
    staging_ipa = ipa.with_suffix('.tmp.ipa')
    run('/usr/bin/ditto', '-c', '-k', '--keepParent', out / 'Payload', staging_ipa)
    staging_ipa.replace(ipa)
    print(f'Signed app: {app}\nSigned IPA: {ipa}\nBundle ID: {bundle_id}', flush=True)


if __name__ == '__main__':
    main()
