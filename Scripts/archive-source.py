#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Validate an exported source inventory and archive with anonymous ownership headers."""
import gzip
import hashlib
import io
import json
from pathlib import Path, PurePosixPath
import sys
import tarfile


def main():
    if len(sys.argv) != 2:
        raise SystemExit('Usage: python3 Scripts/archive-source.py <exported-source-directory>')
    root = Path(sys.argv[1]).absolute()
    if root.is_symlink() or not root.is_dir():
        raise SystemExit('Expected a real export directory')
    manifest = json.loads((root / 'EXPORT_MANIFEST.json').read_text())
    expected = {'EXPORT_MANIFEST.json', 'SHA256SUMS'}
    for entry in manifest['files']:
        name = entry['path']
        path = PurePosixPath(name)
        if path.is_absolute() or '..' in path.parts or name in expected:
            raise SystemExit('Invalid or duplicate manifest path')
        expected.add(name)
        file = root / name
        if file.is_symlink() or not file.is_file() or hashlib.sha256(file.read_bytes()).hexdigest() != entry['sha256']:
            raise SystemExit('Export checksum mismatch: ' + name)
    actual = set()
    for file in root.rglob('*'):
        if file.is_symlink():
            raise SystemExit('Refusing a symlink in export')
        if file.is_file():
            actual.add(file.relative_to(root).as_posix())
    if actual != expected:
        raise SystemExit('Export has extra or missing files; use a fresh source-only export')
    sums = ''.join(f"{e['sha256']}  {e['path']}\n" for e in manifest['files'])
    sums += hashlib.sha256((root / 'EXPORT_MANIFEST.json').read_bytes()).hexdigest() + '  EXPORT_MANIFEST.json\n'
    if (root / 'SHA256SUMS').read_text() != sums:
        raise SystemExit('Checksum list mismatch')
    output = root.with_name(root.name + '.tar.gz')
    if output.exists() or output.with_suffix(output.suffix + '.sha256').exists():
        raise SystemExit('Refusing to overwrite an existing archive or checksum')
    modes = {e['path']: e['mode'] for e in manifest['files']}
    # Do not inherit local usernames, ownership, file timestamps or PAX metadata.
    with output.open('xb') as raw:
        with gzip.GzipFile(fileobj=raw, mode='wb', filename='', mtime=0) as compressed:
            with tarfile.open(fileobj=compressed, mode='w', format=tarfile.USTAR_FORMAT) as archive:
                for name in sorted(expected):
                    data = (root / name).read_bytes()
                    info = tarfile.TarInfo(root.name + '/' + name)
                    info.size = len(data)
                    info.mode = modes.get(name, 0o644)
                    info.uid = info.gid = info.mtime = 0
                    info.uname = info.gname = ''
                    archive.addfile(info, io.BytesIO(data))
    digest = hashlib.sha256(output.read_bytes()).hexdigest()
    output.with_suffix(output.suffix + '.sha256').write_text(f'{digest}  {output.name}\n')
    print(f'Archived {len(expected)} files. SHA256: {digest}')


if __name__ == '__main__':
    main()
