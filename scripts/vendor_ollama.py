#!/usr/bin/env python3
"""Bundle the official CLI runtime (including Metal libraries), never Ollama.app."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import tarfile
import tempfile
import urllib.request

VERSION = '0.40.6'
SHA256 = 'b2b55434865a668decb494110d7fd970eed3ecc8837be2872f672ccbb95df974'
URL = f'https://github.com/ollama/ollama/releases/download/v{VERSION}/ollama-darwin.tgz'


def extract_verified(archive: Path, destination: Path):
    digest = hashlib.sha256()
    with archive.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    if digest.hexdigest() != SHA256:
        raise ValueError('Ollama archive SHA-256 mismatch')
    # Fail before extraction. Only ordinary files/directories/internal symlinks
    # are allowed; device nodes, hard links and escaping paths are rejected.
    with tarfile.open(archive, 'r:gz') as bundle:
        members = bundle.getmembers()
        for member in members:
            path = Path(member.name)
            if path.is_absolute() or '..' in path.parts or not (member.isfile() or member.isdir() or member.issym()):
                raise ValueError(f'Unsafe archive entry: {member.name}')
            if member.issym():
                target = Path(member.linkname)
                if target.is_absolute() or '..' in target.parts:
                    raise ValueError(f'Unsafe archive symlink: {member.name}')
        # AppleDouble sidecars are merged/removed by DMG creation. Signing them
        # as ordinary files makes the mounted app's resource seal invalid.
        members = [m for m in members if '__MACOSX' not in Path(m.name).parts
                   and not Path(m.name).name.startswith('._')]
        bundle.extractall(destination, members=members, filter='data')
    for name in ('ollama', 'llama-server'):
        binary = destination / name
        if not binary.is_file():
            raise ValueError(f'Missing Ollama runtime binary: {name}')
        binary.chmod(binary.stat().st_mode | 0o111)
    if not list(destination.rglob('*.dylib')):
        raise ValueError('Missing Ollama runtime libraries')
    (destination / 'runtime.json').write_text(json.dumps({
        'version': VERSION, 'sha256': SHA256, 'source': URL,
    }, indent=2) + '\n')


def apply_security_revision(destination, cli, metadata_path):
    from rebuild_ollama import SOURCE_COMMIT, SOURCE_SHA256, GO_VERSION, REVISION, ROOT, digest
    from ollama_patches import native_patch_digest
    metadata = json.loads(Path(metadata_path).read_text())
    required = dict(native_patch_sha256=native_patch_digest(ROOT), security_patch_sha256=digest(ROOT / 'runtime/ollama/hermeneus_security.go'), revision=REVISION, source_commit=SOURCE_COMMIT, source_sha256=SOURCE_SHA256,
        go_version=GO_VERSION, minimum_macos='14.0', architecture='arm64',
        cli_sha256=digest(cli), go_mod_sha256=digest(ROOT / 'runtime/ollama/go.mod'),
        go_sum_sha256=digest(ROOT / 'runtime/ollama/go.sum'))
    if any(metadata.get(key) != value for key, value in required.items()):
        raise ValueError('Patched Ollama CLI does not match the pinned security build')
    shutil.copyfile(ROOT / 'runtime/ollama/OLLAMA_LICENSE', destination / 'OLLAMA_LICENSE')
    shutil.copyfile(cli, destination / 'ollama')
    (destination / 'ollama').chmod(0o755)
    runtime = json.loads((destination / 'runtime.json').read_text())
    runtime['security_build'] = metadata
    (destination / 'runtime.json').write_text(json.dumps(runtime, indent=2) + '\n')



def apply_native_revision(destination, runner, metadata_path):
    from rebuild_ollama import SOURCE_COMMIT, SOURCE_SHA256, ROOT, digest
    from rebuild_native_ollama import LLAMA_COMMIT, LLAMA_SHA256, CMAKE_VERSION
    metadata = json.loads(Path(metadata_path).read_text())
    expected = dict(ollama_source_commit=SOURCE_COMMIT, ollama_source_sha256=SOURCE_SHA256,
        llama_commit=LLAMA_COMMIT, llama_archive_sha256=LLAMA_SHA256,
        runner_sha256=digest(runner), minimum_macos='14.0', architecture='arm64',
        rpc_enabled=False, metal_enabled=True, cmake_version=CMAKE_VERSION,
        recipe_sha256=digest(ROOT/'scripts/rebuild_native_ollama.py'))
    if any(metadata.get(key) != value for key, value in expected.items()):
        raise ValueError('Native runner does not match the pinned source build')
    if metadata.get('gif_disabled') is not True:
        raise ValueError('Native GIF decoder must be disabled')
    shutil.copyfile(runner, destination/'llama-server')
    (destination/'llama-server').chmod(0o755)
    record = destination/'runtime.json'
    data = json.loads(record.read_text());data['native_build'] = metadata
    record.write_text(json.dumps(data,indent=2)+'\n')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('destination', type=Path)
    parser.add_argument('--archive', type=Path, help='Use a previously downloaded archive')
    parser.add_argument('--patched-cli', required=True, type=Path)
    parser.add_argument('--build-metadata', required=True, type=Path)
    parser.add_argument('--native-runner', required=True, type=Path)
    parser.add_argument('--native-build-metadata', required=True, type=Path)
    args = parser.parse_args()
    if args.destination.exists():
        raise SystemExit('Destination already exists; refusing to overwrite it')
    args.destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=args.destination.parent) as temporary:
        temp = Path(temporary)
        archive = args.archive or temp / 'ollama-darwin.tgz'
        if args.archive is None:
            with urllib.request.urlopen(URL, timeout=120) as response, archive.open('wb') as output:
                shutil.copyfileobj(response, output)
        stage = temp / 'runtime'
        stage.mkdir()
        extract_verified(archive, stage)
        apply_security_revision(stage, args.patched_cli, args.build_metadata)
        apply_native_revision(stage, args.native_runner, args.native_build_metadata)
        stage.rename(args.destination)
    print(f'Bundled patched headless Ollama based on {VERSION}: {args.destination}')


if __name__ == '__main__':
    main()
