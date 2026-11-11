#!/usr/bin/env python3
"""Focused host fixture and optional read-only proof against pristine LINE."""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def verify_binary(path, mapping):
    data = path.read_bytes()
    assert hashlib.sha256(data).hexdigest() == mapping['sha256']
    assert struct.unpack_from('<I', data)[0] == 0xfeedfacf
    segments = []
    offset = 32
    for _ in range(struct.unpack_from('<I', data, 16)[0]):
        command, size = struct.unpack_from('<II', data, offset)
        if command == 0x19:
            name, va, _, file_offset, file_size = struct.unpack_from('<16sQQQQ', data, offset + 8)
            segments.append((name.rstrip(b'\0').decode(), va, file_offset, file_size))
        elif command == 0x1b:
            assert data[offset + 8:offset + 24].hex() == mapping['uuid'].replace('-', '').lower()
        offset += size

    def read(va, size, segment_name=None):
        for name, start, file_offset, file_size in segments:
            if (segment_name is None or name == segment_name) and start <= va and va + size <= start + file_size:
                return data[file_offset + va - start:file_offset + va - start + size]
        raise AssertionError(f'address outside {segment_name}: {va:#x}')

    for anchor in mapping['anchors']:
        expected = struct.pack('<' + 'I' * len(anchor['words']), *anchor['words'])
        assert read(anchor['address'], len(expected), '__TEXT') == expected
    assert read(mapping['policyReturnVA'] - 4, 4, '__TEXT') == struct.pack('<I', 0xd63f0100)
    base = next(va for name, va, _, _ in segments if name == '__TEXT')

    def pointer(va):
        raw, = struct.unpack('<Q', read(va, 8))
        assert not raw >> 63
        return base + (raw & ((1 << 36) - 1)) + (((raw >> 36) & 255) << 56)

    def relative(va, indirect=False):
        offset, = struct.unpack('<i', read(va, 4))
        target = va + offset
        return pointer(target - 1) if indirect and offset & 1 else target

    def type_name(descriptor):
        parts, seen = [], set()
        while descriptor and descriptor not in seen and len(seen) < 8:
            seen.add(descriptor)
            name = relative(descriptor + 8)
            raw = bytearray()
            while len(raw) < 128:
                byte = read(name + len(raw), 1)
                if byte == b'\0':
                    break
                raw.extend(byte)
            parts.append(raw.decode())
            parent_offset, = struct.unpack('<i', read(descriptor + 4, 4))
            descriptor = relative(descriptor + 4, True) if parent_offset else 0
        assert not descriptor
        return '.'.join(reversed(parts))

    conformance = mapping['conformanceVA']
    assert type_name(relative(conformance, True)) == 'LineMessagingV2.GeneralSettingsService'
    assert type_name(relative(conformance + 4)) == 'LineMessaging.MessagingGeneralSettingsService'
    words = struct.unpack('<QQ', read(mapping['witnessTableVA'], 16, '__DATA_CONST'))
    for raw, expected in zip(words, (mapping['conformanceVA'], mapping['getterVA'])):
        assert not raw >> 63
        assert base + (raw & ((1 << 36) - 1)) + (((raw >> 36) & 255) << 56) == expected
    configuration = mapping['configurationConformanceVA']
    assert type_name(relative(configuration, True)) == 'LineConfigurationInterface.CompositeConfigurationKey'
    key_type = relative(configuration + 4)
    key_name = b'LabsSilentMessageEnabledKey\0'
    assert read(relative(key_type + 8), len(key_name)) == key_name
    assert read(mapping['configurationValueTypeVA'] & ~1, 3) == b'Sb\0'
    assert read(mapping['configurationReturnVA'] - 4, 4, '__TEXT') == struct.pack('<I', 0xd63f0120)
    read(mapping['configurationWitnessTableVA'], 24, '__DATA')
    for index, field in enumerate(('configurationConformanceVA', 'configurationValueTypeVA', 'configurationGetterVA')):
        assert pointer(mapping['configurationWitnessTableVA'] + index * 8) == mapping[field]
    print(f"PASS pristine 26.17 general/config conformances, scalar/indirect Bool callers and {len(mapping['anchors'])} anchors; binary unchanged")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', type=Path)
    args = parser.parse_args()
    output = ROOT / 'build/check-native-mute-send'
    output.mkdir(parents=True, exist_ok=True)
    includes = ['-I' + str(path) for path in sorted({p.parent for p in (ROOT / 'src').glob('*/*.h')})]
    common = [str(p) for p in sorted((ROOT / 'src/known').glob('*.m'))]
    common += [str(p) for p in sorted((ROOT / 'src/known/versions').glob('*.m'))]
    compiler = ['xcrun', '--sdk', 'macosx', 'clang', '-fobjc-arc', '-fblocks', '-std=gnu11',
                '-Wall', '-Wextra', '-Werror', '-DRUIN_HOST_CHECK=1', *includes]
    source = str(ROOT / 'src/messaging/NativeMuteSend.m')
    subprocess.run([*compiler, '-fsyntax-only', source], cwd=ROOT, check=True)
    executable = output / 'check_native_mute_send'
    subprocess.run([*compiler, '-DRUIN_NATIVE_MUTE_SEND_HOST_CHECK=1', source, *common,
                    '-framework', 'Foundation', '-o', str(executable)], cwd=ROOT, check=True)
    subprocess.run([str(executable)], cwd=ROOT, check=True, timeout=30)
    if args.binary:
        mapping = json.loads(subprocess.check_output([str(executable), '--mapping'], text=True))
        verify_binary(args.binary, mapping)


if __name__ == '__main__':
    main()
