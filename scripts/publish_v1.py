#!/usr/bin/env python3
"""User-run v1.0.0 reissue: verify, commit, push, upload draft, verify, publish."""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import subprocess
import tempfile
from release_source import ROOT, public_path, source_files
from verify_release import verify, digest

REPOSITORY = 'secure-artifacts/Hermeneus'
TAG = 'v1.0.0'


def run(args, **kwargs):
    return subprocess.run(args, cwd=ROOT, check=True, **kwargs)


def output(args):
    return run(args, capture_output=True, text=True).stdout.strip()


def remote_tag():
    value = output(['git', 'ls-remote', '--tags', 'origin', f'refs/tags/{TAG}', f'refs/tags/{TAG}^{{}}'])
    refs = dict(line.split('\t')[::-1] for line in value.splitlines())
    return refs.get(f'refs/tags/{TAG}^{{}}', refs.get(f'refs/tags/{TAG}'))


def release():
    result = subprocess.run(['gh', 'api', f'repos/{REPOSITORY}/releases/tags/{TAG}'], cwd=ROOT, capture_output=True, text=True)
    if result.returncode:
        if 'HTTP 404' in result.stderr: return None
        raise RuntimeError('Cannot read GitHub release state: ' + result.stderr)
    return json.loads(result.stdout)


def publish(folder, manifest):
    if (ROOT/'VERSION').read_text().strip() != '1.0.0':
        raise ValueError('This command only reissues v1.0.0')
    if output(['git', 'branch', '--show-current']) != 'main':
        raise ValueError('Switch to the reviewed main branch first')
    origin = output(['git', 'remote', 'get-url', 'origin'])
    if origin not in {f'https://github.com/{REPOSITORY}.git', f'https://github.com/{REPOSITORY}', f'git@github.com:{REPOSITORY}.git'}:
        raise ValueError('Unexpected origin; refusing to publish elsewhere')
    run(['gh', 'auth', 'status'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    existing = release()
    if existing and not existing.get('draft'):
        raise ValueError('A public v1.0.0 already exists; nothing will be replaced')
    allowed_assets = set(manifest['artifacts']) | {'release-manifest.json', 'SHA256SUMS'}
    if existing and any(asset['name'] not in allowed_assets for asset in existing['assets']):
        raise ValueError('Existing draft has unexpected attachments; review it manually')
    head = output(['git', 'rev-parse', 'HEAD'])
    remote_main = output(['git', 'ls-remote', '--heads', 'origin', 'refs/heads/main']).split()[0]
    if head != remote_main:
        # A locally prepared commit can be retried if its only parent is current main.
        parents = output(['git', 'rev-list', '--parents', '-n', '1', 'HEAD']).split()[1:]
        if parents != [remote_main]:
            raise ValueError('Remote main changed or local history diverged; update/review before publishing')
    old_remote_tag = remote_tag()
    if old_remote_tag and old_remote_tag != head:
        raise ValueError('Remote v1.0.0 points to another commit; no forced push is permitted')
    paths = set(source_files())
    tracked = output(['git', 'ls-files', '-z']).split('\0')
    paths.update(name for name in tracked if name and public_path(name))
    # Never include private evidence or unrelated files already staged by the user.
    staged = output(['git', 'diff', '--cached', '--name-only', '-z']).split('\0')
    if any(name and not public_path(name) for name in staged):
        raise ValueError('Unrelated staged files found; unstage them before publishing')
    run(['git', 'add', '-A', '--', *sorted(paths)])
    changed = subprocess.run(['git', 'diff', '--cached', '--quiet'], cwd=ROOT)
    if changed.returncode not in (0, 1): raise RuntimeError('Cannot inspect staged changes')
    if changed.returncode == 1:
        if old_remote_tag: raise ValueError('Reviewed source differs from the existing remote tag; refusing to overwrite it')
        run(['git', 'commit', '-m', 'security: reissue Hermeneus v1.0.0 build 2 after full review'])
    verify(folder)
    head = output(['git', 'rev-parse', 'HEAD'])
    try:
        old_local = output(['git', 'rev-parse', f'refs/tags/{TAG}'])
    except subprocess.CalledProcessError:
        old_local = None
    if old_local and not old_remote_tag:
        backup = TAG+'-local-backup-'+datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
        run(['git', 'update-ref', 'refs/tags/'+backup, old_local])
    if not old_remote_tag:
        run(['git', 'tag', '-f', '-a', TAG, '-m', 'Hermeneus v1.0.0 security reissue, build 2', head])
        run(['git', 'push', '--atomic', 'origin', 'HEAD:refs/heads/main', f'refs/tags/{TAG}'])
    else:
        run(['git', 'push', 'origin', 'HEAD:refs/heads/main'])
    files = [str(folder/name) for name in sorted(allowed_assets)]
    if existing:
        run(['gh', 'release', 'edit', TAG, '--draft=true', '--title',
             'Hermeneus v1.0.0 · 安全修订版（build 2）', '--notes-file', str(folder/'RELEASE_NOTES.md'), '--repo', REPOSITORY])
        run(['gh', 'release', 'upload', TAG, *files, '--clobber', '--repo', REPOSITORY])
    else:
        run(['gh', 'release', 'create', TAG, *files, '--draft', '--verify-tag', '--title',
             'Hermeneus v1.0.0 · 安全修订版（build 2）', '--notes-file', str(folder/'RELEASE_NOTES.md'), '--repo', REPOSITORY])
    data = release()
    if not data or not data.get('draft') or {a['name'] for a in data['assets']} != allowed_assets:
        raise ValueError('Draft upload incomplete; it remains unpublished')
    with tempfile.TemporaryDirectory(prefix='hermeneus-release-download-') as temporary:
        for asset in data['assets']:
            expected = digest(folder/asset['name'])
            if asset.get('digest'):
                if asset['digest'] != 'sha256:'+expected: raise ValueError('GitHub asset digest mismatch')
            else:
                run(['gh', 'release', 'download', TAG, '--pattern', asset['name'], '--dir', temporary, '--repo', REPOSITORY])
                if digest(Path(temporary)/asset['name']) != expected: raise ValueError('Uploaded attachment differs')
    run(['gh', 'release', 'edit', TAG, '--draft=false', '--latest', '--repo', REPOSITORY])
    print(f'https://github.com/{REPOSITORY}/releases/tag/{TAG}')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--directory', type=Path, default=ROOT/'dist/v1.0.0-reissue')
    parser.add_argument('--publish', action='store_true', help='Commit, push, create/verify draft, then publish')
    args = parser.parse_args(); folder = args.directory.resolve()
    manifest = verify(folder)
    if args.publish: publish(folder, manifest)
    else: print('PASS: release attachments and reviewed source match. No commit, tag, push or upload was performed.')


if __name__ == '__main__': main()
