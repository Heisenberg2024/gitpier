#!/usr/bin/env python3
import argparse
import base64
import hashlib
from pathlib import Path
import subprocess
import sys
import xml.etree.ElementTree as ET
from release_metadata import load, CONFIG

parser = argparse.ArgumentParser()
parser.add_argument('archive', type=Path)
parser.add_argument('feed', type=Path)
parser.add_argument('signature', nargs='?')
parser.add_argument('--config', type=Path, default=CONFIG)
args = parser.parse_args()
archive, feed = args.archive, args.feed
config, testing = load(args.config)
assert config['publicEDKey'], 'Release key missing'
subprocess.run(['swift', 'Scripts/verify-update-signature.swift', '--feed', config['publicEDKey'], str(feed)], check=True)
ns = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
items = ET.parse(feed).findall('./channel/item')
assert len(items) == 1, 'Expected one stable release item'
item = items[0]
assert item.find(ns + 'channel') is None, 'Stable release cannot specify a prerelease channel'
assert item.findtext(ns + 'version') == config['build'], 'Build mismatch'
assert item.findtext(ns + 'shortVersionString') == config['version'], 'Version mismatch'
assert item.findtext(ns + 'minimumSystemVersion') == config['minimumSystemVersion'], 'OS mismatch'
enclosure = item.find('enclosure')
assert enclosure is not None
prefix = config['feedURL'].rsplit('/', 1)[0] + '/' if testing else f'https://github.com/Heisenberg2024/gitpier/releases/download/v{config["version"]}/'
assert enclosure.get('url') == prefix + archive.name, 'Download URL mismatch' 
assert int(enclosure.get('length', 0)) == archive.stat().st_size, 'Length mismatch'
signature = enclosure.get(ns + 'edSignature', '')
assert len(base64.b64decode(signature, validate=True)) == 64, 'Missing EdDSA signature'
if args.signature:
    assert signature == args.signature, 'Signing output mismatch'
assert item.find('description') is not None, 'Release notes are required'
subprocess.run(['swift', 'Scripts/verify-update-signature.swift', config['publicEDKey'], signature, str(archive)], check=True)
print(f'Release metadata verified; SHA256 {hashlib.sha256(archive.read_bytes()).hexdigest()}')
