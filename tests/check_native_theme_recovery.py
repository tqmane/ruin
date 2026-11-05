#!/usr/bin/env python3
"""Compare files restored by LINE's My Themes control with the original ZIP."""
import argparse
import hashlib
from pathlib import Path, PurePosixPath
import zipfile


def check(archive, restored):
    restored = Path(restored)
    assert restored.is_dir() and not restored.is_symlink(), 'Restored directory is missing or a link'
    assert not any(path.is_symlink() for path in restored.rglob('*')), 'Restored files contain a link'
    expected = {}
    with zipfile.ZipFile(archive) as source:
        for entry in source.infolist():
            if entry.is_dir():
                continue
            path = PurePosixPath(entry.filename)
            assert not path.is_absolute() and '..' not in path.parts, 'Unsafe archive path'
            assert entry.filename not in expected, 'Duplicate archive file'
            expected[entry.filename] = hashlib.sha256(source.read(entry)).digest()
    assert expected, 'Archive contains no files'
    for name, digest in expected.items():
        target = restored / name
        assert not target.is_symlink() and target.is_file(), f'Missing regular file: {name}'
        assert hashlib.sha256(target.read_bytes()).digest() == digest, f'Content differs: {name}'
    return len(expected)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('archive')
    parser.add_argument('restored_directory')
    args = parser.parse_args()
    count = check(args.archive, args.restored_directory)
    print(f'PASS native My Themes restoration: {count} files match the original ZIP')
