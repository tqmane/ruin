"""Portable coverage of repairing LiveContainer's actual Mach-O metadata."""
from pathlib import Path
import struct
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from prepare_livecontainer import remove_livecontainer_rpaths


LC_RPATH = 0x8000001C
LC_ID_DYLIB = 0xD
PAYLOAD_OFFSET = 1024
PAYLOAD = bytes(range(256)) + b"@loader_path\0@executable_path/../../Tweaks\0"


def path_command(command, path):
    encoded = path.encode("utf-8") + b"\0"
    minimum = 24 if command == LC_ID_DYLIB else 12
    size = (minimum + len(encoded) + 7) & ~7
    fixed = struct.pack("<III", command, size, minimum)
    if command == LC_ID_DYLIB:
        fixed += struct.pack("<III", 2, 0x10000, 0x10000)
    return fixed + encoded.ljust(size - minimum, b"\0")


# Exact byte layout written by upstream LCPatchAddRPath: it rounds only the
# string length, producing 44/28-byte commands instead of 8-byte-aligned ones.
IMPORTED_PATHS = (
    struct.pack("<III", LC_RPATH, 44, 12)
    + b"@executable_path/../../Tweaks\0".ljust(32, b"\0"),
    struct.pack("<III", LC_RPATH, 28, 12)
    + b"@loader_path\0".ljust(16, b"\0"),
)
ID_COMMAND = path_command(LC_ID_DYLIB, "@rpath/RUIN.dylib")
CLEAN_COMMANDS = (
    ID_COMMAND,
    path_command(LC_RPATH, "/usr/lib/swift"),
    struct.pack("<II16s", 0x1B, 24, bytes(range(16))),  # LC_UUID
    path_command(LC_RPATH, "@loader_path/Frameworks"),
    path_command(LC_RPATH, "@executable_path/../../Tweaks-extra"),
    path_command(LC_RPATH, "@loader_path/Folder With Spaces"),
    struct.pack("<IIII", 0x1D, 16, PAYLOAD_OFFSET + len(PAYLOAD), 32),
)


def image(commands, subtype=0):
    table = b"".join(commands)
    header = struct.pack("<8I", 0xFEEDFACF, 0x0100000C, subtype, 6,
                         len(commands), len(table), 0x100080, 0)
    assert len(header) + len(table) < PAYLOAD_OFFSET
    return (header + table).ljust(PAYLOAD_OFFSET, b"\0") + PAYLOAD + b"signature".ljust(32, b"\xff")


def changed_word(data, offset, value):
    copy = bytearray(data)
    struct.pack_into("<I", copy, offset, value)
    return bytes(copy)


class LiveContainerMetadataTests(unittest.TestCase):
    def test_repeated_imports_restore_exact_original_slice(self):
        for subtype in (0, 0x80000002):
            for imports in (1, 2, 3):
                with self.subTest(subtype=subtype, imports=imports):
                    clean = image(CLEAN_COMMANDS, subtype)
                    # Interleave paths with unrelated commands as well as
                    # appending them; removal must not assume a trailing pair.
                    commands = (CLEAN_COMMANDS[:2] + IMPORTED_PATHS[:1]
                                + CLEAN_COMMANDS[2:] + IMPORTED_PATHS[1:]
                                + IMPORTED_PATHS * (imports - 1))
                    imported = image(commands, subtype)
                    original = imported[:]
                    repaired = remove_livecontainer_rpaths(imported)
                    self.assertEqual(repaired, clean)
                    self.assertEqual(imported, original)
                    self.assertEqual(repaired[PAYLOAD_OFFSET:], imported[PAYLOAD_OFFSET:])
                    self.assertEqual(remove_livecontainer_rpaths(repaired), repaired)

    def test_clean_dylib_is_byte_identical(self):
        clean = image(CLEAN_COMMANDS)
        self.assertEqual(remove_livecontainer_rpaths(clean), clean)

    def test_removes_only_exact_owned_paths(self):
        # A normalizer must leave even duplicate non-LC paths alone; the
        # distribution verifier separately rejects such unrelated metadata.
        other = path_command(LC_RPATH, "/usr/lib/swift")
        clean = image(CLEAN_COMMANDS + (other,))
        imported = image(CLEAN_COMMANDS + IMPORTED_PATHS + (other,))
        self.assertEqual(remove_livecontainer_rpaths(imported), clean)

    def test_rejects_foreign_or_ambiguous_install_identity(self):
        foreign_id = path_command(LC_ID_DYLIB, "@rpath/Other.dylib")
        invalid = (
            image(CLEAN_COMMANDS[1:] + IMPORTED_PATHS),
            image((foreign_id,) + CLEAN_COMMANDS[1:] + IMPORTED_PATHS),
            image(CLEAN_COMMANDS + (ID_COMMAND,) + IMPORTED_PATHS),
        )
        for data in invalid:
            with self.subTest(data=data[:64]), self.assertRaises(ValueError):
                remove_livecontainer_rpaths(data)

    def test_rejects_invalid_header_and_command_bounds(self):
        valid = image(CLEAN_COMMANDS + IMPORTED_PATHS)
        count, size = struct.unpack_from("<II", valid, 16)
        invalid = (
            valid[:31],
            changed_word(valid, 0, 0xFEEDFACE),  # 32-bit Mach-O
            changed_word(valid, 4, 0x01000007),  # x86_64
            changed_word(valid, 12, 2),  # executable, not dylib
            changed_word(valid, 16, size // 8 + 1),
            changed_word(valid, 16, count - 1),
            changed_word(valid, 16, count + 1),
            changed_word(valid, 20, len(valid)),
            changed_word(valid, 36, 0),
            changed_word(valid, 36, 10),
            changed_word(valid, 36, size + 4),
        )
        for index, data in enumerate(invalid):
            with self.subTest(case=index), self.assertRaises(ValueError):
                remove_livecontainer_rpaths(data)

    def test_rejects_truncated_or_unbounded_path_strings(self):
        invalid = (
            struct.pack("<II", LC_RPATH, 8),
            struct.pack("<IIII", LC_ID_DYLIB, 16, 12, 0),
            changed_word(IMPORTED_PATHS[0], 8, 8),
            changed_word(IMPORTED_PATHS[0], 8, 44),
            struct.pack("<III", LC_RPATH, 16, 12) + b"AAAA",
            struct.pack("<III", LC_RPATH, 16, 12) + b"\xff\0\0\0",
        )
        for index, malformed in enumerate(invalid):
            data = image(CLEAN_COMMANDS + (malformed,))
            with self.subTest(case=index), self.assertRaises(ValueError):
                remove_livecontainer_rpaths(data)


if __name__ == "__main__":
    unittest.main()
