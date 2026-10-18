#!/usr/bin/env python3
"""Verify a prepared release against reviewed source and every upload byte."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import zipfile
from check_release_security import check
from release_source import ROOT, fingerprint, source_files


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def verify(folder, root=ROOT):
    folder = Path(folder)
    check(json.loads((root/'release-security.json').read_text()))
    manifest = json.loads((folder/'release-manifest.json').read_text())
    version = (root/'VERSION').read_text().strip()
    if manifest.get('version') != version or manifest.get('build') != (root/'BUILD_NUMBER').read_text().strip():
        raise ValueError('Release version/build changed')
    if manifest.get('source_sha256') != fingerprint(root):
        raise ValueError('Reviewed source changed after release preparation')
    expected = {f'Hermeneus-v{version}-Full.dmg', f'Hermeneus-v{version}-Source.zip',
                'SECURITY_AUDIT.md', 'DEPENDENCIES.md', 'dependency-sbom.json', 'RELEASE_NOTES.md'}
    artifacts = manifest.get('artifacts', {})
    if set(artifacts) != expected:
        raise ValueError('Unexpected release attachment set')
    if {p.name for p in folder.iterdir()} != expected | {'release-manifest.json', 'SHA256SUMS'}:
        raise ValueError('Extra or missing release files')
    for name, sha in artifacts.items():
        path = folder/name
        if path.is_symlink() or digest(path) != sha:
            raise ValueError('Release attachment changed: ' + name)
    checksums = {}
    for line in (folder/'SHA256SUMS').read_text().splitlines():
        match = re.fullmatch(r'([0-9a-f]{64})  ([A-Za-z0-9_.-]+)', line)
        if not match or match[2] in checksums:
            raise ValueError('Invalid checksum file')
        checksums[match[2]] = match[1]
    if set(checksums) != expected | {'release-manifest.json'}:
        raise ValueError('Incomplete checksum file')
    if any(digest(folder/name) != sha for name, sha in checksums.items()):
        raise ValueError('Release checksum mismatch')
    with zipfile.ZipFile(folder/f'Hermeneus-v{version}-Source.zip') as archive:
        names = archive.namelist()
        current = source_files(root)
        if sorted(names) != current or len(names) != len(set(names)):
            raise ValueError('Source archive file inventory mismatch')
        for name in current:
            if hashlib.sha256(archive.read(name)).hexdigest() != digest(root/name):
                raise ValueError('Source archive is stale: ' + name)
    return manifest


if __name__ == '__main__':
    parser = argparse.ArgumentParser(); parser.add_argument('directory', type=Path)
    args = parser.parse_args(); result = verify(args.directory)
    print(f"Verified v{result['version']} build {result['build']}: reviewed source and all release attachments")
