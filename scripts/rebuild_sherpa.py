#!/usr/bin/env python3
"""Build the reviewed Hermeneus sherpa wheel; never use an unpatched PyPI core."""
import argparse
import json
import os
import shlex
from pathlib import Path
import subprocess
import tarfile
import zipfile
from rebuild_ollama import fetch, digest

COMMIT = '11afbd009a7f8c08f4bcf2fc1b265d0df4670fbf'
SOURCE_SHA256 = '7ee4f2d117bf72a0651146535b9158d62f11a86520e68142270ca9a35a9032b7'
PATCH_SHA256 = '833d73f98b8d8c652cab7c1df9d5cc7d1821e2f104eb34172ba63eb6578a5c5d'
VERSION = '1.13.8+hermeneus.1'
ROOT = Path(__file__).resolve().parents[1]
FLAGS = ('-DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 '
         '-DCMAKE_OSX_ARCHITECTURES=arm64 -DSHERPA_ONNX_ENABLE_BINARY=OFF '
         '-DSHERPA_ONNX_ENABLE_TTS=OFF -DSHERPA_ONNX_ENABLE_PORTAUDIO=OFF '
         '-DSHERPA_ONNX_ENABLE_WEBSOCKET=OFF -DSHERPA_ONNX_ENABLE_C_API=OFF '
         '-DSHERPA_ONNX_USE_PRE_INSTALLED_ONNXRUNTIME_IF_AVAILABLE=OFF '
         '-DCMAKE_EXPORT_COMPILE_COMMANDS=ON')


def record_build(source, wheel, output):
    with zipfile.ZipFile(wheel) as archive:
        modules=[name for name in archive.namelist() if '_sherpa_onnx.cpython-' in name and name.endswith('.so')]
    if len(modules)!=1 or 'cpython-311-darwin.so' not in modules[0]:
        raise ValueError('Wrong or mixed Python ABI in native wheel')
    native = {str(p.relative_to(source)): digest(p) for p in sorted((source/'build').rglob('*'))
              if p.is_file() and p.suffix in ('.dylib', '.so') and not p.is_symlink()}
    record = dict(version=VERSION, source_commit=COMMIT, source_sha256=SOURCE_SHA256,
                  patch_sha256=PATCH_SHA256, recipe_sha256=digest(Path(__file__)),
                  wheel_sha256=digest(wheel), wheel_name=wheel.name, flags=FLAGS,
                  minimum_macos='14.0', architecture='arm64', native_files=native,
                  cmake_version=subprocess.check_output(['cmake','--version'],text=True).splitlines()[0])
    output.write_text(json.dumps(record,indent=2)+'\n')


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--work-dir',type=Path,required=True)
    parser.add_argument('--python',required=True)
    parser.add_argument('--install',action='store_true')
    args=parser.parse_args()
    version=subprocess.check_output([args.python,'-c','import sys;print(".".join(map(str,sys.version_info[:2])))'],text=True).strip()
    if version!='3.11':raise ValueError('Use Python 3.11 for the packaged runtime')
    if subprocess.check_output(['cmake','--version'],text=True).splitlines()[0]!='cmake version 4.4.4':
        raise ValueError('Use CMake 4.4.4')
    work=args.work_dir.resolve();work.mkdir(parents=True,exist_ok=True)
    unpack=work/'source'
    if unpack.exists():raise ValueError('Use a fresh source directory')
    archive=work/'sherpa-source.tar.gz'
    fetch(f'https://api.github.com/repos/k2-fsa/sherpa-onnx/tarball/{COMMIT}',archive,SOURCE_SHA256)
    patch=ROOT/'runtime/sherpa/transducer-bounds.patch'
    if digest(patch)!=PATCH_SHA256:raise ValueError('Unreviewed sherpa patch')
    unpack.mkdir()
    with tarfile.open(archive) as stream:
        # Upstream examples contain absolute symlinks; none are needed to build.
        # Keep data-filter traversal checks and exclude every archive link.
        stream.extractall(unpack,members=(m for m in stream.getmembers() if m.isfile() or m.isdir()),filter='data')
    roots=list(unpack.iterdir())
    if len(roots)!=1 or not roots[0].is_dir():raise ValueError('Unexpected source layout')
    source=roots[0]
    subprocess.run(['/usr/bin/patch','-p1','--batch','--forward','-i',str(patch)],cwd=source,check=True)
    python_paths=json.loads(subprocess.check_output([args.python,'-c',
        'import json,sysconfig;print(json.dumps(dict(include=sysconfig.get_path("include"),library=sysconfig.get_config_var("LIBDIR")+"/"+sysconfig.get_config_var("LDLIBRARY"))))'],text=True))
    python_flags=shlex.join([f'-DPython_EXECUTABLE={args.python}',f'-DPython3_EXECUTABLE={args.python}',
                           '-DPython_INCLUDE_DIR='+python_paths['include'], '-DPython_LIBRARY='+python_paths['library']])
    env=dict(os.environ,SHERPA_ONNX_CMAKE_ARGS=FLAGS+' '+python_flags,SHERPA_ONNX_MAKE_ARGS='-j8')
    env.pop('SHERPA_ONNX_SPLIT_PYTHON_PACKAGE',None)
    subprocess.run([args.python,'setup.py','bdist_wheel'],cwd=source,env=env,check=True)
    wheels=list((source/'dist').glob('*hermeneus.1*.whl'))
    if len(wheels)!=1:raise ValueError('Expected one reviewed wheel')
    record_build(source,wheels[0],work/'sherpa-build.json')
    if args.install:
        subprocess.run([args.python,'-m','pip','uninstall','-y','sherpa-onnx','sherpa-onnx-core'],check=True)
        subprocess.run([args.python,'-m','pip','install','--no-deps',str(wheels[0])],check=True)
    print(wheels[0])

if __name__=='__main__':main()
