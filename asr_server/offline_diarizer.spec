# -*- coding: utf-8 -*-
"""PyInstaller specification for the Hermeneus offline pyannote diarizer."""
from PyInstaller.utils.hooks import collect_all, collect_dynamic_libs, collect_submodules

block_cipher = None
datas, binaries, hiddenimports = [], [], []
for package in ["pyannote.audio", "torch", "torchaudio", "torchcodec", "huggingface_hub", "numpy"]:
    package_datas, package_binaries, package_hiddenimports = collect_all(package)
    datas += package_datas
    binaries += package_binaries
    hiddenimports += package_hiddenimports
binaries += collect_dynamic_libs("torch")
hiddenimports += collect_submodules("pyannote")
hiddenimports += ["torch._C", "torchcodec", "huggingface_hub"]

analysis = Analysis(
    ["offline_diarization_worker.py"], pathex=[], binaries=binaries, datas=datas,
    hiddenimports=hiddenimports, hookspath=[], hooksconfig={}, runtime_hooks=[],
    excludes=["matplotlib", "tkinter", "IPython", "notebook", "jupyter", "pytest", "sphinx"],
    noarchive=False, cipher=block_cipher,
)
pyz = PYZ(analysis.pure, analysis.zipped_data, cipher=block_cipher)
exe = EXE(
    pyz, analysis.scripts, analysis.binaries, analysis.zipfiles, analysis.datas, [],
    name="offline_diarizer", debug=False, bootloader_ignore_signals=False, strip=False,
    upx=False, console=True, target_arch="arm64",
)
