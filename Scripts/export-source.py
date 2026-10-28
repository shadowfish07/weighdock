#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Export reviewed tracked source or refresh its inventory; no network or app launch."""
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
FILES = {
    '.gitignore', 'Package.swift', 'LICENSE', 'THIRD_PARTY_NOTICES.md',
    'README.md', 'CHANGELOG.md', 'CONTRIBUTING.md', 'SECURITY.md',
    'Scripts/build.sh', 'Scripts/test.sh', 'Scripts/mihome_reference.py',
    'Scripts/mihome_optimized_check.swift', 'Scripts/mihome-study.sh',
    'Scripts/export-source.py', 'Scripts/archive-source.py',
    'docs/GoogleHealthSetup.md', 'docs/Validation.md', 'docs/Privacy.md',
    'docs/Compatibility.md', 'docs/ReleaseChecklist.md', 'docs/MiHomeCompatibilityStudy.md',
    'examples/README.md', 'examples/desktop-oauth.example.json',
}
PREFIXES = ('Sources/', 'Tests/', 'Reference/', 'Resources/', '.github/')
VENDOR_PATHS = {
    'AppAuth-iOS': ('Sources/', 'UnitTests/'),
    'GTMAppAuth': ('GTMAppAuth/Sources/', 'GTMAppAuth/Tests/'),
    'gtm-session-fetcher': ('Sources/', 'UnitTests/', 'SwiftPMTests/'),
}
VENDOR_DOCS = {'Package.swift', 'LICENSE', 'NOTICE', 'NOTICE.md', 'AUTHORS', 'CONTRIBUTORS', 'README.md'}
STRIP_DEBUG = {'Sources/S400Menu/App.swift', 'Sources/S400Menu/AppModel.swift', 'Sources/S400Menu/Views.swift'}
EXCLUDE = {'Sources/S400Menu/PreviewScenario.swift'}
INVENTORY_FILES = {'EXPORT_MANIFEST.json', 'SHA256SUMS'}


def allowed(name):
    if name in EXCLUDE or name in INVENTORY_FILES:
        return False
    if name in FILES or name.startswith(PREFIXES):
        return True
    parts = name.split('/', 2)
    return (len(parts) == 3 and parts[0] == 'Vendor' and parts[1] in VENDOR_PATHS
            and (parts[2] in VENDOR_DOCS or parts[2].startswith(VENDOR_PATHS[parts[1]])))


def release_branches(text):
    """Only these reviewed files use conditional compilation, all '#if DEBUG'."""
    out, stack = [], []
    active = True
    for line in text.splitlines(keepends=True):
        directive = line.strip()
        if directive.startswith('#if '):
            if directive != '#if DEBUG':
                raise ValueError('Unexpected conditional; review exporter before release')
            stack.append((active, False))
            active = False
        elif directive == '#else':
            if not stack or stack[-1][1]:
                raise ValueError('Unexpected #else')
            parent, _ = stack[-1]
            stack[-1] = (parent, True)
            active = parent
        elif directive == '#endif':
            if not stack:
                raise ValueError('Unexpected #endif')
            active, _ = stack.pop()
        elif directive.startswith('#elseif'):
            raise ValueError('Unexpected #elseif')
        elif active:
            out.append(line)
    if stack:
        raise ValueError('Unclosed #if')
    return ''.join(out)


def tracked_source():
    tracked = subprocess.check_output(['git', 'ls-files', '-z'], cwd=ROOT).decode().split('\0')
    selected = sorted(name for name in tracked if name and allowed(name))
    if not FILES.issubset(selected):
        raise SystemExit('Required public files are not all tracked; review/stage first')
    return selected


def prepare_inputs(selected, production_only):
    entries, prepared = [], []
    for name in selected:
        path = ROOT / name
        if path.is_symlink() or any(p.is_symlink() for p in path.parents if p != ROOT.parent):
            raise SystemExit('Refusing symbolic links in source inputs')
        raw = path.read_bytes()
        output = release_branches(raw.decode()).encode() if production_only and name in STRIP_DEBUG else raw
        mode = 0o755 if path.stat().st_mode & 0o111 else 0o644
        entry = {'path': name, 'sha256': hashlib.sha256(output).hexdigest(), 'mode': mode}
        if output != raw:
            entry.update(source_sha256=hashlib.sha256(raw).hexdigest(),
                         transformation='Keep production branches; remove DEBUG interactive QA only')
        entries.append(entry)
        prepared.append((name, output, mode))
    return entries, prepared


def write_inventory(destination, entries, **metadata):
    # Neither metadata file is a source entry. SHA256SUMS hashes the completed
    # manifest once, but never itself; no circular or placeholder checksums.
    if any(e['path'] in INVENTORY_FILES for e in entries):
        raise ValueError('Inventory cannot include its own metadata files')
    version = plistlib.loads((destination / 'Resources/Info.plist').read_bytes())['CFBundleShortVersionString']
    manifest = {'format': 1, 'project': 'WeighDock', 'version': version, **metadata, 'files': entries}
    target = destination / 'EXPORT_MANIFEST.json'
    target.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + '\n')
    checksums = ''.join(f"{e['sha256']}  {e['path']}\n" for e in entries)
    checksums += hashlib.sha256(target.read_bytes()).hexdigest() + '  EXPORT_MANIFEST.json\n'
    (destination / 'SHA256SUMS').write_text(checksums)


def main():
    if len(sys.argv) != 2:
        raise SystemExit('Usage: python3 Scripts/export-source.py --refresh-inventory | release-prep/<new-directory>')
    if sys.argv[1] == '--refresh-inventory':
        entries, _ = prepare_inputs(tracked_source(), production_only=False)
        write_inventory(ROOT, entries, note='Tracked application source inventory; metadata excluded from source entries.')
        print(f'Refreshed {len(entries)} source digests; manifest hashed once, checksum list not self-hashed.')
        return
    destination = Path(sys.argv[1]).absolute()
    parent = ROOT / 'release-prep'
    if destination.parent != parent or destination.exists() or destination.is_symlink():
        raise SystemExit('Destination must be a new direct child of this project release-prep/')
    if parent.is_symlink():
        raise SystemExit('Refusing symlink output directory')
    entries, prepared = prepare_inputs(tracked_source(), production_only=True)
    revision = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    clean = not subprocess.check_output(['git', 'status', '--porcelain', '--untracked-files=no'], cwd=ROOT)
    parent.mkdir(exist_ok=True)
    destination.mkdir()
    for name, output, mode in prepared:
        target = destination / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(output)
        target.chmod(mode)
    write_inventory(destination, entries, source_revision=revision, source_tracked_tree_clean=clean,
                    note='Source snapshot only; no git history or interactive QA. Tests retain isolated service doubles.')
    print(f'Exported {len(entries)} reviewed files; tracked tree clean: {clean}. No app launched.')


if __name__ == '__main__':
    main()
