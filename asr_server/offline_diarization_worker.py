#!/usr/bin/env python3
"""Hermeneus local pyannote Community-1 worker.

The Hugging Face credential is read only from the user's local HF credential
store. Model weights and all diarization output are written under --model-dir
and --output supplied by the Hermeneus secure-root job manager.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--model-dir", required=True)
    parser.add_argument("--num-speakers", type=int, default=2)
    args = parser.parse_args()

    source = Path(args.input).expanduser().resolve(strict=True)
    output = Path(args.output).expanduser().resolve()
    model_dir = Path(args.model_dir).expanduser().resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    model_dir.mkdir(parents=True, exist_ok=True)

    try:
        from huggingface_hub import snapshot_download
        from pyannote.audio import Pipeline
    except Exception as exc:
        raise RuntimeError("pyannote 环境不可用；请使用 Hermeneus 的 diarization-venv") from exc

    # Download only on first use. Community-1 access is gated by the user-accepted
    # Hugging Face terms; token=True reads the user's local credential, not a project secret.
    if not (model_dir / "config.yaml").exists():
        snapshot_download(
            repo_id="pyannote/speaker-diarization-community-1",
            local_dir=str(model_dir),
            token=True,
        )

    pipeline = Pipeline.from_pretrained(str(model_dir))
    result = pipeline(str(source), num_speakers=max(1, args.num_speakers))
    timeline = getattr(result, "exclusive_speaker_diarization", None) or result.speaker_diarization
    turns = []
    for segment, _, speaker in timeline.itertracks(yield_label=True):
        turns.append({
            "start": round(float(segment.start), 3),
            "end": round(float(segment.end), 3),
            "speaker": str(speaker),
        })
    payload = {
        "schema_version": 1,
        "model": "pyannote/speaker-diarization-community-1",
        "num_speakers": args.num_speakers,
        "turns": turns,
    }
    temporary = output.with_suffix(output.suffix + ".tmp")
    temporary.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    temporary.replace(output)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"diarization failed: {exc}", file=sys.stderr)
        raise SystemExit(1)
