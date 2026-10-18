#!/usr/bin/env python3
"""Pinned PCM/AIFF decoder; compressed inputs use the bundled FFmpeg path."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tarfile
from rebuild_ollama import fetch, digest
ROOT = Path(__file__).resolve().parents[1]
SOURCE_SHA256 = 'ffe12ef8add3eaca876f04087734e6e8e029350082f3251f565fa9da55b52121'
REVISION = '1.2.2-hermeneus.2'
PATCHES = ['unaligned-1.2.2.patch', 'cue-label.patch', 'ima-counts-1.2.2.patch', 'ircam-bounds-1.2.2.patch']

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--work-dir', type=Path, required=True)
    parser.add_argument('--cmake', required=True)
    parser.add_argument('--sanitize', action='store_true')
    args = parser.parse_args()
    work = args.work_dir.resolve(); work.mkdir(parents=True, exist_ok=False)
    archive = work / 'source.tar.gz'
    fetch('https://github.com/libsndfile/libsndfile/archive/refs/tags/1.2.2.tar.gz', archive, SOURCE_SHA256)
    with tarfile.open(archive) as bundle: bundle.extractall(work, filter='data')
    source = work / 'libsndfile-1.2.2'
    for name in PATCHES:
        subprocess.run(['/usr/bin/patch', '--fuzz=0', '-p1', '-i', str(ROOT/'runtime/libsndfile'/name)], cwd=source, check=True)
    build = work / 'build'
    command = [args.cmake, '-S', str(source), '-B', str(build), '-DCMAKE_POLICY_VERSION_MINIMUM=3.5',
        '-DBUILD_SHARED_LIBS=ON', '-DBUILD_PROGRAMS=OFF', '-DBUILD_EXAMPLES=OFF',
        '-DENABLE_EXTERNAL_LIBS=OFF', '-DENABLE_MPEG=OFF', '-DCMAKE_BUILD_TYPE=Release',
        '-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0', '-DCMAKE_OSX_ARCHITECTURES=arm64', '-DCMAKE_INSTALL_NAME_DIR=@rpath']
    if args.sanitize:
        command += ['-DCMAKE_C_FLAGS=-fsanitize=address,undefined,float-cast-overflow -fno-sanitize-recover=all',
                    '-DCMAKE_SHARED_LINKER_FLAGS=-fsanitize=address,undefined,float-cast-overflow']
    subprocess.run(command, check=True)
    subprocess.run([args.cmake, '--build', str(build), '--parallel', '8'], check=True)
    binary = work / 'libsndfile_arm64.dylib'
    shutil.copy2(build/'libsndfile.dylib', binary)
    record = dict(revision=REVISION, source_sha256=SOURCE_SHA256,
        patches={name:digest(ROOT/'runtime/libsndfile'/name) for name in PATCHES},
        library_sha256=digest(binary), sanitized=args.sanitize, external_codecs=False,
        recipe_sha256=digest(Path(__file__)))
    (work/'build.json').write_text(json.dumps(record,indent=2)+'\n')

if __name__ == '__main__': main()
