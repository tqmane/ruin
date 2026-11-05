#!/usr/bin/env python3
"""Enable the native stylesheet settings write for secondary LINE accounts."""
import argparse
import hashlib
from pathlib import Path
import struct

SOURCE_HASH = 'e1ad61171b021566f4a318c93ba1260747bfb220c81a79d5a80121311787d6ad'
FUNCTION_HASH = '8c57c9da2415794c8af73c474ab1b05ab1a5e65516fad9c393f651acd157125f'
IMAGE_BASE = 0x100000000
GATE_PC = 0x105DF1838
FUNCTION_START, FUNCTION_END = 0x105DF17F4, 0x105DF18A8
ORIGINAL = bytes.fromhex('c0020036')  # tbz w0, #0, return-without-writing
REPLACEMENT = bytes.fromhex('1f2003d5')  # nop; evaluate the existing validity check


def patched_bytes(data):
    if hashlib.sha256(data).hexdigest() != SOURCE_HASH:
        raise ValueError('Unrecognized source executable; no theme persistence patch applied.')
    start, end, offset = (a - IMAGE_BASE for a in (FUNCTION_START, FUNCTION_END, GATE_PC))
    if hashlib.sha256(data[start:end]).hexdigest() != FUNCTION_HASH:
        raise ValueError('Native stylesheet settings function differs from the researched build.')
    if data[offset:offset + 4] != ORIGINAL:
        raise ValueError('Native primary-account gate differs from the researched instruction.')
    # The role closure is loaded through StylesheetManager.isPrimaryAccount's
    # verified offset slot. The following independent validity gate is retained.
    if data[offset - 16:offset] != bytes.fromhex('08a540f98802088b095140a920013fd6'):
        raise ValueError('Native primary-account callback load does not match.')
    if struct.unpack_from('<I', data, offset + 20)[0] != 0x36000220:
        raise ValueError('The following native stylesheet validation branch does not match.')
    return data[:offset] + REPLACEMENT + data[offset + 4:]


def apply_to_file(binary):
    data = binary.read_bytes()
    binary.write_bytes(patched_bytes(data))
    return {'version': 1, 'scope': 'StylesheetManager secondary-account settings persistence',
            'nativePC': hex(GATE_PC), 'original': ORIGINAL.hex(),
            'replacement': REPLACEMENT.hex(), 'otherValidityCheckPreserved': True}


def check(binary):
    data = binary.read_bytes()
    patched = patched_bytes(data)
    offset = GATE_PC - IMAGE_BASE
    assert len(patched) == len(data)
    assert patched[:offset] == data[:offset] and patched[offset + 4:] == data[offset + 4:]
    assert patched[offset:offset + 4] == REPLACEMENT
    word = int.from_bytes(ORIGINAL, 'little')
    assert word & 0xFFF8001F == 0x36000000  # TBZ W0, bit zero
    assert GATE_PC + ((word >> 5) & 0x3FFF) * 4 == 0x105DF1890
    try:
        patched_bytes(patched)
    except ValueError:
        pass
    else:
        raise AssertionError('Already modified input was accepted as pristine.')
    print('PASS exact-build stylesheet persistence gate, one-instruction change, validity check retained')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', type=Path, required=True, help='Check without changing the input file')
    check(parser.parse_args().check)
