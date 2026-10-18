"""Explicit public source inventory; private audit evidence and outputs stay local."""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PUBLIC_ROOTS = {'HermeneusApp', 'asr_server', 'scripts', 'runtime', 'tests', 'licenses', '.github', 'docs', 'dependencies'}
PUBLIC_FILES = {'.gitignore', '.env.example', 'README.md', 'CHANGELOG.md', 'RELEASE_NOTES.md', 'VERSION', 'BUILD_NUMBER',
                'requirements.txt', 'requirements-diarization.txt', 'constraints-security.txt',
                'Hermeneus_start.sh', 'start.sh', 'LICENSE', 'DIARIZATION_MODELS.md', 'release-security.json'}
SKIP = {'.git', '.build', 'build', 'dist', '__pycache__', '.swiftpm', '.DS_Store', '.pytest_cache'}


def public_path(relative):
    path = Path(relative)
    allowed = (path.suffix in {'.swift', '.py', '.go', '.mod', '.sum', '.sh', '.spec', '.json', '.patch', '.md', '.txt', '.yml', '.yaml', '.toml', '.c', '.h'}
               or path.name in {'LICENSE', 'COPYING', 'COPYING.LGPLv2.1', 'COPYING.LGPLv3', 'BUILD_NUMBER', 'VERSION', '.gitignore', '.env.example', 'LIBSNDFILE_COPYING', 'Makefile'}
               or path.as_posix() == 'runtime/libsndfile/libsndfile_arm64.dylib'
               or path.as_posix().startswith('runtime/ollama/orderedmap/testdata/fuzz/')
               or (path.parts and path.parts[0] == 'licenses' and path.name.endswith(('.tar.gz', '.tar.xz', '.tar.bz2'))))
    return (allowed and bool(path.parts) and not path.is_absolute() and '..' not in path.parts and not any(p in SKIP for p in path.parts)
            and (path.as_posix() in PUBLIC_FILES or path.parts[0] in PUBLIC_ROOTS))


def source_files(root=ROOT):
    files = []
    for path in root.rglob('*'):
        relative = path.relative_to(root)
        if not public_path(relative) or not path.is_file():
            continue
        if path.is_symlink():
            raise ValueError('Public source must not contain symlinks: ' + str(relative))
        if path.suffix.lower() in {'.log', '.pyc', '.pem', '.p12', '.pfx', '.key'} or (path.name.startswith('.env') and path.name != '.env.example'):
            raise ValueError('Private file in public source: ' + str(relative))
        files.append(relative.as_posix())
    return sorted(files)


def fingerprint(root=ROOT):
    # Bind every public build/source input, including native tests, Makefiles,
    # dependency locks and archive patches. Generated decoder records and bytes
    # are verified independently at freeze/package time; reports are descriptive.
    generated = {'release-security.json', 'runtime/libsndfile/build.json',
                 'runtime/libsndfile/frozen.json', 'runtime/libsndfile/libsndfile_arm64.dylib'}
    files = {name: hashlib.sha256((root/name).read_bytes()).hexdigest() for name in source_files(root)
             if name not in generated and not name.startswith(('docs/', 'dependencies/'))}
    return hashlib.sha256(json.dumps(files, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
