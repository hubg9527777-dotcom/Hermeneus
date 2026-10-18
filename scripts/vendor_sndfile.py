"""Reject an unreviewed wheel decoder when freezing either Python worker."""
import json
import shutil
import subprocess
import tempfile
from pathlib import Path
from rebuild_ollama import digest
from rebuild_sndfile import ROOT, SOURCE_SHA256, PATCHES, REVISION

def verified_library():
    folder = ROOT / 'runtime/libsndfile'
    record = json.loads((folder/'build.json').read_text())
    binary = folder/'libsndfile_arm64.dylib'
    expected = dict(revision=REVISION, source_sha256=SOURCE_SHA256,
        patches={name:digest(folder/name) for name in PATCHES},
        library_sha256=digest(binary), sanitized=False, external_codecs=False,
        recipe_sha256=digest(Path(__file__).with_name('rebuild_sndfile.py')))
    if record != expected:
        raise ValueError('Unverified libsndfile build; rebuild the pinned decoder')
    return binary

def replace_decoder(analysis):
    binary = verified_library()
    found = []
    for collection in (analysis.binaries, analysis.datas):
        for index, entry in enumerate(collection):
            name, source, kind = entry
            if 'libsndfile' in Path(name).name:
                found.append(name)
                collection[index] = (name, str(binary), kind)
    if not found:
        raise ValueError('SoundFile decoder missing from frozen worker')


def validate_frozen_record(record, workers):
    """Bind frozen hashes to the exact current source-build decoder record."""
    verified_library()
    current = json.loads((ROOT/'runtime/libsndfile/build.json').read_text())
    if record.get('decoder') != current:
        raise ValueError('Frozen workers refer to a different decoder build')
    expected_image = unsigned_image_digest(ROOT/'runtime/libsndfile/libsndfile_arm64.dylib')
    if record.get('library_image_sha256') != expected_image:
        raise ValueError('Frozen decoder image does not match the current library')
    expected_names = {'asr_server', 'offline_diarizer'}
    if set(record.get('workers', {})) != expected_names or set(workers) != expected_names:
        raise ValueError('Missing or unexpected frozen decoder workers')
    for name, path in workers.items():
        if record.get('embedded_decoders', {}).get(name) != {'_soundfile_data/libsndfile_arm64.dylib': expected_image}:
            raise ValueError('Frozen record does not verify its embedded decoder: ' + name)
        if record['workers'][name] != digest(path):
            raise ValueError('Worker does not match patched decoder build: ' + name)


def unsigned_image_digest(path):
    """Compare every library byte after stripping only its ad-hoc signature."""
    with tempfile.TemporaryDirectory(prefix='hermeneus-decoder-verify-') as folder:
        copy = Path(folder)/'decoder.dylib'
        shutil.copy2(path, copy)
        subprocess.run(['/usr/bin/codesign', '--remove-signature', str(copy)],
                       check=True, capture_output=True)
        return digest(copy)


def verify_embedded_decoder(worker, expected):
    # Build-time dependency already supplied by the worker freezer.
    from PyInstaller.archive.readers import CArchiveReader
    archive = CArchiveReader(str(worker))
    names = [name for name in archive.toc if 'libsndfile' in Path(name).name]
    if names != ['_soundfile_data/libsndfile_arm64.dylib']:
        raise ValueError('Missing or unexpected embedded SoundFile decoder')
    with tempfile.TemporaryDirectory(prefix='hermeneus-embedded-decoder-') as folder:
        image = Path(folder)/'decoder.dylib'
        image.write_bytes(archive.extract(names[0]))
        actual = unsigned_image_digest(image)
    if actual != expected:
        raise ValueError('Frozen worker embeds an old or different decoder: ' + str(worker))
    return {names[0]: actual}
