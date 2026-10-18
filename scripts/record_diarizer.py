#!/usr/bin/env python3
"""Bind the frozen diarizer to its reviewed source-build record."""
import argparse
import json
from pathlib import Path
from rebuild_ollama import digest
from rebuild_sherpa import COMMIT, SOURCE_SHA256, PATCH_SHA256, VERSION, FLAGS


def validate(record):
    expected=dict(version=VERSION,source_commit=COMMIT,source_sha256=SOURCE_SHA256,
                  patch_sha256=PATCH_SHA256,flags=FLAGS,minimum_macos='14.0',architecture='arm64',
                  recipe_sha256=digest(Path(__file__).with_name('rebuild_sherpa.py')))
    if any(record.get(k)!=v for k,v in expected.items()):
        raise ValueError('Unreviewed diarization native build')


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--build',type=Path,required=True)
    parser.add_argument('--binary',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args()
    record=json.loads(args.build.read_text());validate(record)
    record['frozen_binary_sha256']=digest(args.binary)
    args.output.write_text(json.dumps(record,indent=2)+'\n')

if __name__=='__main__':main()
