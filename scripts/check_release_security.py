#!/usr/bin/env python3
"""Bind public release permission to the exact reviewed source and native recipes."""
import json
from pathlib import Path
import sys
from vendor_ollama import VERSION, SHA256
from rebuild_ollama import REVISION, digest
from rebuild_sndfile import REVISION as DECODER_REVISION
from rebuild_ffmpeg import VERSION as FFMPEG_VERSION, SHA256 as FFMPEG_SHA256
from release_source import ROOT, fingerprint


def reviewed_components():
    return dict(reviewed_ollama_version=VERSION, reviewed_ollama_sha256=SHA256,
                reviewed_security_revision=REVISION, reviewed_decoder_revision=DECODER_REVISION,
                reviewed_decoder_recipe_sha256=digest(ROOT/'scripts/rebuild_sndfile.py'),
                reviewed_ffmpeg_version=FFMPEG_VERSION, reviewed_ffmpeg_source_sha256=FFMPEG_SHA256,
                reviewed_source_sha256=fingerprint())


def check(policy):
    if policy.get('qa_only') is True or policy.get('release_approved') is not True:
        raise ValueError('Release blocked: ' + '; '.join(policy.get('blockers') or ['security review is incomplete']))
    if policy.get('blockers'):
        raise ValueError('Release blocked: unresolved review findings')
    if any(policy.get(k) != v for k, v in reviewed_components().items()):
        raise ValueError('Release blocked: source or native component changed since review')


def main():
    try:
        check(json.loads((ROOT/'release-security.json').read_text()))
    except ValueError as error:
        print(str(error), file=sys.stderr)
        return 1
    print('Release review matches the pinned source and native components')
    return 0


if __name__ == '__main__': raise SystemExit(main())
