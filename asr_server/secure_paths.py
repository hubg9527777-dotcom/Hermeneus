"""Bound worker output to the user-selected root; create private atomic files."""
import json
import os
from pathlib import Path
import tempfile
import uuid


def job_identifier(value):
    return str(uuid.UUID(value)) if value else str(uuid.uuid4())


def contained(root, *parts):
    root = Path(root).resolve(strict=True)
    result = root.joinpath(*parts).resolve()
    if result == root or not result.is_relative_to(root):
        raise ValueError('Output path escapes the selected storage directory')
    return result


def atomic_private_text(path, text):
    path = Path(path)
    fd, temporary = tempfile.mkstemp(dir=path.parent, prefix='.' + path.name + '-')
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as stream:
            stream.write(text)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
