#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Hermeneus local offline batch transcription/translation worker.

Single-speaker jobs process one local media file as Spanish -> Simplified Chinese.
Dual-speaker jobs are intentionally limited to Hermeneus paired recordings.  Their
independent microphone and system-audio tracks supply deterministic speaker identity,
so no cloud access or pyannote diarization is required.
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import requests
from faster_whisper import WhisperModel


def now() -> str:
    return datetime.now(timezone.utc).isoformat()


def atomic_json(path: Path, payload: dict[str, Any]) -> None:
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True), encoding="utf-8")
    temporary.replace(path)


def write_progress(path: Path, *, state: str, completed: int, total: int | None, message: str = "") -> None:
    atomic_json(path, {
        "schema_version": 1,
        "state": state,
        "completed_segments": completed,
        "total_segments": total,
        "updated_at": now(),
        "message": message,
    })


def seconds_to_srt(seconds: float, separator: str = ",") -> str:
    milliseconds = max(0, int(round(seconds * 1000)))
    hours, milliseconds = divmod(milliseconds, 3_600_000)
    minutes, milliseconds = divmod(milliseconds, 60_000)
    secs, milliseconds = divmod(milliseconds, 1000)
    return f"{hours:02d}:{minutes:02d}:{secs:02d}{separator}{milliseconds:03d}"


