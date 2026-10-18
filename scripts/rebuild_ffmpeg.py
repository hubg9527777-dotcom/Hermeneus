#!/usr/bin/env python3
"""Build a private, relocatable macOS 14 FFmpeg; no Homebrew runtime needed."""
import argparse
from pathlib import Path
import shutil
import subprocess
import tarfile
from rebuild_ollama import fetch
from vendor_ffmpeg import vendor

VERSION = '8.1.2'
SHA256 = '464beb5e7bf0c311e68b45ae2f04e9cc2af88851abb4082231742a74d97b524c'


def main():
    parser = argparse.ArgumentParser();parser.add_argument('--work-dir', required=True, type=Path)
    parser.add_argument('--destination', required=True, type=Path);args=parser.parse_args()
    work=args.work_dir.resolve();work.mkdir(parents=True,exist_ok=True)
    archive=work/'ffmpeg.tar.xz';fetch(f'https://ffmpeg.org/releases/ffmpeg-{VERSION}.tar.xz',archive,SHA256)
    with tarfile.open(archive) as bundle: bundle.extractall(work,filter='data')
    source=work/f'ffmpeg-{VERSION}';prefix=work/'install'
    subprocess.run(['./configure',f'--prefix={prefix}','--arch=arm64','--target-os=darwin',
        '--cc=clang','--extra-cflags=-mmacosx-version-min=14.0','--extra-ldflags=-mmacosx-version-min=14.0 -Wl,-headerpad_max_install_names',
        '--install-name-dir=@rpath','--disable-autodetect','--disable-network','--enable-shared',
        '--disable-static','--disable-doc','--disable-debug','--disable-programs','--enable-ffmpeg',
        '--disable-gpl','--disable-nonfree'],cwd=source,check=True)
    subprocess.run(['make','-j6'],cwd=source,check=True)
    subprocess.run(['make','install'],cwd=source,check=True)
    vendor(prefix/'bin/ffmpeg',args.destination.resolve())
    licenses=args.destination/'licenses';licenses.mkdir()
    for name in ['COPYING.LGPLv2.1','COPYING.LGPLv3','LICENSE.md']:
        if (source/name).is_file():shutil.copy2(source/name,licenses/name)
    shutil.copy2(source/'ffbuild/config.log',args.destination/'configure.log')
    shutil.copy2(archive,args.destination/'ffmpeg-source.tar.xz')
    (args.destination/'SOURCE-AND-LICENSE-NOTICE.txt').write_text(
        f'FFmpeg {VERSION}: https://ffmpeg.org/releases/ffmpeg-{VERSION}.tar.xz\n'
        f'SHA-256: {SHA256}\n'
        'Unmodified FFmpeg source archive and LGPL license texts accompany this private build.\n'
        'Build uses shared libraries, no GPL/nonfree components, no network protocols.\n'
        'See build-version.txt and configure.log for configuration.\n')

if __name__ == '__main__':main()
