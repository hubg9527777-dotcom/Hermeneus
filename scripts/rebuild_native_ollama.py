#!/usr/bin/env python3
"""Reproduce the pinned Apple Silicon llama.cpp payload, without RPC.

--disable-gif is an explicit capability change; use only after developer approval.
MLX payloads remain from the independently checked official archive.
"""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import tarfile
from rebuild_ollama import SOURCE_COMMIT, SOURCE_SHA256, fetch, digest

LLAMA_COMMIT = '620d2225cc436ab0b001e3200e590e3b286ef9ab'
LLAMA_SHA256 = 'da36b3375b80d9d237e3787ff04fa72887bce2c8eefb717023205e4e6bbdeaad'
CMAKE_VERSION = '4.4.4'


def extract(archive, destination):
    destination.mkdir()
    with tarfile.open(archive) as stream:
        stream.extractall(destination, filter='data')
    roots = list(destination.iterdir())
    if len(roots) != 1 or not roots[0].is_dir():
        raise ValueError('Unexpected native archive layout')
    return roots[0]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--work-dir', required=True, type=Path)
    parser.add_argument('--cmake', default='cmake')
    parser.add_argument('--disable-gif', action='store_true')
    args = parser.parse_args()
    work = args.work_dir.resolve();work.mkdir(parents=True, exist_ok=True)
    if (work/'build').exists() or (work/'ollama-source').exists():
        raise ValueError('A fresh native build directory is required')
    version = subprocess.check_output([args.cmake,'--version'],text=True).splitlines()[0]
    if version != 'cmake version '+CMAKE_VERSION:
        raise ValueError('Use pinned CMake '+CMAKE_VERSION)
    ollama_archive=work/'ollama.tar.gz';llama_archive=work/'llama.tar.gz'
    fetch(f'https://api.github.com/repos/ollama/ollama/tarball/{SOURCE_COMMIT}',ollama_archive,SOURCE_SHA256)
    fetch(f'https://api.github.com/repos/ggml-org/llama.cpp/tarball/{LLAMA_COMMIT}',llama_archive,LLAMA_SHA256)
    ollama=extract(ollama_archive,work/'ollama-source');llama=extract(llama_archive,work/'llama-source')
    helper=llama/'tools/mtmd/mtmd-helper.cpp'
    if args.disable_gif:
        original=helper.read_text();anchor='#define STB_IMAGE_IMPLEMENTATION'
        if original.count(anchor)!=1:raise ValueError('Unknown image decoder source layout')
        helper.write_text(original.replace(anchor,'#define STBI_NO_GIF\n'+anchor))
    build=work/'build'
    command=[args.cmake,'-S',str(ollama/'llama/server'),'-B',str(build),
        '-DCMAKE_BUILD_TYPE=Release','-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0',
        '-DCMAKE_OSX_ARCHITECTURES=arm64','-DBUILD_SHARED_LIBS=OFF',
        '-DGGML_BACKEND_DL=OFF','-DGGML_METAL=ON','-DGGML_METAL_EMBED_LIBRARY=ON',
        '-DGGML_RPC=OFF','-DCMAKE_EXPORT_COMPILE_COMMANDS=ON',
        '-DLLAMA_BUILD_COMMIT='+LLAMA_COMMIT[:12]+'-hermeneus',
        '-DFETCHCONTENT_SOURCE_DIR_LLAMA_CPP='+str(llama)]
    subprocess.run(command,check=True)
    subprocess.run([args.cmake,'--build',str(build),'--target','llama-server','--parallel','8'],check=True)
    binary=work/'llama-server';shutil.copy2(build/'bin/llama-server',binary)
    compiler=subprocess.check_output(['/usr/bin/clang++','--version'],text=True).splitlines()[0]
    metadata={'ollama_source_commit':SOURCE_COMMIT,'ollama_source_sha256':SOURCE_SHA256,
        'llama_commit':LLAMA_COMMIT,'llama_archive_sha256':LLAMA_SHA256,
        'runner_sha256':digest(binary),'helper_sha256':digest(helper),
        'minimum_macos':'14.0','architecture':'arm64','rpc_enabled':False,
        'gif_disabled':args.disable_gif,'metal_enabled':True,'cmake_version':CMAKE_VERSION,
        'compiler':compiler,'recipe_sha256':digest(Path(__file__))}
    (work/'native-build.json').write_text(json.dumps(metadata,indent=2)+'\n')
    print('Built pinned native payload:',binary)

if __name__=='__main__': main()