def ensure_local_ollama(model: str, ollama_url: str) -> None:
    tags_url = ollama_url.rsplit("/api/", 1)[0] + "/api/tags"
    try:
        response = requests.get(tags_url, timeout=2)
        response.raise_for_status()
    except requests.RequestException:
        binary = shutil.which("ollama")
        if not binary:
            raise RuntimeError("未找到 Ollama。请先按安装指南安装命令行版 Ollama。")
        env = os.environ.copy()
        for candidate in ("/Volumes/untitled/APP/ollama models", "/Volumes/Hermeneus/ollama models"):
            if os.path.isdir(candidate):
                env["OLLAMA_MODELS"] = candidate
                break
        subprocess.Popen([binary, "serve"], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        deadline = time.monotonic() + 20
        last_error: Exception | None = None
        while time.monotonic() < deadline:
            try:
                response = requests.get(tags_url, timeout=2)
                response.raise_for_status()
                break
            except requests.RequestException as exc:
                last_error = exc
                time.sleep(0.5)
        else:
            raise RuntimeError(f"无法启动本机 Ollama：{last_error}")
    available = {str(item.get("name", "")) for item in response.json().get("models", [])}
    if model not in available and not any(name.split(":", 1)[0] == model.split(":", 1)[0] for name in available):
        raise RuntimeError(f"本机 Ollama 未找到模型 {model}。请先执行：ollama pull {model}")


def translate_local(text: str, model: str, ollama_url: str, source_language: str, target_language: str) -> str:
    if not text.strip():
        return ""
    prompt = (
        f"你是严谨的{source_language}到{target_language}口译员。只输出忠实、自然的{target_language}译文，"
        "不要添加解释、标题、引号或原文。保留人名、数字、专有名词与不确定信息。\n\n"
        f"{source_language}：{text.strip()}"
    )
    response = requests.post(
        ollama_url,
        json={
            "model": model,
            "prompt": prompt,
            "stream": False,
            "options": {"temperature": 0.1, "num_ctx": 1536, "num_predict": 320},
            "keep_alive": "30m",
        },
        timeout=(5, 300),
    )
    response.raise_for_status()
    translated = str(response.json().get("response") or "").strip()
    if not translated:
        raise RuntimeError("本机 Ollama 返回空译文")
    return translated


def speaker_for(start: float, end: float, turns: list[dict[str, Any]]) -> str:
    best_speaker = "SPEAKER_00"
    best_overlap = 0.0
    for turn in turns:
        overlap = max(0.0, min(end, float(turn["end"])) - max(start, float(turn["start"])))
        if overlap > best_overlap:
            best_overlap = overlap
            best_speaker = str(turn["speaker"])
    return best_speaker


def run_diarization(args: argparse.Namespace, source: Path, job_dir: Path) -> list[dict[str, Any]]:
    output = job_dir / "diarization.json"
    model_dir = Path(args.secure_root).expanduser().resolve() / "Hermeneus Data" / "model-cache" / "pyannote-community-1"
    if args.diarization_executable:
        command = [args.diarization_executable]
    else:
        command = [args.diarization_python, args.diarization_worker]
    command += [
        "--input", str(source), "--output", str(output),
        "--model-dir", str(model_dir), "--num-speakers", "2",
    ]
    completed = subprocess.run(command, capture_output=True, text=True, timeout=3600)
    if completed.returncode != 0:
        detail = (completed.stderr or completed.stdout or "").strip()
        raise RuntimeError(detail or "本机匿名说话人分离失败")
    payload = json.loads(output.read_text(encoding="utf-8"))
    return list(payload.get("turns") or [])


def apply_anonymous_roles(records: list[dict[str, Any]], turns: list[dict[str, Any]]) -> None:
    raw_speakers: list[str] = []
    for turn in turns:
        speaker = str(turn.get("speaker") or "")
        if speaker and speaker not in raw_speakers:
            raw_speakers.append(speaker)
    role_map = {speaker: f"说话人 {chr(ord('A') + index)}" for index, speaker in enumerate(raw_speakers[:2])}
    for record in records:
        raw_speaker = speaker_for(float(record["start"]), float(record["end"]), turns)
        record["speaker"] = role_map.get(raw_speaker, "说话人 A")


def transcribe_track(
    model: WhisperModel,
    source: Path,
    *,
    language: str,
    role: str,
    source_label: str,
    target_label: str,
    translation_source_language: str,
    translation_target_language: str,
    model_name: str,
    ollama_url: str,
    track_order: int,
    progress: Path,
    completed_offset: int,
    progress_message: str,
) -> list[dict[str, Any]]:
    segments, _info = model.transcribe(
        str(source), language=language, beam_size=1, best_of=1,
        vad_filter=True, vad_parameters={"min_silence_duration_ms": 500},
        condition_on_previous_text=False, word_timestamps=False,
    )
    records: list[dict[str, Any]] = []
    for segment in segments:
        source_text = (segment.text or "").strip()
        if not source_text:
            continue
        write_progress(progress, state="transcribing", completed=completed_offset + len(records), total=None, message=progress_message)
        translated = translate_local(
            source_text, model_name, ollama_url,
            translation_source_language, translation_target_language,
        )
        records.append({
            "start": round(float(segment.start), 3),
            "end": round(float(segment.end), 3),
            "speaker": role,
            "source_label": source_label,
            "target_label": target_label,
            "source_text": source_text,
            "translation_text": translated,
            "track_order": track_order,
        })
    return records


def export_results(records: list[dict[str, Any]], exports: Path, stem: str, title: str) -> None:
    # A single TXT document is the default human-facing deliverable. JSONL remains
    # in the job directory as the resumable machine checkpoint.
    exports.mkdir(parents=True, exist_ok=True)
    ordered = sorted(records, key=lambda item: (float(item["start"]), int(item.get("track_order", 0)), float(item["end"])))
    lines: list[str] = [title, ""]
    for item in ordered:
        start_time = seconds_to_srt(float(item["start"]))
        speaker = str(item["speaker"])
        source_label = str(item["source_label"])
        target_label = str(item["target_label"])
        source = str(item["source_text"])
        translated = str(item["translation_text"])
        lines.extend([f"{start_time}  {speaker}", f"{source_label}：{source}", f"{target_label}：{translated}", ""])
    (exports / f"{stem}_双语记录.txt").write_text("\n".join(lines), encoding="utf-8")

def run(args: argparse.Namespace) -> int:
    root = Path(args.secure_root).expanduser().resolve(strict=True)
    dual = bool(args.local_input or args.remote_input)
    if dual and not (args.local_input and args.remote_input):
        raise RuntimeError("双人说话任务必须同时提供 local.wav 与 remote.wav。")
    if not dual and not args.input:
        raise RuntimeError("单人说话任务必须提供一个本地媒体文件。")
    if args.diarization and dual:
        raise RuntimeError("成对双轨录音的身份已由轨道来源确定，不应再使用匿名说话人分离。")

    source = Path(args.input).expanduser().resolve(strict=True) if args.input else None
    local = Path(args.local_input).expanduser().resolve(strict=True) if dual else None
    remote = Path(args.remote_input).expanduser().resolve(strict=True) if dual else None
    job_id = args.job_id or str(uuid.uuid4())
    job_dir = root / "Hermeneus Data" / "jobs" / job_id
    export_dir = root / "Hermeneus Data" / "exports" / job_id
    job_dir.mkdir(parents=True, exist_ok=True)
    checkpoint = job_dir / "transcript.jsonl"
    progress = job_dir / "progress.json"
    manifest = job_dir / "job.json"
    atomic_json(manifest, {
        "schema_version": 2,
        "kind": "offline-dual-track-translation" if dual else "offline-single-speaker-translation",
        "job_id": job_id,
        "mode": "dual_speaker" if dual else "single_speaker",
        "local_track": local.name if local else None,
        "remote_track": remote.name if remote else None,
        "source_file_name": source.name if source else None,
        "model": args.model,
        "network_used": False,
        "created_at": now(),
    })
    write_progress(progress, state="preflight", completed=0, total=None, message="正在检查本机 Ollama 与翻译模型")
    ensure_local_ollama(args.model, args.ollama_url)
    write_progress(progress, state="starting", completed=0, total=None, message="正在加载本地 Whisper 模型")
    model = WhisperModel(args.whisper_model, device="auto", compute_type="int8", local_files_only=True)

    if dual:
        write_progress(progress, state="transcribing", completed=0, total=None, message="正在识别对方说（系统音源）：西语转中文")
        remote_records = transcribe_track(
            model, remote, language="es", role="🎧 对方说（系统音源）",
            source_label="西语", target_label="中文", translation_source_language="西班牙语", translation_target_language="简体中文",
            model_name=args.model, ollama_url=args.ollama_url, track_order=0, progress=progress, completed_offset=0,
            progress_message="正在转写并翻译对方说（西语 → 中文）",
        )
        write_progress(progress, state="transcribing", completed=len(remote_records), total=None, message="正在识别我说（麦克风）：中文转西语")
        local_records = transcribe_track(
            model, local, language="zh", role="🎙 我说（麦克风 → BlackHole）",
            source_label="中文", target_label="西语", translation_source_language="中文", translation_target_language="西班牙语",
            model_name=args.model, ollama_url=args.ollama_url, track_order=1, progress=progress, completed_offset=len(remote_records),
            progress_message="正在转写并翻译我说（中文 → 西语）",
        )
        records = remote_records + local_records
        stem = "双方录音_中西双语"
        title = "双方录音 · 对方说（西语→中文）与我说（中文→西语）"
    else:
        if args.diarization:
            write_progress(progress, state="diarizing", completed=0, total=None, message="正在本机匿名区分说话人 A / B；首次会下载模型到加密卷")
            speaker_turns = run_diarization(args, source, job_dir)
            role = "说话人 A"
            progress_message = "正在转写并翻译普通混音（匿名说话人 A / B）"
        else:
            speaker_turns = []
            role = "单人说话"
            progress_message = "正在转写并翻译单人说话（西语 → 中文）"
        records = transcribe_track(
            model, source, language="es", role=role,
            source_label="西语", target_label="中文", translation_source_language="西班牙语", translation_target_language="简体中文",
            model_name=args.model, ollama_url=args.ollama_url, track_order=0, progress=progress, completed_offset=0,
            progress_message=progress_message,
        )
        if args.diarization:
            apply_anonymous_roles(records, speaker_turns)
            stem = source.stem + "_匿名双人西中双语"
            title = stem + " · 普通混音匿名双人说话"
        else:
            stem = source.stem + "_西中双语"
            title = stem + " · 单人说话"

    with checkpoint.open("w", encoding="utf-8") as handle:
        for index, record in enumerate(sorted(records, key=lambda item: (item["start"], item["track_order"])), start=1):
            record["index"] = index
            handle.write(json.dumps(record, ensure_ascii=False) + "\n")
        handle.flush()
        os.fsync(handle.fileno())
    export_results(records, export_dir, stem, title)
    write_progress(progress, state="completed", completed=len(records), total=len(records), message="已完成本地双向转写、翻译和字幕导出")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Hermeneus offline local translation worker")
    parser.add_argument("--input")
    parser.add_argument("--local-input")
    parser.add_argument("--remote-input")
    parser.add_argument("--secure-root", required=True)
    parser.add_argument("--job-id")
    parser.add_argument("--whisper-model", default="small")
    parser.add_argument("--model", default="qwen2.5:3b")
    parser.add_argument("--ollama-url", default="http://127.0.0.1:11434/api/generate")
    parser.add_argument("--diarization", action="store_true")
    parser.add_argument("--diarization-python", default=str(Path.home() / "Library/Application Support/Hermeneus/diarization-venv/bin/python"))
    parser.add_argument("--diarization-worker", default=str(Path(__file__).with_name("offline_diarization_worker.py")))
    parser.add_argument("--diarization-executable", default="")
    args = parser.parse_args()
    try:
        return run(args)
    except Exception as exc:
        print(f"offline batch failed: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
