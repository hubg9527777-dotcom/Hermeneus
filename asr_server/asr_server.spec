# -*- mode: python ; coding: utf-8 -*-
"""ASR one-file bundle using current importlib metadata and patched build tools."""

from PyInstaller.utils.hooks import collect_all, collect_dynamic_libs, collect_submodules

block_cipher = None

# --------------------------------------------------------------------------
# 1. 重型 AI 依赖：完整收集 datas / binaries / hiddenimports
# --------------------------------------------------------------------------
HEAVY_PACKAGES = [
    "funasr",
    "faster_whisper",
    "torch",
    "ctranslate2",
    "modelscope",
]

datas = []
binaries = []
hiddenimports = []

for pkg in HEAVY_PACKAGES:
    try:
        pkg_datas, pkg_binaries, pkg_hiddenimports = collect_all(pkg)
        datas += pkg_datas
        binaries += pkg_binaries
        hiddenimports += pkg_hiddenimports
        print(f"[spec] collect_all 完成: {pkg} "
              f"(+{len(pkg_datas)} datas, +{len(pkg_binaries)} binaries, "
              f"+{len(pkg_hiddenimports)} hiddenimports)")
    except Exception as exc:  # noqa: BLE001 - 打包期诊断，不吞掉关键包时才继续
        print(f"[spec] 警告：collect_all 处理 {pkg} 失败，已跳过: {exc}")

# ctranslate2 的核心推理库是动态链接的 .dylib，collect_all 有时抓不全，显式补充
binaries += collect_dynamic_libs("ctranslate2")

# Package metadata is collected by collect_all; pkg_resources was removed in
# setuptools 82+. Do not resurrect the obsolete shim or vendor insecure versions.
hiddenimports += [
    "funasr.models",
    "funasr.utils",
    "torch._C",
    "torch.utils.checkpoint",
    "offline_batch_worker",
]

# --------------------------------------------------------------------------
# 3. 裁剪：测试 / 文档 / 可视化 / 交互式解释器相关模块
# --------------------------------------------------------------------------
excludes = [
    "torch.utils.tensorboard",
    "torch.testing",
    "torch.utils.data.datapipes",
    "matplotlib",
    "tkinter",
    "IPython",
    "notebook",
    "jupyter",
    "pytest",
    "sphinx",
    "setuptools.tests",
]

a = Analysis(
    ["server.py"],
    pathex=[],
    binaries=binaries,
    datas=datas,
    hiddenimports=hiddenimports,
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=excludes,
    noarchive=False,
    cipher=block_cipher,
)

from pathlib import Path
import sys
sys.path.insert(0, str(Path(SPECPATH).parent / 'scripts'))
from vendor_sndfile import replace_decoder
replace_decoder(a)

pyz = PYZ(a.pure, a.zipped_data, cipher=block_cipher)

# onefile 模式：不做 COLLECT，产物直接是 dist/asr_server 单文件可执行程序，
# 与 Hermeneus_start.sh / build_dmg.yml 中约定的路径保持一致。
exe = EXE(
    pyz,
    a.scripts,
    a.binaries,
    a.zipfiles,
    a.datas,
    [],
    name="asr_server",
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=False,
    console=True,
    target_arch="arm64",
)
