#!/usr/bin/env python3
"""Copy a local FFmpeg and its non-system dylib closure into a relocatable QA bundle."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess


def dependencies(path):
    return [line.strip().split(' (compatibility version')[0] for line in
            subprocess.check_output(['otool', '-L', str(path)], text=True).splitlines()[1:] if line.startswith('\t')]


def vendor(executable, destination):
    executable = executable.resolve(strict=True)
    if destination.exists(): raise ValueError('Refusing to replace existing FFmpeg directory')
    libraries = destination / 'lib';libraries.mkdir(parents=True)
    queue = [(executable, destination / 'ffmpeg')]; seen = {}; inventory = []
    while queue:
        source, output = queue.pop(0)
        if output.name in seen:
            if seen[output.name] != source: raise ValueError('Library-name collision: ' + output.name)
            continue
        seen[output.name] = source
        shutil.copy2(source, output);output.chmod(output.stat().st_mode | 0o200)
        changes = []
        for name in dependencies(source):
            if name == str(source) or name.startswith(('/usr/lib/', '/System/Library/')): continue
            if name.startswith('@rpath/'):
                candidate = source.parent / name.removeprefix('@rpath/')
                if not candidate.is_file(): candidate = source.parent.parent / 'lib' / name.removeprefix('@rpath/')
            elif name.startswith('@loader_path/'):
                candidate = source.parent / name.removeprefix('@loader_path/')
            elif name.startswith(('/opt/homebrew/', '/usr/local/')):
                candidate = Path(name)
            else: raise ValueError('Unresolved dependency: ' + name)
            if candidate.resolve() == source: continue
            if not candidate.is_file(): raise ValueError('Missing dependency: ' + str(candidate))
            target = libraries / candidate.name
            queue.append((candidate.resolve(), target))
            replacement = '@loader_path/' + ('lib/' if output.parent == destination else '') + target.name
            changes += ['-change', name, replacement]
        if output.parent == libraries: changes += ['-id', '@loader_path/' + output.name]
        if changes: subprocess.run(['install_name_tool', *changes, str(output)], check=True)
        inventory.append(dict(file=str(output.relative_to(destination)), source=str(source),
            source_sha256=hashlib.sha256(source.read_bytes()).hexdigest()))
    for output in [destination / 'ffmpeg', *libraries.iterdir()]:
        subprocess.run(['codesign', '--force', '--sign', '-', str(output)], check=True, stdout=subprocess.DEVNULL)
        for dependency in dependencies(output):
            if dependency.startswith(('/opt/homebrew/', '/usr/local/')):
                raise ValueError('External dependency remains: ' + dependency)
    version = subprocess.check_output([str(destination / 'ffmpeg'), '-version'], text=True)
    (destination / 'build-version.txt').write_text(version)
    (destination / 'inventory.json').write_text(json.dumps(inventory, indent=2) + '\n')
    # QA build only: retain the installed source recipe/license evidence. Public
    # redistribution requires a complete license/source-offer review.
    (destination / 'SOURCE-AND-LICENSE-NOTICE.txt').write_text(
        'Local QA build. FFmpeg: https://ffmpeg.org/ ; package recipe: https://formulae.brew.sh/formula/ffmpeg\n'
        'See build-version.txt for enabled libraries and licensing configuration.\n'
        'Formal distribution remains blocked pending license/source-offer review of this native closure.\n')
    print(f'Bundled FFmpeg and {len(inventory)-1} private dynamic libraries')


def main():
    parser = argparse.ArgumentParser();parser.add_argument('destination', type=Path)
    parser.add_argument('--executable', type=Path, default=Path(shutil.which('ffmpeg') or '/nonexistent/ffmpeg'))
    args = parser.parse_args();vendor(args.executable, args.destination)

if __name__ == '__main__': main()
