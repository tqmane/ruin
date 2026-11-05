#!/usr/bin/env python3
"""Read-only checks that packaging leaves LINE's existing Mach-O sections intact."""
import argparse
import hashlib
from pathlib import Path
import struct
import zipfile

SOURCE_SHA256 = 'e1ad61171b021566f4a318c93ba1260747bfb220c81a79d5a80121311787d6ad'
RUIN_LOAD_PATH = '@executable_path/Frameworks/RUIN.dylib'
MH_MAGIC_64, CPU_TYPE_ARM64, MH_EXECUTE = 0xFEEDFACF, 0x0100000C, 2
LC_SEGMENT_64, LC_LOAD_DYLIB = 0x19, 0xC
ZEROFILL_TYPES = {0x1, 0xC, 0x12}


def _name(raw):
    return raw.split(b'\0', 1)[0].decode('ascii')


def sections(data):
    """Return layout and content hashes, including constants and Swift metadata.

    The load-command area and __LINKEDIT code signature may change when adding
    RUIN's dependency and signing. Existing sections may not change at all.
    """
    if len(data) < 32:
        raise ValueError('Truncated Mach-O header.')
    magic, cpu, subtype, filetype, count, command_size, flags, reserved = struct.unpack_from('<8I', data)
    if (magic, cpu, filetype) != (MH_MAGIC_64, CPU_TYPE_ARM64, MH_EXECUTE):
        raise ValueError('Expected a thin arm64 Mach-O executable.')
    end = 32 + command_size
    if end > len(data) or count > command_size // 8:
        raise ValueError('Invalid Mach-O load-command bounds.')
    result = {}
    dependencies = []
    cursor = 32
    for _ in range(count):
        if cursor + 8 > end:
            raise ValueError('Truncated Mach-O load command.')
        command, size = struct.unpack_from('<II', data, cursor)
        if size < 8 or size % 8 or cursor + size > end:
            raise ValueError('Invalid Mach-O load-command size.')
        if command == LC_SEGMENT_64:
            if size < 72:
                raise ValueError('Truncated segment command.')
            segment = _name(data[cursor + 8:cursor + 24])
            section_count = struct.unpack_from('<I', data, cursor + 64)[0]
            if 72 + section_count * 80 != size:
                raise ValueError('Invalid section table size.')
            for index in range(section_count):
                pos = cursor + 72 + index * 80
                section = _name(data[pos:pos + 16])
                owner = _name(data[pos + 16:pos + 32])
                address, length, offset = struct.unpack_from('<QQI', data, pos + 32)
                section_flags = struct.unpack_from('<I', data, pos + 64)[0]
                key = (segment, section)
                if owner != segment or key in result:
                    raise ValueError('Invalid or duplicate Mach-O section.')
                digest = None
                if length and section_flags & 0xFF not in ZEROFILL_TYPES:
                    if offset < end or offset + length > len(data):
                        raise ValueError('Invalid Mach-O section file range.')
                    digest = hashlib.sha256(memoryview(data)[offset:offset + length]).hexdigest()
                # Preserve the entire section header, not just the file bytes.
                result[key] = (data[pos:pos + 80], digest)
        elif command == LC_LOAD_DYLIB:
            if size < 24:
                raise ValueError('Truncated dylib load command.')
            offset = struct.unpack_from('<I', data, cursor + 8)[0]
            if offset < 24 or offset >= size:
                raise ValueError('Invalid dylib name offset.')
            raw = data[cursor + offset:cursor + size]
            if b'\0' not in raw:
                raise ValueError('Unterminated dylib name.')
            dependencies.append(raw.split(b'\0', 1)[0].decode('utf-8'))
        cursor += size
    if cursor != end or ('__TEXT', '__text') not in result:
        raise ValueError('Invalid command table or missing executable section.')
    return (cpu, subtype, filetype, flags, reserved), result, dependencies


def verify_source(data):
    if hashlib.sha256(data).hexdigest() != SOURCE_SHA256:
        raise ValueError('Source executable does not match the unmodified LINE 26.16.0 build.')
    sections(data)


def verify_packaged(original, packaged):
    original_header, original_sections, original_deps = sections(original)
    header, current_sections, dependencies = sections(packaged)
    if header != original_header or current_sections != original_sections:
        raise ValueError('Packaging changed an existing LINE Mach-O section; refusing the IPA.')
    if RUIN_LOAD_PATH in original_deps or dependencies != original_deps + [RUIN_LOAD_PATH]:
        raise ValueError('Expected exactly one added RUIN dylib dependency.')
    return len(original_sections)


def read_executable(path):
    if path.suffix.lower() != '.ipa':
        return path.read_bytes()
    import plistlib
    with zipfile.ZipFile(path) as archive:
        names = [name for name in archive.namelist()
                 if name.startswith('Payload/') and name.endswith('.app/Info.plist')
                 and name.count('/') == 2]
        if len(names) != 1:
            raise ValueError('Expected exactly one app in Payload.')
        info = plistlib.loads(archive.read(names[0]))
        return archive.read(names[0].rsplit('/', 1)[0] + '/' + info['CFBundleExecutable'])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path, help='Unmodified LINE IPA or executable')
    parser.add_argument('--packaged', type=Path, help='Also compare a packaged IPA or executable')
    args = parser.parse_args()
    original = read_executable(args.source)
    verify_source(original)
    if args.packaged:
        count = verify_packaged(original, read_executable(args.packaged))
        print(f'PASS: all {count} original Mach-O sections preserved; only RUIN dependency added.')
    else:
        print('PASS: recognized unmodified LINE 26.16.0 arm64 executable (read only).')


if __name__ == '__main__':
    main()
