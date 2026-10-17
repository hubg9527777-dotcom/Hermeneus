"""Account-free official ONNX assets; verify before native parsing.

No YAML, pickle, dynamic classes, configurable URLs, or HF credentials.
"""
from contextlib import contextmanager
import hashlib
import os
from pathlib import Path
import stat
import tarfile
import tempfile
from urllib.parse import urlsplit

MODEL_ID = 'sherpa-onnx/segmentation-3.0+titanet-small'
BASE = 'https://github.com/k2-fsa/sherpa-onnx/releases/download/'
FILES = {
    'segmentation.onnx': (5992913, '220ad67ca923bef2fa91f2390c786097bf305bceb5e261d4af67b38e938e1079'),
    'embedding.onnx': (40257283, 'ad4a1802485d8b34c722d2a9d04249662f2ece5d28a7a039063ca22f515a789e'),
}
ARCHIVE = (6958444, '24615ee884c897d9d2ba09bb4d30da6bb1b15e685065962db5b02e76e4996488')


def copy_verified(source, destination, expected_size, expected_hash):
    source, destination = Path(source), Path(destination)
    if any(p.is_symlink() for p in (source, *source.parents)):
        raise ValueError('模型缓存不能使用符号链接')
    fd = os.open(source, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, 'rb') as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_size != expected_size:
            raise ValueError('模型大小校验失败：' + source.name)
        digest = hashlib.sha256()
        with destination.open('xb') as output:
            remaining = expected_size
            while remaining:
                block = stream.read(min(1024 * 1024, remaining))
                if not block:
                    raise ValueError('模型文件不完整')
                remaining -= len(block)
                digest.update(block)
                output.write(block)
            if stream.read(1) or digest.hexdigest() != expected_hash:
                raise ValueError('模型 SHA-256 校验失败：' + source.name)


def checked_download_url(url):
    p = urlsplit(url)
    if p.scheme != 'https' or p.hostname not in {'github.com', 'release-assets.githubusercontent.com', 'objects.githubusercontent.com'} or p.username or p.password or p.port not in (None, 443):
        raise ValueError('模型下载地址不在官方允许范围内')
    return url


def download(url, destination, size, sha256, progress=None):
    import requests
    with requests.Session() as session:
        session.trust_env = False  # No .netrc or environment credentials.
        for _ in range(5):
            with session.get(checked_download_url(url), stream=True, timeout=(15, 60), allow_redirects=False) as response:
                if response.is_redirect:
                    url = response.headers.get('Location', '')
                    continue
                response.raise_for_status()
                digest, received = hashlib.sha256(), 0
                with destination.open('xb') as output:
                    for block in response.iter_content(1024 * 1024):
                        received += len(block)
                        if received > size:
                            raise ValueError('模型下载超过预期大小')
                        digest.update(block)
                        output.write(block)
                        if progress:
                            progress(received, size)
                if received != size or digest.hexdigest() != sha256:
                    raise ValueError('模型下载完整性校验失败，请重试')
                return
        raise ValueError('模型下载重定向过多')


def ensure_models(cache, allow_download=False, progress=None):
    cache = Path(cache)
    cache.mkdir(mode=0o700, parents=True, exist_ok=True)
    if all((cache / name).is_file() for name in FILES):
        try:
            with verified_models(cache):
                return
        except (OSError, ValueError):
            if not allow_download:
                raise ValueError('模型缓存损坏，请在界面确认重新下载') from None
    if not allow_download:
        raise ValueError('首次使用需要下载约 47 MB 分离模型；请在界面确认下载')
    print('首次下载官方分离模型（无需账号，音频不会上传）', flush=True)
    with tempfile.TemporaryDirectory(prefix='hermeneus-model-download-', dir=cache) as folder:
        root = Path(folder)
        archive = root / 'segmentation.tar.bz2'
        total = ARCHIVE[0] + FILES['embedding.onnx'][0]
        first_progress = (lambda received, _: progress(received, total)) if progress else None
        second_progress = (lambda received, _: progress(ARCHIVE[0] + received, total)) if progress else None
        download(BASE + 'speaker-segmentation-models/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2', archive, *ARCHIVE, progress=first_progress)
        # Never extract archive paths or links; copy one bounded regular member.
        with tarfile.open(archive, 'r:bz2') as stream:
            member = stream.getmember('sherpa-onnx-pyannote-segmentation-3-0/model.onnx')
            if not member.isfile() or member.size != FILES['segmentation.onnx'][0]:
                raise ValueError('官方模型压缩包布局异常')
            with stream.extractfile(member) as source, (root / 'segmentation.onnx').open('xb') as output:
                remaining = member.size
                while remaining:
                    block = source.read(min(1024 * 1024, remaining))
                    if not block:
                        raise ValueError('分离模型压缩包不完整')
                    output.write(block)
                    remaining -= len(block)
        download(BASE + 'speaker-recongition-models/nemo_en_titanet_small.onnx', root / 'embedding.onnx', *FILES['embedding.onnx'], progress=second_progress)
        for name, spec in FILES.items():
            copy_verified(root / name, root / ('verified-' + name), *spec)
        for name in FILES:
            os.replace(root / ('verified-' + name), cache / name)


@contextmanager
def verified_models(cache):
    with tempfile.TemporaryDirectory(prefix='hermeneus-onnx-') as folder:
        root = Path(folder).resolve()
        for name, spec in FILES.items():
            copy_verified(Path(cache) / name, root / name, *spec)
        yield root
