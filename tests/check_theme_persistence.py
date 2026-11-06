#!/usr/bin/env python3
"""Read-only verification of the native theme-save evidence in a supplied IPA."""
import argparse
from pathlib import Path
import re
import struct
import sys
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from macho_integrity import read_executable, sections, verify_source


def check(source):
    data = read_executable(source)
    verify_source(data)
    _, image_sections, _ = sections(data)

    def at(address, size):
        for header, digest in image_sections.values():
            start, length, offset = struct.unpack_from('<QQI', header, 32)
            if digest and start <= address and address + size <= start + length:
                return data[offset + address - start:offset + address - start + size]
        raise AssertionError(f'Address outside file-backed sections: {address:#x}')

    def word(address):
        return struct.unpack('<I', at(address, 4))[0]

    def signed(value, bits):
        return value - (1 << bits) if value & (1 << (bits - 1)) else value

    implementation = (Path(__file__).resolve().parents[1] / 'src/themes/ThemeShop.x').read_text()
    sites = implementation.split('sites[] = {', 1)[1].split('    };', 1)[0]
    matches = re.findall(r'\{(0x[0-9a-fA-F]+),\s*(\d+),\s*\{([^}]+)\}\}', sites)
    assert matches, 'No runtime fingerprints found'
    for pc, count, values in matches:
        expected = [int(value.strip(), 16) for value in values.split(',')]
        assert len(expected) == int(count)
        assert at(int(pc, 16), len(expected) * 4) == struct.pack('<' + 'I' * len(expected), *expected), pc

    cursor = 32
    image_uuid = None
    for _ in range(struct.unpack_from('<I', data, 16)[0]):
        command, size = struct.unpack_from('<II', data, cursor)
        if command == 0x1B:
            image_uuid = data[cursor + 8:cursor + 24]
        cursor += size
    assert image_uuid == uuid.UUID('292883e8-e011-3583-adf5-f02241e3277b').bytes
    declaration = implementation.split('expectedUUID[16] = {', 1)[1].split('}', 1)[0]
    assert bytes(int(part.strip(), 16) for part in declaration.split(',')) == image_uuid

    # The constructor supplies a zero-context Swift closure at 0x100233a1c.
    pc = 0x105DF505C
    adrp, add = word(pc), word(pc + 4)
    assert adrp & 0x9F00001F == 0x90000003  # ADRP x3, page
    assert add & 0xFFC003FF == 0x91000063   # ADD x3, x3, imm12
    delta = signed(((adrp >> 5) & 0x7FFFF) << 2 | ((adrp >> 29) & 3), 21)
    callback = (pc & ~0xFFF) + (delta << 12) + ((add >> 10) & 0xFFF)
    assert callback == 0x100233A1C
    call = word(0x100233A34)
    assert call & 0xFC000000 == 0x94000000
    assert 0x100233A34 + (signed(call & 0x3FFFFFF, 26) << 2) == 0x10285E424
    assert struct.unpack('<Q', at(0x10D33F148, 8))[0] == 32
    assert word(0x105DF1834) == 0xD63F0120  # BLR x9 through isPrimaryAccount

    # Both independent branches remain intact and target the native return.
    for branch_pc in (0x105DF1838, 0x105DF184C):
        branch = word(branch_pc)
        assert branch & 0xFFF8001F == 0x36000000  # TBZ w0, bit 0
        assert branch_pc + (signed((branch >> 5) & 0x3FFF, 14) << 2) == 0x105DF1890
    validity_call = word(0x105DF1848)
    assert validity_call & 0xFC000000 == 0x94000000
    assert 0x105DF1848 + (signed(validity_call & 0x3FFFFFF, 26) << 2) == 0x105DF18A8
    print(f'PASS: {len(matches)} runtime fingerprints, UUID, Swift closure and both unmodified theme-save branches (read only).')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path, help='Pristine LINE 26.16.0 IPA or executable')
    check(parser.parse_args().source)
