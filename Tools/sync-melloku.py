#!/usr/bin/env python3
"""Refresh Melloku's library snapshot; leave the app manifest/call sites untouched."""
from pathlib import Path
import shutil
import argparse

parser = argparse.ArgumentParser()
parser.add_argument('--melloku', type=Path, default=Path('/Users/chris/Desktop/Workspace/Products/Melloku'))
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
target = args.melloku / 'Shared/Vendor/ZipMello'
if not (target / 'Package.swift').is_file():
    raise SystemExit('Melloku integration manifest is missing')
for path in ['Sources/ZipMello', 'Sources/ZipMelloConsumers', 'Vendor/ZIPFoundation']:
    destination = target / path
    # Replace managed source directories to remove stale files from earlier snapshots.
    if destination.exists():
        shutil.rmtree(destination)
    shutil.copytree(root / path, destination, ignore=shutil.ignore_patterns('.build', '.git'))
print(target)
