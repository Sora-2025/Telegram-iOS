import json
import os
import sys
import shutil
import tempfile
import plistlib
import argparse
import subprocess
import base64
import hashlib
import re

from BuildEnvironment import run_executable_with_output, check_run_system


def setup_temp_keychain(p12_path, p12_password=''):
    """Create a temporary keychain and import the p12 certificate."""
    keychain_name = 'generate-profiles-temp.keychain'
    keychain_password = 'temp123'

    # Delete if exists
    run_executable_with_output('security', arguments=['delete-keychain', keychain_name], check_result=False)

    # Create keychain
    run_executable_with_output('security', arguments=[
        'create-keychain', '-p', keychain_password, keychain_name
    ], check_result=True)

    # Add to search list
    existing = run_executable_with_output('security', arguments=['list-keychains', '-d', 'user'])
    run_executable_with_output('security', arguments=[
        'list-keychains', '-d', 'user', '-s', keychain_name, existing.replace('"', '')
    ], check_result=True)

    # Unlock and set settings
    run_executable_with_output('security', arguments=['set-keychain-settings', keychain_name])
    run_executable_with_output('security', arguments=[
        'unlock-keychain', '-p', keychain_password, keychain_name
    ])

    # Import p12
    run_executable_with_output('security', arguments=[
        'import', p12_path, '-k', keychain_name, '-P', p12_password,
        '-T', '/usr/bin/codesign', '-T', '/usr/bin/security'
    ], check_result=True)

    # Set partition list for access
    run_executable_with_output('security', arguments=[
        'set-key-partition-list', '-S', 'apple-tool:,apple:', '-k', keychain_password, keychain_name
    ], check_result=True)

    return keychain_name


def cleanup_temp_keychain(keychain_name):
    """Remove the temporary keychain."""
    run_executable_with_output('security', arguments=['delete-keychain', keychain_name], check_result=False)


def get_certificate_from_keychain(keychain_name):
    """Первая сертификация в keychain как (base64 DER, SHA-1).

    Раньше сертификат и имя для `security cms -N` вытаскивались из p12 и из
    subject. Оба шага хрупкие: `-passin pass:` завязан на пустой пароль, а
    subject печатается как `CN=Имя` и разбирать его приходилось строкой.
    Keychain, который мы только что наполнили, — источник истины: сертификат
    оттуда гарантированно тот, которым потом подписывается профиль.
    """
    proc = subprocess.Popen(
        ['security', 'find-certificate', '-a', '-p', keychain_name],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE
    )
    cert_pem, _ = proc.communicate()

    proc = subprocess.Popen(
        ['openssl', 'x509', '-outform', 'DER'],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE
    )
    cert_der, stderr = proc.communicate(cert_pem)

    if not cert_der:
        raise Exception('Could not read a certificate from keychain {}: {}'.format(
            keychain_name, stderr.decode('utf-8', 'replace').strip()))

    return base64.b64encode(cert_der).decode('utf-8'), hashlib.sha1(cert_der).hexdigest().upper()


def find_identity_in_keychain(keychain_name):
    """SHA-1 сертификата, которым security сможет подписать.

    `security cms -N` принимает и общее имя, и SHA-1. Имя мы не разбираем:
    берём то, что сам security называет идентичностью для codesigning. Если
    фильтр по политике отсекает самоподписанный сертификат, откатываемся на
    SHA-1 того же сертификата — подойдёт любой из двух.
    """
    result = run_executable_with_output('security', arguments=[
        'find-identity', '-v', '-p', 'codesigning', keychain_name
    ], check_result=False)

    if result is not None:
        match = re.search(r'\)\s+([0-9A-Fa-f]{40})\s', result)
        if match:
            return match.group(1).upper()

    return None


def apply_replacements(parsed_plist_file, source, replacements):
    with open(parsed_plist_file, 'rb') as file:
        content = file.read()
    for old, new in replacements:
        if old.encode('utf-8') not in content:
            print('Warning: {!r} not found in {}'.format(old, os.path.basename(source)))
        content = content.replace(old.encode('utf-8'), new.encode('utf-8'))
    with open(parsed_plist_file, 'wb') as file:
        file.write(content)


