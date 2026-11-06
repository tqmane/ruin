#!/usr/bin/env python3
"""Read-only checks that packaging changes only LINE's loading/signing metadata."""
import argparse
import hashlib
from pathlib import Path
import plistlib
import struct
import zipfile

SOURCE_SHA256 = 'e1ad61171b021566f4a318c93ba1260747bfb220c81a79d5a80121311787d6ad'
RUIN_LOAD_PATH = '@executable_path/Frameworks/RUIN.dylib'
MH_MAGIC_64, CPU_TYPE_ARM64, MH_EXECUTE = 0xFEEDFACF, 0x0100000C, 2
LC_SEGMENT_64, LC_LOAD_DYLIB, LC_SYMTAB, LC_CODE_SIGNATURE = 0x19, 0xC, 0x2, 0x1D
ZEROFILL_TYPES = {0x1, 0xC, 0x12}


def _name(raw):
    return raw.split(b'\0', 1)[0].decode('ascii')


def _commands(data):
    if len(data) < 32:
        raise ValueError('Truncated Mach-O header.')
    magic, cpu, subtype, filetype, count, command_size, flags, reserved = struct.unpack_from('<8I', data)
    if (magic, cpu, filetype) != (MH_MAGIC_64, CPU_TYPE_ARM64, MH_EXECUTE):
        raise ValueError('Expected a thin arm64 Mach-O executable.')
    end = 32 + command_size
    if end > len(data) or count > command_size // 8:
        raise ValueError('Invalid Mach-O load-command bounds.')
    commands = []
    cursor = 32
    for _ in range(count):
        if cursor + 8 > end:
            raise ValueError('Truncated Mach-O load command.')
        command, size = struct.unpack_from('<II', data, cursor)
        if size < 8 or size % 8 or cursor + size > end:
            raise ValueError('Invalid Mach-O load-command size.')
        commands.append((command, bytes(data[cursor:cursor + size])))
        cursor += size
    if cursor != end:
        raise ValueError('Invalid Mach-O command table.')
    return (cpu, subtype, filetype, flags, reserved), commands, end


def sections(data):
    """Return unchanged section headers/hashes and ordinary dylib dependencies."""
    header, commands, command_end = _commands(data)
    result = {}
    dependencies = []
    for command, raw_command in commands:
        size = len(raw_command)
        # All offsets below are relative to the current load command.
        if command == LC_SEGMENT_64:
            if size < 72:
                raise ValueError('Truncated segment command.')
            segment = _name(raw_command[8:24])
            section_count = struct.unpack_from('<I', raw_command, 64)[0]
            if 72 + section_count * 80 != size:
                raise ValueError('Invalid section table size.')
            for index in range(section_count):
                section_offset = 72 + index * 80
                section_header = raw_command[section_offset:section_offset + 80]
                section = _name(section_header[:16])
                owner = _name(section_header[16:32])
                _, length, offset = struct.unpack_from('<QQI', section_header, 32)
                section_flags = struct.unpack_from('<I', section_header, 64)[0]
                key = (segment, section)
                if owner != segment or key in result:
                    raise ValueError('Invalid or duplicate Mach-O section.')
                digest = None
                if length and (section_flags & 0xFF) not in ZEROFILL_TYPES:
                    if offset < command_end or offset + length > len(data):
                        raise ValueError('Invalid Mach-O section file range.')
                    digest = hashlib.sha256(memoryview(data)[offset:offset + length]).hexdigest()
                # Preserve the entire section header, not just the file bytes.
                result[key] = (section_header, digest)
        elif command == LC_LOAD_DYLIB:
            if size < 24:
                raise ValueError('Truncated dylib load command.')
            offset = struct.unpack_from('<I', raw_command, 8)[0]
            if offset < 24 or offset >= size:
                raise ValueError('Invalid dylib name offset.')
            raw_name = raw_command[offset:]
            if b'\0' not in raw_name:
                raise ValueError('Unterminated dylib name.')
            dependencies.append(raw_name.split(b'\0', 1)[0].decode('utf-8'))
    if ('__TEXT', '__text') not in result:
        raise ValueError('Invalid command table or missing executable section.')
    return header, result, dependencies


def verify_source(data):
    if hashlib.sha256(data).hexdigest() != SOURCE_SHA256:
        raise ValueError('Source executable does not match the unmodified LINE 26.16.0 build.')
    sections(data)


def _signing_layout(data, commands, command_end):
    """Locate the sole trailing signature; everything before it is immutable."""
    linkedit = [raw for command, raw in commands
                if command == LC_SEGMENT_64 and _name(raw[8:24]) == '__LINKEDIT']
    signatures = [raw for command, raw in commands if command == LC_CODE_SIGNATURE]
    if len(linkedit) != 1 or len(signatures) > 1:
        raise ValueError('Expected one __LINKEDIT segment and at most one code signature.')
    segment = linkedit[0]
    vm_size, file_offset, file_size = struct.unpack_from('<QQQ', segment, 32)
    if file_offset < command_end or file_offset + file_size != len(data) or vm_size < file_size:
        raise ValueError('Invalid final __LINKEDIT segment range.')
    prefix_end = len(data)
    if signatures:
        if len(signatures[0]) != 16:
            raise ValueError('Invalid code-signature command.')
        offset, size = struct.unpack_from('<II', signatures[0], 8)
        if not size or offset < file_offset or offset + size != len(data):
            raise ValueError('Code signature must occupy the end of __LINKEDIT.')
        prefix_end = offset
    return segment, prefix_end, bool(signatures)


