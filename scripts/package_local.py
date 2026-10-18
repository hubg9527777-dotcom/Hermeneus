#!/usr/bin/env python3
"""Assemble a local validation DMG. This does not authorize or publish a release."""
import argparse
import json
from rebuild_ollama import digest
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
from vendor_ollama import apply_security_revision, apply_native_revision

ROOT = Path(__file__).resolve().parents[1]

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--runtime', type=Path, required=True)
    parser.add_argument('--ffmpeg', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--diarization-build', type=Path, required=True)
    parser.add_argument('--swift-products', type=Path, help='Use a separately validated Swift build products directory')
    args = parser.parse_args()
    version = (ROOT / 'VERSION').read_text().strip()
    if not re.fullmatch(r'\d+\.\d+\.\d+', version):
        raise ValueError('Invalid application version')
    build_number = (ROOT / 'BUILD_NUMBER').read_text().strip()
    if not re.fullmatch(r'[1-9]\d*', build_number):
        raise ValueError('Invalid application build number')
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    stage = output / 'stage'; stage.mkdir()
    app = stage / 'Hermeneus.app'
    contents = app / 'Contents'
    resources = contents / 'Resources'; resources.mkdir(parents=True)
    macos = contents / 'MacOS'; macos.mkdir()
    products = args.swift_products or ROOT / 'HermeneusApp/App/.build/release'
    shutil.copy2(products / 'AILiveInterpreterApp', macos / 'AILiveInterpreterApp')
    for bundle in products.glob('*.bundle'):
        shutil.copytree(bundle, resources / bundle.name)
    for name in ('asr_server', 'offline_diarizer'):
        shutil.copy2(ROOT / 'asr_server/dist' / name, resources / name)
    shutil.copy2(ROOT / 'Hermeneus_start.sh', resources / 'Hermeneus_start.sh')
    from vendor_sndfile import validate_frozen_record
    decoder = json.loads((ROOT/'runtime/libsndfile/frozen.json').read_text())
    validate_frozen_record(decoder, {name: resources/name for name in ('asr_server', 'offline_diarizer')})
    shutil.copy2(ROOT/'runtime/libsndfile/frozen.json', resources/'decoder-build.json')

    from record_diarizer import validate
    diarization_record = json.loads(args.diarization_build.read_text())
    validate(diarization_record)
    if diarization_record.get('frozen_binary_sha256') != digest(resources / 'offline_diarizer'):
        raise ValueError('Frozen diarizer does not match the source-build record')
    shutil.copy2(args.diarization_build, resources / 'diarization-build.json')
    shutil.copy2(ROOT / 'DIARIZATION_MODELS.md', resources / 'DIARIZATION_MODELS.md')
    shutil.copytree(ROOT / 'licenses', resources / 'licenses')
    runtime = resources / 'ollama-runtime'
    shutil.copytree(args.runtime, runtime, symlinks=True, ignore=shutil.ignore_patterns('._*', '__MACOSX'))
    # Recheck the CLI and pinned Go/source/patch provenance before packaging.
    metadata = runtime / 'runtime.json'
    record = output / 'ollama-build.json'
    record.write_text(json.dumps(json.loads(metadata.read_text())['security_build']))
    apply_security_revision(runtime, args.runtime / 'ollama', record)
    native_record = output / 'native-build.json'
    native_record.write_text(json.dumps(json.loads(metadata.read_text())['native_build']))
    apply_native_revision(runtime, args.runtime / 'llama-server', native_record)
    shutil.copytree(args.ffmpeg, resources / 'ffmpeg', symlinks=True)
    info = dict(CFBundleExecutable='AILiveInterpreterApp',
        CFBundleIdentifier='com.hermeneus.ailiveinterpreter', CFBundleName='Hermeneus',
        CFBundleDisplayName='Hermeneus', CFBundlePackageType='APPL',
        CFBundleShortVersionString=version, CFBundleVersion=build_number,
        LSMinimumSystemVersion='14.0', NSHighResolutionCapable=True,
        NSMicrophoneUsageDescription='需要访问麦克风以进行实时语音同传')
    (contents / 'Info.plist').write_bytes(plistlib.dumps(info))
    os.symlink('/Applications', stage / '应用程序')
    (stage / '请先阅读.txt').write_text(
        'Hermeneus v' + version + '\n拖入“应用程序”后打开，按向导选择模型和声音设备。\n'
        '此应用未通过 Apple Developer ID 签名或公证。请按 macOS 系统设置中的单个应用允许流程打开；不要关闭系统安全功能。\n'
        '说话人分离无需账号，首次确认后下载约 47 MB 模型，以后可离线使用。\n'
        '在会议软件中将麦克风选择为 BlackHole 2ch，可通过设置中的回传检测验收。\n')
    environment = dict(os.environ, PATH=str(resources/'ffmpeg')+':/usr/bin:/bin:/usr/sbin:/sbin')
    subprocess.run(['/bin/bash', str(ROOT/'scripts/verify_full_bundle.sh'), str(app)], env=environment, check=True)
    subprocess.run(['/bin/bash', str(ROOT/'scripts/sign_full_bundle.sh'), str(app)], check=True)
    subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    image = output / ('Hermeneus-v' + version + '-Full.dmg')
    subprocess.run(['/usr/bin/hdiutil', 'create', '-volname', 'Hermeneus', '-srcfolder', str(stage),
                    '-format', 'UDZO', '-ov', str(image)], check=True)
    print(image)

if __name__ == '__main__':
    main()