def replace_developer_certificates(parsed_plist_file, certificate_data):
    with open(parsed_plist_file, 'rb') as file:
        plist = plistlib.loads(file.read())
    plist['DeveloperCertificates'] = [base64.b64decode(certificate_data)]
    plist.pop('DER-Encoded-Profile', None)
    with open(parsed_plist_file, 'wb') as file:
        plistlib.dump(plist, file, fmt=plistlib.FMT_XML)


def process_provisioning_profile(source, destination, certificate_data, signing_identity, keychain_name, replacements=None):
    parsed_plist = run_executable_with_output('openssl', arguments=[
        'smime',
        '-inform',
        'der',
        '-verify',
        '-noverify',
        '-in',
        source
    ], decode=False, stderr_to_stdout=False, check_result=True)
    parsed_plist_file = tempfile.mktemp()
    with open(parsed_plist_file, 'wb') as file:
        file.write(parsed_plist)

    if replacements:
        apply_replacements(parsed_plist_file, source, replacements)

    replace_developer_certificates(parsed_plist_file, certificate_data)

    # Sign with the certificate from the temporary keychain
    run_executable_with_output('security', arguments=[
        'cms', '-S', '-k', keychain_name, '-N', signing_identity, '-i', parsed_plist_file, '-o', destination
    ], check_result=True)

    os.unlink(parsed_plist_file)


def generate_provisioning_profiles(source_path, destination_path, certs_path, replacements=None):
    p12_path = os.path.join(certs_path, 'SelfSigned.p12')

    if not os.path.exists(p12_path):
        print('{} does not exist'.format(p12_path))
        sys.exit(1)

    if not os.path.exists(destination_path):
        print('{} does not exist'.format(destination_path))
        sys.exit(1)

    p12_password = ''  # fake-codesigning uses empty password

    # Keychain поднимаем первым: сертификат и идентичность берём уже из него,
    # так что обе величины заведомо соответствуют ключу, которым подписывается.
    keychain_name = setup_temp_keychain(p12_path, p12_password)

    try:
        certificate_data, certificate_sha1 = get_certificate_from_keychain(keychain_name)
        signing_identity = find_identity_in_keychain(keychain_name) or certificate_sha1

        print('Using signing identity: {}'.format(signing_identity))

        for file_name in os.listdir(source_path):
            if file_name.endswith('.mobileprovision'):
                print('Processing {}'.format(file_name))
                process_provisioning_profile(
                    source=os.path.join(source_path, file_name),
                    destination=os.path.join(destination_path, file_name),
                    certificate_data=certificate_data,
                    signing_identity=signing_identity,
                    keychain_name=keychain_name,
                    replacements=replacements
                )
        print('Done. Generated {} profiles.'.format(
            len([f for f in os.listdir(destination_path) if f.endswith('.mobileprovision')])
        ))
    finally:
        cleanup_temp_keychain(keychain_name)


def main():
    parser = argparse.ArgumentParser(description='Re-sign provisioning profiles with the fake self-signed certificate, optionally rewriting bundle identifiers.')
    parser.add_argument('--source', required=True, help='Directory holding the source .mobileprovision files')
    parser.add_argument('--destination', required=True, help='Directory to write the re-signed profiles into')
    parser.add_argument('--certs', required=True, help='Directory holding SelfSigned.p12')
    parser.add_argument('--replace', action='append', default=[], metavar='OLD=NEW', help='Literal replacement applied to every profile before re-signing; repeatable')
    args = parser.parse_args()

    replacements = []
    for item in args.replace:
        if '=' not in item:
            print('--replace expects OLD=NEW, got {!r}'.format(item))
            sys.exit(1)
        old, new = item.split('=', 1)
        replacements.append((old, new))

    os.makedirs(args.destination, exist_ok=True)
    generate_provisioning_profiles(
        source_path=args.source,
        destination_path=args.destination,
        certs_path=args.certs,
        replacements=replacements
    )


if __name__ == '__main__':
    main()