def _ruin_load_command():
    name = RUIN_LOAD_PATH.encode() + b'\0'
    size = (24 + len(name) + 7) & ~7
    # Exactly the command produced by the pinned insert_dylib tool.
    return struct.pack('<6I', LC_LOAD_DYLIB, size, 24, 0, 0, 0) + name.ljust(size - 24, b'\0')


def verify_packaged(original, packaged):
    original_header, original_sections, original_deps = sections(original)
    header, current_sections, dependencies = sections(packaged)
    if header != original_header or current_sections != original_sections:
        raise ValueError('Packaging changed an existing LINE Mach-O section; refusing the IPA.')
    if RUIN_LOAD_PATH in original_deps or dependencies != original_deps + [RUIN_LOAD_PATH]:
        raise ValueError('Expected exactly one added RUIN dylib dependency.')
    _, old_commands, old_command_end = _commands(original)
    _, new_commands, new_command_end = _commands(packaged)
    old_linkedit, prefix_end, old_signed = _signing_layout(original, old_commands, old_command_end)
    new_linkedit, new_prefix_end, new_signed = _signing_layout(packaged, new_commands, new_command_end)

    # Only a new trailing signature (plus its <=15-byte alignment padding) may
    # change file length. An unsigned intermediate ends exactly at the old one.
    if (new_prefix_end < prefix_end or new_prefix_end - prefix_end > 15 or
            (not new_signed and new_prefix_end != prefix_end) or
            any(packaged[prefix_end:new_prefix_end])):
        raise ValueError('Packaging changed the non-signature __LINKEDIT extent.')
    old_vm_size = struct.unpack_from('<Q', old_linkedit, 32)[0]
    new_vm_size, _, new_file_size = struct.unpack_from('<QQQ', new_linkedit, 32)
    allowed_vm_sizes = {old_vm_size, (new_file_size + 0xFFF) & ~0xFFF,
                        (new_file_size + 0x3FFF) & ~0x3FFF}
    if new_vm_size not in allowed_vm_sizes:
        raise ValueError('Unexpected __LINKEDIT virtual size change.')

    old_fixed = [(command, raw) for command, raw in old_commands if command != LC_CODE_SIGNATURE]
    new_fixed = [(command, raw) for command, raw in new_commands if command != LC_CODE_SIGNATURE]
    if len(new_fixed) != len(old_fixed) + 1 or new_fixed[-1] != (LC_LOAD_DYLIB, _ruin_load_command()):
        raise ValueError('Unexpected load-command addition or removal; only RUIN is allowed.')
    for (old_kind, old), (new_kind, new) in zip(old_fixed, new_fixed):
        if old_kind != new_kind or len(old) != len(new):
            raise ValueError('Packaging changed an existing load command.')
        if old == new:
            continue
        if old_kind == LC_SEGMENT_64 and _name(old[8:24]) == '__LINKEDIT':
            # File offset, VM address, protections, flags and sections stay exact.
            old = old[:32] + b'\0' * 8 + old[40:48] + b'\0' * 8 + old[56:]
            new = new[:32] + b'\0' * 8 + new[40:48] + b'\0' * 8 + new[56:]
        elif old_kind == LC_SYMTAB and len(old) == 24 and old_signed:
            string_offset, string_size = struct.unpack_from('<II', old, 16)
            padding = prefix_end - (string_offset + string_size)
            new_string_size = struct.unpack_from('<I', new, 20)[0]
            # insert_dylib extends the string table over the existing zero pad
            # before stripping the signature; no other symbol-table edit is OK.
            if (0 <= padding <= 16 and new_string_size == string_size + padding and
                    not any(original[string_offset + string_size:prefix_end])):
                new = new[:20] + old[20:24]
        if old != new:
            raise ValueError('Packaging changed an existing load command.')

    if new_command_end > old_command_end and any(original[old_command_end:new_command_end]):
        raise ValueError('RUIN load command would overwrite non-padding bytes.')
    # This also covers __LINKEDIT fixups, exports, symbol tables and inter-section
    # bytes that section hashing alone cannot protect. No executable is written.
    body_start = max(old_command_end, new_command_end)
    original_body = memoryview(original)[body_start:prefix_end]
    packaged_body = memoryview(packaged)[body_start:prefix_end]
    if (prefix_end < body_start or len(packaged) < prefix_end or
            hashlib.sha256(original_body).digest() != hashlib.sha256(packaged_body).digest()):
        raise ValueError('Packaging changed non-signature Mach-O bytes (including __LINKEDIT).')
    return len(original_sections)


def read_executable(path):
    if path.suffix.lower() != '.ipa':
        return path.read_bytes()
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
