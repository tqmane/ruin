"""Guard against executable, loader and __LINKEDIT feature patches."""
import importlib.util
from pathlib import Path
import struct
import unittest

spec = importlib.util.spec_from_file_location('macho_integrity',
    Path(__file__).resolve().parents[1] / 'tools/macho_integrity.py')
macho = importlib.util.module_from_spec(spec)
spec.loader.exec_module(macho)


def dylib_command(name, command=0xC):
    raw = name.encode() + b'\0'
    size = (24 + len(raw) + 7) & ~7
    return struct.pack('<6I', command, size, 24, 0, 0, 0) + raw.ljust(size - 24, b'\0')


def fixture(dependencies=(), signature=b'original-signature', padded_strings=False):
    commands = []
    for segment, section, offset, contents, flags in (
        ('__TEXT', '__text', 0x800, b'code' * 16, 0x80000400),
        ('__TEXT', '__const', 0x840, b'metadata' * 8, 0),
        ('__DATA', '__data', 0x900, b'data' * 16, 0),
    ):
        name = segment.encode().ljust(16, b'\0')
        command = struct.pack('<II16sQQQQiiII', 0x19, 152, name,
            0x100000000 + offset, len(contents), offset, len(contents), 7, 5, 1, 0)
        command += struct.pack('<16s16sQQIIIIIIII', section.encode(), name,
            0x100000000 + offset, len(contents), offset, 2, 0, 0, flags, 0, 0, 0)
        commands.append(command)
    # Non-section linker data must be protected too. The string table ends
    # eight zero bytes before the signature, as in insert_dylib's padding case.
    file_size = 0x80 + len(signature or b'')
    commands.append(struct.pack('<II16sQQQQiiII', 0x19, 72, b'__LINKEDIT',
        0x100001000, (file_size + 0xFFF) & ~0xFFF, 0xA00, file_size, 1, 1, 0, 0))
    commands.append(struct.pack('<6I', 0x2, 24, 0xA00, 4, 0xA40,
        0x40 if padded_strings else 0x38))
    commands.append(struct.pack('<IIQQ', 0x80000028, 24, 0x800, 0))
    commands.append(struct.pack('<4I', 0x80000034, 16, 0xA00, 0x20))
    commands.extend(dylib_command(name) for name in dependencies)
    if signature is not None:
        commands.append(struct.pack('<4I', 0x1D, 16, 0xA80, len(signature)))
    raw_commands = b''.join(commands)
    result = bytearray(struct.pack('<8I', 0xFEEDFACF, 0x0100000C, 0, 2,
        len(commands), len(raw_commands), 0x200085, 0) + raw_commands)
    result.extend(b'\0' * (0xA80 - len(result)))
    result[0x800:0x840] = b'code' * 16
    result[0x840:0x880] = b'metadata' * 8
    result[0x900:0x940] = b'data' * 16
    result[0xA00:0xA40] = b'linkedit' * 8
    result[0xA40:0xA78] = b'strings\0' * 7
    return bytes(result) + (signature or b'')


def command_offset(data, wanted, segment=None):
    cursor = 32
    for _ in range(struct.unpack_from('<I', data, 16)[0]):
        command, size = struct.unpack_from('<II', data, cursor)
        if command == wanted and (segment is None or data[cursor + 8:cursor + 24].rstrip(b'\0') == segment):
            return cursor
        cursor += size
    raise AssertionError('fixture command missing')


