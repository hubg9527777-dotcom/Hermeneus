#!/usr/bin/env python3
"""Release gate requested by the developer. Local development is unaffected."""
import json
from pathlib import Path
import sys
from vendor_ollama import VERSION, SHA256
from rebuild_ollama import REVISION


def check(policy):
    if policy.get('qa_only') is True or policy.get('release_approved') is not True:
        raise ValueError('Release blocked: ' + '; '.join(policy.get('blockers') or ['security review is incomplete']))
    if policy.get('reviewed_ollama_version') != VERSION or policy.get('reviewed_ollama_sha256') != SHA256 or policy.get('reviewed_security_revision') != REVISION:
        raise ValueError('Release blocked: runtime changed since the security review')


def main():
    policy = json.loads((Path(__file__).resolve().parents[1] / 'release-security.json').read_text())
    try:
        check(policy)
    except ValueError as error:
        print(str(error), file=sys.stderr)
        return 1
    print('Release security review approved for the pinned runtime')
    return 0


if __name__ == '__main__': raise SystemExit(main())
