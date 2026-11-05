"""Guard against reintroducing packaged executable/data patches."""
import importlib.util
from pathlib import Path
import struct
import unittest

spec = importlib.util.spec_from_file_location('macho_integrity',
    Path(__file__).resolve().parents[1] / 'tools/macho_integrity.py')
macho = importlib.util.module_from_spec(spec)
spec.loader.exec_module(macho)


def fixture(dependencies=(), signature=b'original-signature'):
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
    for name in dependencies:
        raw = name.encode() + b'\0'
        size = (24 + len(raw) + 7) & ~7
        commands.append(struct.pack('<6I', 0xC, size, 24, 0, 0, 0) + raw.ljust(size - 24, b'\0'))
    raw_commands = b''.join(commands)
    result = bytearray(struct.pack('<8I', 0xFEEDFACF, 0x0100000C, 0, 2,
        len(commands), len(raw_commands), 0x200085, 0) + raw_commands)
    result.extend(b'\0' * (0xA00 - len(result)))
    result[0x800:0x840] = b'code' * 16
    result[0x840:0x880] = b'metadata' * 8
    result[0x900:0x940] = b'data' * 16
    return bytes(result) + signature


class PackagingIntegrityTests(unittest.TestCase):
    def setUp(self):
        self.dependencies = ('/usr/lib/libSystem.B.dylib',)
        self.source = fixture(self.dependencies)
        self.packaged = fixture(self.dependencies + (macho.RUIN_LOAD_PATH,), b'new-signature')

    def test_loader_and_signature_changes_are_allowed(self):
        self.assertEqual(macho.verify_packaged(self.source, self.packaged), 3)

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
