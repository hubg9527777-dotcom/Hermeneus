# -*- coding: utf-8 -*-
"""PyInstaller specification for the Hermeneus account-free ONNX diarizer."""
from PyInstaller.utils.hooks import collect_dynamic_libs, copy_metadata

block_cipher = None
# Only the narrow package initializer is imported. Avoid collecting upstream
# CLI modules and their unused ASR/TTS/demo dependency graphs.
datas = copy_metadata("sherpa-onnx")
binaries = collect_dynamic_libs("sherpa_onnx")
hiddenimports = ["sherpa_onnx.lib._sherpa_onnx"]

analysis = Analysis(
    ["offline_diarization_worker.py"], pathex=[], binaries=binaries, datas=datas,
    hiddenimports=hiddenimports, hookspath=[], hooksconfig={}, runtime_hooks=[],
    excludes=["matplotlib", "tkinter", "IPython", "notebook", "jupyter", "pytest", "sphinx", "torch", "torchaudio", "torchcodec", "pyannote", "huggingface_hub", "librosa", "numba", "llvmlite"],
    noarchive=False, cipher=block_cipher,
)
pyz = PYZ(analysis.pure, analysis.zipped_data, cipher=block_cipher)
exe = EXE(
    pyz, analysis.scripts, analysis.binaries, analysis.zipfiles, analysis.datas, [],
    name="offline_diarizer", debug=False, bootloader_ignore_signals=False, strip=False,
    upx=False, console=True, target_arch="arm64",
)
