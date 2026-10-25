#!/usr/bin/env python3
"""Compile and exercise only synthetic data. Never opens Photos or requests TCC."""
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = root / 'scripts/apple_photos_bridge.swift'
text = source.read_text()
for forbidden in ('performChanges', 'PHAssetChangeRequest', 'PHAssetCreationRequest',
                  'deleteAssets', 'URLSession', 'CKContainer', 'AppleID', 'password'):
    assert forbidden not in text, f'Unexpected capability: {forbidden}'
assert 'allowNetwork: Bool = false' in text
assert 'options.isNetworkAccessAllowed = allowNetwork' in text
assert 'manager.cancelImageRequest(request)' in text
assert 'PHAssetMediaSubtype.photoScreenshot' in text
assert 'originalTimeZone: nil' in text
assert 'cloudStatus: "unknown"' in text
# Explicit CLI actions are isolated; synthetic mode must not construct the bridge.
synthetic = text.split('if args == ["--self-test"] {', 1)[1].split('} else if args', 1)[0]
assert 'ApplePhotosBridge(' not in synthetic
with tempfile.TemporaryDirectory(prefix='moments-apple-bridge-') as temp:
    binary = str(Path(temp) / 'bridge')
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-warnings-as-errors',
                    '-parse-as-library', '-module-cache-path', str(Path(temp) / 'cache'),
                    str(source), '-o', binary], check=True)
    result = subprocess.run([binary, '--self-test'], capture_output=True, text=True, check=True)
    manifest = json.loads(result.stdout)
    assert manifest['schemaVersion'] == 1
    assert manifest['source'] == 'apple-photos'
    assert manifest['total'] == 2 and manifest['offset'] == 0 and manifest['nextOffset'] == 1
    assert len(manifest['assets']) == 1
    asset = manifest['assets'][0]
    assert asset['id'] == 'APL' + hashlib.sha256(b'synthetic-only').hexdigest()
    assert asset['localIdentifier'] == 'synthetic-only'
    assert asset['cloudStatus'] == 'unknown'
    assert asset['creationDate'] == '2026-01-01T00:00:00Z'
    assert asset['dateBasis'] == 'utc-derived'
    assert asset.get('captureLocalDate') is None
    assert asset.get('originalTimeZone') is None
    assert asset['mediaType'] == 'image' and asset['width'] == 100 and asset['height'] == 80
    # Invalid invocation also exits before constructing the bridge.
    assert subprocess.run([binary, '--invalid'], capture_output=True).returncode == 1
    continuation = subprocess.run([binary, '--fetch', '1', '100'], capture_output=True, text=True)
    assert continuation.returncode == 1
    assert 'crossProcessPaginationUnsupported' in continuation.stderr
print('Apple Photos foundation: Swift 6 compilation, synthetic immutable-session paging/schema/hash, expiry/query invalidation, read-only policy passed; no library access performed.')
