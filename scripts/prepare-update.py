#!/usr/bin/env python3
"""Sign the exact GitHub Release archive locally; never export the private key."""
import argparse
import base64
from datetime import datetime, timezone
from email.utils import format_datetime
import hashlib
import html
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tarfile
import urllib.request
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parents[1]
SPARKLE_VERSION = '2.10.1'
SPARKLE_SHA256 = '1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27'
NS = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
ET.register_namespace('sparkle', NS)


def tools_directory():
    override = os.environ.get('SPARKLE_TOOLS_DIR')
    if override:
        return Path(override)
    directory = ROOT / '.build' / f'sparkle-tools-{SPARKLE_VERSION}'
    if (directory / 'bin/sign_update').is_file():
        return directory
    directory.mkdir(parents=True, exist_ok=True)
    archive = directory / 'distribution.tar.xz'
    url = f'https://github.com/sparkle-project/Sparkle/releases/download/{SPARKLE_VERSION}/Sparkle-{SPARKLE_VERSION}.tar.xz'
    with urllib.request.urlopen(url, timeout=60) as response:
        data = response.read()
    if hashlib.sha256(data).hexdigest() != SPARKLE_SHA256:
        raise SystemExit('Sparkle download checksum mismatch')
    archive.write_bytes(data)
    with tarfile.open(archive) as package:
        # This archive is pinned to a known official SHA-256 hash above.
        package.extractall(directory)
    archive.unlink()
    return directory


def run(tool, *arguments):
    return subprocess.check_output([str(tool), *arguments], text=True).strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('archive', type=Path, help='Exact ZIP downloaded from GitHub Releases')
    parser.add_argument('--output', type=Path, default=ROOT / 'appcast.xml')
    parser.add_argument('--previous-feed', type=Path, default=ROOT / 'appcast.xml')
    args = parser.parse_args()
    config = json.loads((ROOT / 'Release.json').read_text())
    tools = tools_directory() / 'bin'
    account = config['keychainAccount']
    public_key = run(tools / 'generate_keys', '--account', account, '-p')
    if public_key != config['publicKey']:
        raise SystemExit('Signing key does not match the application. Do not generate a replacement key.')
    with zipfile.ZipFile(args.archive) as archive:
        candidates = [name for name in archive.namelist() if name.endswith('.app/Contents/Info.plist') and not name.startswith('__MACOSX/') and name.count('.app/') == 1]
        if len(candidates) != 1:
            raise SystemExit('Expected one application in the update archive')
        info = plistlib.loads(archive.read(candidates[0]))
    expected = {'CFBundleIdentifier': 'com.blueeggs.yandexloader', 'CFBundleVersion': config['build'],
                'CFBundleShortVersionString': config['version'], 'SUPublicEDKey': public_key,
                'SUFeedURL': config['feedURL'], 'SURequireSignedFeed': True,
                'SUVerifyUpdateBeforeExtraction': True}
    if any(info.get(key) != value for key, value in expected.items()):
        raise SystemExit('Archive metadata does not match Release.json')
    if args.archive.name != f'Yandex-Loader-{config["version"]}.zip':
        raise SystemExit('Archive name must match the published release asset')
    signature = run(tools / 'sign_update', '--account', account, '-p', str(args.archive))
    if len(base64.b64decode(signature, validate=True)) != 64:
        raise SystemExit('Invalid archive signature')
    run(tools / 'sign_update', '--account', account, '--verify', str(args.archive), signature)
    root = ET.Element('rss', {'version': '2.0'})
    channel = ET.SubElement(root, 'channel')
    ET.SubElement(channel, 'title').text = 'Yandex Loader'
    ET.SubElement(channel, 'link').text = f'https://github.com/{config["repository"]}'
    ET.SubElement(channel, 'description').text = 'Обновления Yandex Loader для macOS'
    ET.SubElement(channel, 'language').text = 'ru'
    item = ET.SubElement(channel, 'item')
    ET.SubElement(item, 'title').text = f'Yandex Loader {config["version"]}'
    ET.SubElement(item, 'pubDate').text = format_datetime(datetime.now(timezone.utc))
    ET.SubElement(item, f'{{{NS}}}version').text = config['build']
    ET.SubElement(item, f'{{{NS}}}shortVersionString').text = config['version']
    ET.SubElement(item, f'{{{NS}}}minimumSystemVersion').text = '14.0'
    notes = (ROOT / 'RELEASE_NOTES.md').read_text().strip()
    ET.SubElement(item, 'description').text = ''.join(f'<p>{html.escape(p)}</p>' for p in notes.split('\n\n'))
    url = f'https://github.com/{config["repository"]}/releases/download/v{config["version"]}/{args.archive.name}'
    ET.SubElement(item, 'enclosure', {'url': url, 'length': str(args.archive.stat().st_size),
                                   'type': 'application/octet-stream', f'{{{NS}}}edSignature': signature})
    if args.previous_feed.is_file():
        run(tools / 'sign_update', '--account', account, '--verify', str(args.previous_feed))
        previous = ET.parse(args.previous_feed)
        for old in previous.findall('./channel/item'):
            old_build = old.findtext(f'{{{NS}}}version')
            if old_build and int(old_build) > int(config['build']):
                raise SystemExit('Refusing to roll back the update feed')
            if old_build != config['build']:
                channel.append(old)
    ET.indent(root)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    ET.ElementTree(root).write(args.output, encoding='utf-8', xml_declaration=True)
    run(tools / 'sign_update', '--account', account, str(args.output))
    run(tools / 'sign_update', '--account', account, '--verify', str(args.output))
    print(f'Signed and verified: {args.output}')
    print('Publish appcast.xml only after the matching ZIP is available in GitHub Releases.')


if __name__ == '__main__':
    main()
