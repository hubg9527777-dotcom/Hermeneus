#!/usr/bin/env python3
"""Build the pinned Hermeneus security revision of the headless Ollama CLI.
Native inference payloads retain the separately verified upstream archive.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import urllib.request

SOURCE_COMMIT = '2476d5ead197abe04629651028f83d48dc75d2b2'
SOURCE_SHA256 = 'e3d3e2c8b851518cf38013bc879211907a3c6167244f15a7931b8fb660ff3372'
GO_VERSION = 'go1.27.2'
GO_SHA256 = '76812b213b1b2302c978d28fa52fa92d541704b9e7d9d5db8002c50e4018c4c5'
REVISION = '0.40.6-hermeneus.6'
ROOT = Path(__file__).resolve().parents[1]


def digest(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''): h.update(block)
    return h.hexdigest()


def fetch(url, destination, expected):
    if not destination.exists():
        temporary = destination.with_suffix('.download')
        with urllib.request.urlopen(url, timeout=120) as response, temporary.open('wb') as output:
            shutil.copyfileobj(response, output)
        temporary.replace(destination)
    if digest(destination) != expected: raise ValueError('SHA-256 mismatch: ' + destination.name)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--work-dir', required=True, type=Path)
    parser.add_argument('--go', type=Path, help='Use an existing, verified Go 1.27.2 SDK')
    args = parser.parse_args()
    work = args.work_dir.resolve();work.mkdir(parents=True, exist_ok=True)
    archive = work / 'source.tar.gz'
    fetch(f'https://api.github.com/repos/ollama/ollama/tarball/{SOURCE_COMMIT}', archive, SOURCE_SHA256)
    source = work / 'source'
    if source.exists(): raise ValueError('Use a fresh work directory; refusing to reuse modified source')
    unpacked = work / 'unpacked';unpacked.mkdir()
    with tarfile.open(archive) as bundle: bundle.extractall(unpacked, filter='data')
    roots = list(unpacked.iterdir())
    if len(roots) != 1 or not roots[0].is_dir(): raise ValueError('Unexpected source layout')
    roots[0].rename(source)
    for name in ('go.mod', 'go.sum'): shutil.copyfile(ROOT / 'runtime/ollama' / name, source / name)
    patch = ROOT / 'runtime/ollama/hermeneus_security.go'
    shutil.copyfile(patch, source / 'server/hermeneus_security.go')
    shutil.copyfile(ROOT / 'runtime/ollama/hermeneus_listener.go', source / 'cmd/hermeneus_listener.go')
    shutil.copyfile(ROOT / 'runtime/ollama/hermeneus_listener_test.go', source / 'cmd/hermeneus_listener_test.go')
    command = source / 'cmd/cmd.go'
    original_command = command.read_text()
    listener_anchor = 'ln, err := net.Listen("tcp", envconfig.Host().Host)'
    if original_command.count(listener_anchor) != 1: raise ValueError('Unrecognized Ollama listener layout')
    command.write_text(original_command.replace(listener_anchor, 'ln, err := hermeneusListener()'))
    routes = source / 'server/routes.go'
    original = routes.read_text()
    anchor = '\tr := gin.Default()\n'
    if original.count(anchor) != 1: raise ValueError('Unrecognized Ollama router layout')
    routes.write_text(original.replace(anchor, anchor + '\tr.Use(hermeneusCapabilityMiddleware())\n'))
    from ollama_patches import apply_native_patches, native_patch_digest
    apply_native_patches(source, ROOT)
    go = args.go
    if go is None:
        sdk = work / 'go-sdk.tar.gz'
        fetch(f'https://go.dev/dl/{GO_VERSION}.darwin-arm64.tar.gz', sdk, GO_SHA256)
        with tarfile.open(sdk) as bundle: bundle.extractall(work, filter='data')
        go = work / 'go/bin/go'
    version = subprocess.check_output([str(go), 'version'], text=True).strip()
    if f' {GO_VERSION} darwin/arm64' not in version: raise ValueError('Unexpected Go toolchain: ' + version)
    environment = dict(os.environ, GOTOOLCHAIN='local', GOPATH=str(work / 'gopath'),
        GOMODCACHE=str(work / 'modules'), GOCACHE=str(work / 'cache'), GOOS='darwin', GOARCH='arm64',
        CGO_ENABLED='1', CGO_CFLAGS='-O3 -mmacosx-version-min=14.0',
        CGO_CXXFLAGS='-O3 -mmacosx-version-min=14.0', CGO_LDFLAGS='-mmacosx-version-min=14.0')
    binary = work / 'ollama'
    subprocess.run([str(go), 'build', '-mod=readonly', '-trimpath', '-buildvcs=false', '-ldflags',
        '-s -w -X github.com/ollama/ollama/version.Version=' + REVISION, '-o', str(binary), '.'],
        cwd=source, env=environment, check=True)
    metadata = dict(native_patch_sha256=native_patch_digest(ROOT), security_patch_sha256=digest(patch), revision=REVISION, source_commit=SOURCE_COMMIT, source_sha256=SOURCE_SHA256,
        go_version=GO_VERSION, cli_sha256=digest(binary), go_mod_sha256=digest(source / 'go.mod'),
        go_sum_sha256=digest(source / 'go.sum'), minimum_macos='14.0', architecture='arm64')
    (work / 'build.json').write_text(json.dumps(metadata, indent=2) + '\n')
    print('Built headless security revision: ' + str(binary))


if __name__ == '__main__': main()
