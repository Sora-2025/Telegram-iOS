import json
import os
import sys
import shutil
import tempfile
import plistlib
import argparse
import subprocess
import base64

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


def get_signing_identity_from_p12(p12_path, p12_password=''):
    """Extract the common name (signing identity) from the p12 certificate."""
    proc = subprocess.Popen(
        ['openssl', 'pkcs12', '-in', p12_path, '-passin', 'pass:' + p12_password, '-nokeys', '-legacy'],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE
    )
    cert_pem, _ = proc.communicate()

    proc2 = subprocess.Popen(
        ['openssl', 'x509', '-noout', '-subject', '-nameopt', 'oneline,-esc_msb'],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE
    )
    subject, _ = proc2.communicate(cert_pem)
    subject = subject.decode('utf-8').strip()

    # Parse CN from subject line like: subject= C = AE, O = ..., CN = Some Name
    if 'CN = ' in subject:
        cn = subject.split('CN = ')[-1].split(',')[0].strip()
        return cn

    return None


def get_certificate_base64_from_p12(p12_path, p12_password=''):
    """Extract the certificate as base64 from p12 file."""
    # Extract certificate in PEM format
    proc = subprocess.Popen(
        ['openssl', 'pkcs12', '-in', p12_path, '-passin', 'pass:' + p12_password, '-nokeys', '-legacy'],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE
    )
    cert_pem, _ = proc.communicate()

    # Convert to DER format
    proc2 = subprocess.Popen(
        ['openssl', 'x509', '-outform', 'DER'],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE
    )
    cert_der, _ = proc2.communicate(cert_pem)

    return base64.b64encode(cert_der).decode('utf-8')


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

    # Extract certificate info from p12
    p12_password = ''  # fake-codesigning uses empty password
    certificate_data = get_certificate_base64_from_p12(p12_path, p12_password)
    signing_identity = get_signing_identity_from_p12(p12_path, p12_password)

    if not signing_identity:
        print('Could not extract signing identity from {}'.format(p12_path))
        sys.exit(1)

    print('Using signing identity: {}'.format(signing_identity))

    # Setup temporary keychain with the certificate
    keychain_name = setup_temp_keychain(p12_path, p12_password)

    try:
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
