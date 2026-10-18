#!/usr/bin/env python3
"""Prepare public, checksummed attachments. Never uploads or modifies a Git tag."""
import argparse
import json
from pathlib import Path
import shutil
import zipfile
from check_release_security import check
from release_source import ROOT, fingerprint, source_files
from verify_release import digest, verify


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--image', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    check(json.loads((ROOT/'release-security.json').read_text()))
    output = args.output.resolve(); output.mkdir(parents=True, exist_ok=False)
    version = (ROOT/'VERSION').read_text().strip()
    shutil.copy2(args.image, output/f'Hermeneus-v{version}-Full.dmg')
    for source, name in [('docs/SECURITY_AUDIT_2026-10-17.md', 'SECURITY_AUDIT.md'),
                         ('docs/DEPENDENCIES_2026-10-17.md', 'DEPENDENCIES.md'),
                         ('dependencies/dependency-sbom.json', 'dependency-sbom.json'),
                         ('RELEASE_NOTES.md', 'RELEASE_NOTES.md')]:
        shutil.copy2(ROOT/source, output/name)
    with zipfile.ZipFile(output/f'Hermeneus-v{version}-Source.zip', 'x', zipfile.ZIP_DEFLATED) as archive:
        for name in source_files(): archive.write(ROOT/name, name)
    manifest = dict(version=version, build=(ROOT/'BUILD_NUMBER').read_text().strip(),
                    source_sha256=fingerprint(),
                    artifacts={p.name:digest(p) for p in sorted(output.iterdir())})
    (output/'release-manifest.json').write_text(json.dumps(manifest, indent=2)+'\n')
    (output/'SHA256SUMS').write_text(''.join(f'{digest(p)}  {p.name}\n' for p in sorted(output.iterdir()) if p.name != 'SHA256SUMS'))
    verify(output)
    print(output)


if __name__ == '__main__': main()