class PackagingIntegrityTests(unittest.TestCase):
    def setUp(self):
        self.dependencies = ('/usr/lib/libSystem.B.dylib',)
        self.source = fixture(self.dependencies)
        self.packaged = fixture(self.dependencies + (macho.RUIN_LOAD_PATH,), b'new-signature')

    def test_loader_and_signature_changes_are_allowed(self):
        self.assertEqual(macho.verify_packaged(self.source, self.packaged), 3)

    def test_unsigned_intermediate_and_string_padding_are_allowed(self):
        packaged = fixture(self.dependencies + (macho.RUIN_LOAD_PATH,), None, padded_strings=True)
        self.assertEqual(macho.verify_packaged(self.source, packaged), 3)
        resigned = fixture(self.dependencies + (macho.RUIN_LOAD_PATH,), b'new' * 64, padded_strings=True)
        self.assertEqual(macho.verify_packaged(self.source, resigned), 3)

    def test_signature_can_be_added_to_unsigned_source(self):
        self.assertEqual(macho.verify_packaged(fixture(self.dependencies, None), self.packaged), 3)

    def test_instruction_constant_and_data_patches_are_rejected(self):
        for offset in (0x810, 0x850, 0x910):
            with self.subTest(offset=offset):
                modified = bytearray(self.packaged)
                modified[offset] ^= 1
                with self.assertRaisesRegex(ValueError, 'existing LINE Mach-O section'):
                    macho.verify_packaged(self.source, modified)

    def test_section_layout_changes_are_rejected(self):
        modified = bytearray(self.packaged)
        struct.pack_into('<Q', modified, 32 + 72 + 32, 0x100001000)
        with self.assertRaisesRegex(ValueError, 'existing LINE Mach-O section'):
            macho.verify_packaged(self.source, modified)

    def test_dependency_must_be_added_once_and_existing_dependencies_preserved(self):
        for dependencies in (self.dependencies, (macho.RUIN_LOAD_PATH,),
                             self.dependencies + (macho.RUIN_LOAD_PATH,) * 2):
            with self.subTest(dependencies=dependencies):
                with self.assertRaisesRegex(ValueError, 'exactly one added'):
                    macho.verify_packaged(self.source, fixture(dependencies))

    def test_segment_mapping_and_protections_are_immutable(self):
        for segment in (b'__TEXT', b'__LINKEDIT'):
            for field in (24, 40, 56, 60):
                with self.subTest(segment=segment, field=field):
                    modified = bytearray(self.packaged)
                    offset = command_offset(modified, 0x19, segment) + field
                    modified[offset] ^= 1
                    with self.assertRaises(ValueError):
                        macho.verify_packaged(self.source, modified)

    def test_entrypoint_fixup_ranges_and_dependency_metadata_are_immutable(self):
        for command, field in ((0x80000028, 8), (0x80000034, 8), (0xC, 12)):
            with self.subTest(command=command):
                modified = bytearray(self.packaged)
                modified[command_offset(modified, command) + field] ^= 1
                with self.assertRaisesRegex(ValueError, 'existing load command'):
                    macho.verify_packaged(self.source, modified)

    def test_extra_weak_dependency_is_rejected(self):
        modified = bytearray(self.packaged)
        count, size = struct.unpack_from('<II', modified, 16)
        command = dylib_command('/tmp/unexpected.dylib', 0x80000018)
        modified[32 + size:32 + size + len(command)] = command
        struct.pack_into('<II', modified, 16, count + 1, size + len(command))
        with self.assertRaisesRegex(ValueError, 'load-command addition'):
            macho.verify_packaged(self.source, modified)

    def test_linkedit_and_inter_section_bytes_are_immutable(self):
        for offset in (0x980, 0xA08, 0xA48):
            with self.subTest(offset=offset):
                modified = bytearray(self.packaged)
                modified[offset] ^= 1
                with self.assertRaisesRegex(ValueError, 'non-signature Mach-O bytes'):
                    macho.verify_packaged(self.source, modified)

    def test_unrelated_symtab_size_changes_are_rejected(self):
        for size in (0x37, 0x39, 0x49):
            with self.subTest(size=size):
                modified = bytearray(self.packaged)
                struct.pack_into('<I', modified, command_offset(modified, 0x2) + 20, size)
                with self.assertRaisesRegex(ValueError, 'existing load command'):
                    macho.verify_packaged(self.source, modified)

    def test_signature_cannot_hide_existing_linkedit_bytes(self):
        modified = bytearray(self.packaged)
        command = command_offset(modified, 0x1D)
        struct.pack_into('<II', modified, command + 8, 0xA40, len(modified) - 0xA40)
        with self.assertRaisesRegex(ValueError, 'non-signature __LINKEDIT extent'):
            macho.verify_packaged(self.source, modified)

    def test_linkedit_size_must_track_signature_and_file_length(self):
        modified = bytearray(self.packaged)
        command = command_offset(modified, 0x19, b'__LINKEDIT')
        struct.pack_into('<Q', modified, command + 48, 1)
        with self.assertRaisesRegex(ValueError, '__LINKEDIT segment range'):
            macho.verify_packaged(self.source, modified)
        modified = bytearray(self.packaged)
        struct.pack_into('<Q', modified, command + 32, 0x400000)
        with self.assertRaisesRegex(ValueError, 'virtual size'):
            macho.verify_packaged(self.source, modified)

    def test_unknown_or_prepatched_source_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'unmodified LINE'):
            macho.verify_source(self.source)

    def test_malformed_input_is_rejected(self):
        for data in (b'', self.source[:500], b'\0' * 100):
            with self.subTest(length=len(data)):
                with self.assertRaises(ValueError):
                    macho.sections(data)


if __name__ == '__main__':
    unittest.main()
