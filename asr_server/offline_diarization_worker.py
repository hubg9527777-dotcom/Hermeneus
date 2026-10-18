#!/usr/bin/env python3
"""Account-free local ONNX diarization. Audio never leaves this process."""
from __future__ import annotations
import argparse
import json
import math
import os
from pathlib import Path
import sys
from secure_paths import atomic_private_text
from public_diarization_models import MODEL_ID, ensure_models, verified_models


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--input', required=True)
    parser.add_argument('--output', required=True)
    parser.add_argument('--model-dir', required=True)
    parser.add_argument('--num-speakers', type=int, default=2, choices=range(1, 17))
    parser.add_argument('--allow-model-download', action='store_true')
    parser.add_argument('--progress-file')
    args = parser.parse_args()
    os.umask(0o077)
    os.environ['ORT_DISABLE_TELEMETRY'] = '1'
    import numpy as np
    import importlib.metadata
    if importlib.metadata.version('sherpa-onnx') != '1.13.8+hermeneus.1':
        raise RuntimeError('分离引擎安全修订不匹配，请安装当前 Hermeneus 完整版')
    import sherpa_onnx as s
    import soundfile as sf
    source = Path(args.input).expanduser().resolve(strict=True)
    output = Path(args.output).expanduser().resolve()
    output.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    cache = Path(args.model_dir).expanduser().resolve()
    def download_progress(received, total):
        if args.progress_file:
            message = f'正在下载分离模型 {received * 100 // total}%（{received / 1e6:.1f} / {total / 1e6:.1f} MB），录音不会上传'
            atomic_private_text(Path(args.progress_file), json.dumps(dict(state='diarizing', completed=0, total=None, message=message), ensure_ascii=False))
    ensure_models(cache, allow_download=args.allow_model_download, progress=download_progress)
    if args.progress_file:
        atomic_private_text(Path(args.progress_file), json.dumps(dict(state='diarizing', completed=0, total=None, message='模型已验证，正在本机区分说话人 A / B'), ensure_ascii=False))
    import subprocess
    import tempfile
    # Decode in a private job directory, bound output to 2h + 1s before reading.
    # FFmpeg receives an argv array and permits no network protocols.
    with tempfile.TemporaryDirectory(prefix='.diarization-audio-', dir=output.parent) as folder:
        decoded = Path(folder) / 'mono.wav'
        subprocess.run(['ffmpeg', '-nostdin', '-hide_banner', '-loglevel', 'error',
                        '-protocol_whitelist', 'file,pipe', '-i', str(source), '-vn',
                        '-t', '7201', '-ac', '1', '-ar', '16000', '-c:a', 'pcm_s16le', str(decoded)],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=900)
        with sf.SoundFile(decoded) as audio:
            if not 0 < audio.frames <= 7200 * 16000 or audio.channels != 1 or audio.samplerate != 16000:
                raise ValueError('说话人分离支持最多两小时的本地音频')
            samples = audio.read(dtype='float32')
    if not np.isfinite(samples).all():
        raise ValueError('音频包含无效采样值')
    with verified_models(cache) as models:
        config = s.OfflineSpeakerDiarizationConfig(
            segmentation=s.OfflineSpeakerSegmentationModelConfig(
                pyannote=s.OfflineSpeakerSegmentationPyannoteModelConfig(model=str(models / 'segmentation.onnx')),
                num_threads=2, provider='cpu'),
            embedding=s.SpeakerEmbeddingExtractorConfig(model=str(models / 'embedding.onnx'), num_threads=2, provider='cpu'),
            clustering=s.FastClusteringConfig(num_clusters=args.num_speakers),
            min_duration_on=0.3, min_duration_off=0.5)
        if not config.validate():
            raise RuntimeError('本地分离配置验证失败')
        pipeline = s.OfflineSpeakerDiarization(config)
        result = pipeline.process(samples).sort_by_start_time()
        turns = []
        duration = len(samples) / 16000
        for segment in result:
            start, end, speaker = float(segment.start), float(segment.end), int(segment.speaker)
            if not (math.isfinite(start) and math.isfinite(end) and 0 <= start < end <= duration + 0.1 and 0 <= speaker < args.num_speakers):
                raise ValueError('分离引擎返回无效时间或说话人编号')
            turns.append(dict(start=round(start, 3), end=round(min(end, duration), 3), speaker=f'SPEAKER_{speaker:02d}'))
    payload = dict(schema_version=1, model=MODEL_ID, num_speakers=args.num_speakers, turns=turns,
                   audio_uploaded=False, account_required=False)
    atomic_private_text(output, json.dumps(payload, ensure_ascii=False, indent=2))
    return 0


if __name__ == '__main__':
    import multiprocessing
    multiprocessing.freeze_support()
    if '--runtime-check' in sys.argv:
        os.environ['ORT_DISABLE_TELEMETRY'] = '1'
        import importlib.metadata
        assert importlib.metadata.version('sherpa-onnx') == '1.13.8+hermeneus.1', 'Unpatched diarization runtime'
        import sherpa_onnx
        import soundfile
        import io
        import wave
        audio = io.BytesIO()
        with wave.open(audio, 'wb') as stream:
            stream.setparams((1, 2, 16000, 1600, 'NONE', 'not compressed'))
            stream.writeframes(b'\0\0' * 1600)
        samples, rate = soundfile.read(io.BytesIO(audio.getvalue()))
        assert rate == 16000 and len(samples) == 1600
        print('Hermeneus account-free diarizer imports and synthetic WAV decode passed')
        raise SystemExit(0)
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f'说话人分离失败：{exc}', file=sys.stderr)
        raise SystemExit(1)
