#!/usr/bin/env python3
"""Read-only verification of the versioned native-theme mappings."""
import argparse
from bisect import bisect_right
import hashlib
import json
from pathlib import Path
import struct
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from macho_integrity import _commands, read_executable, sections, verify_source

ROOT = Path(__file__).resolve().parents[1]
PROOF = ROOT / 'build/upgrade-2617/theme-mapping-proof.json'
MAPPING_MANIFEST = ROOT / 'tests/fixtures/version-mappings.json'


def mapping_for_host(host):
    manifest = json.loads(MAPPING_MANIFEST.read_text())
    candidates = [row for row in manifest['mappings']
                  if all(row['host'][key] == host[value] for key, value in
                         (('version', 'version'), ('build', 'build'), ('uuid', 'uuid'),
                          ('sourceSHA256', 'sha256')))]
    assert len(candidates) == 1, (host, len(candidates))
    return candidates[0]


def mapping_anchors(mapping):
    features = mapping['themes']
    arrays = {}
    for feature in ('shopNavigation', 'shopEligibility', 'validation', 'localPolicy'):
        record = features[feature]
        anchors = record['anchors']
        active_partial_adapter = (feature == 'shopEligibility' and
                                  record.get('nativeReadAdapterStatus') == 'verified')
        if (record['status'] == 'verified' or active_partial_adapter) and anchors:
            arrays[feature] = [
                {'address': int(row['address'], 16), 'wordCount': row['wordCount'],
                 'words': [int(word, 16) for word in row['words']]}
                for row in anchors
            ]
    return arrays


def function_reader(data):
    _, image_sections, _ = sections(data)
    text_header, _ = image_sections[('__TEXT', '__text')]
    text_start, text_size, text_offset = struct.unpack_from('<QQI', text_header, 32)
    text_end = text_start + text_size
    commands = _commands(data)[1]
    base = None
    table = None
    for command, raw in commands:
        if command == 0x19 and raw[8:24].split(b'\0', 1)[0] == b'__TEXT':
            base = struct.unpack_from('<Q', raw, 24)[0]
        elif command == 0x26:
            table = struct.unpack_from('<II', raw, 8)
    if base is None or table is None:
        raise AssertionError('Missing __TEXT or LC_FUNCTION_STARTS')
    offset, length = table
    cursor, limit, address = offset, offset + length, base
    starts = []
    while cursor < limit:
        delta = shift = 0
        while True:
            if cursor >= limit:
                raise AssertionError('Truncated LC_FUNCTION_STARTS ULEB128')
            byte = data[cursor]
            cursor += 1
            delta |= (byte & 0x7f) << shift
            if not byte & 0x80:
                break
            shift += 7
            if shift > 63:
                raise AssertionError('Invalid LC_FUNCTION_STARTS ULEB128')
        if not delta:
            break
        address += delta
        starts.append(address)
    starts.append(text_end)

    def read(address):
        index = bisect_right(starts, address) - 1
        if index < 0 or address >= text_end:
            raise AssertionError(f'No function owner for {address:#x}')
        start, stop = starts[index], starts[index + 1]
        file_offset = text_offset + start - text_start
        raw = data[file_offset:file_offset + stop - start]
        if len(raw) != stop - start:
            raise AssertionError(f'Function bytes outside __TEXT,__text: {start:#x}')
        return {'start': hex(start), 'stop': hex(stop), 'size': stop - start,
                'sha256': hashlib.sha256(raw).hexdigest()}
    return read


def verify_local_policy_functions(data, local_policy, version):
    read_function = function_reader(data)
    revision = '26.16' if version == '26.16.0' else '26.17'

    def verify_function(expected):
        actual = read_function(int(expected['start'], 16))
        assert all(actual[key] == expected[key] for key in ('start', 'stop', 'size', 'sha256'))

    helper = local_policy['helper'][revision]
    verify_function(helper['function'])
    call_site = int(helper['call']['callSite'], 16)
    assert hex(call_site + 4) == helper['call']['returnPC']
    assert branch_target_from_bytes(data, call_site) == int(helper['call']['target'], 16)

    family_key = 'baseline26_16' if version == '26.16.0' else 'candidate26_17'
    for family in local_policy['closureFamilies']:
        sites = family[family_key]
        for name in ('function', 'closureFactory', 'closureThunk'):
            verify_function(sites[name])
        call_site = int(sites['helperCall']['callSite'], 16)
        assert hex(call_site + 4) == sites['helperCall']['returnPC']
        assert branch_target_from_bytes(data, call_site) == int(sites['helperCall']['target'], 16)
        reference = sites['closureEntryReference']
        add_site = int(reference['addSite'], 16)
        actual = bytes_at(data, add_site - 4, 8)
        assert actual == struct.pack('<2I', *(int(word, 16) for word in reference['words']))
        assert adrp_add_target_from_bytes(data, add_site - 4) == int(reference['target'], 16)


def bytes_at(data, address, size):
    _, image_sections, _ = sections(data)
    for header, digest in image_sections.values():
        start, length, offset = struct.unpack_from('<QQI', header, 32)
        if digest and start <= address and address + size <= start + length:
            return data[offset + address - start:offset + address - start + size]
    raise AssertionError(f'Address outside file-backed sections: {address:#x}')


def branch_target_from_bytes(data, address):
    instruction = struct.unpack('<I', bytes_at(data, address, 4))[0]
    assert instruction & 0xfc000000 == 0x94000000
    value = instruction & 0x03ffffff
    if value & (1 << 25):
        value -= 1 << 26
    return address + value * 4


def adrp_add_target_from_bytes(data, address):
    adrp, add = struct.unpack('<2I', bytes_at(data, address, 8))
    assert adrp & 0x9f000000 == 0x90000000
    register = adrp & 31
    assert add & 0xffc00000 == 0x91000000 and add & 31 == register and (add >> 5) & 31 == register
    immediate = ((adrp >> 29) & 3) | (((adrp >> 5) & 0x7ffff) << 2)
    if immediate & (1 << 20):
        immediate -= 1 << 21
    return (address & ~0xfff) + (immediate << 12) + ((add >> 10) & 0xfff)


def check(source, proof_path):
    data = read_executable(source)
    host = verify_source(data)
    version = host['version']
    mapping = mapping_for_host(host)
    arrays = mapping_anchors(mapping)
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

    def adrp_add_target(pc):
        adrp, add = word(pc), word(pc + 4)
        assert adrp & 0x9f000000 == 0x90000000
        register = adrp & 31
        assert add & 0xffc00000 == 0x91000000 and (add & 31) == register and ((add >> 5) & 31) == register
        delta = signed(((adrp >> 5) & 0x7ffff) << 2 | ((adrp >> 29) & 3), 21)
        return (pc & ~0xfff) + (delta << 12) + ((add >> 10) & 0xfff)

    def branch_target(pc):
        instruction = word(pc)
        assert instruction & 0xfc000000 == 0x94000000
        return pc + (signed(instruction & 0x03ffffff, 26) << 2)

    def encoded_rows(rows):
        return [{'address': hex(row['address']), 'wordCount': row['wordCount'],
                 'words': [hex(word) for word in row['words']]} for row in rows]

    for name, rows in arrays.items():
        for row in rows:
            raw = at(row['address'], row['wordCount'] * 4)
            assert raw == struct.pack('<' + 'I' * row['wordCount'], *row['words']), (name, hex(row['address']))

    assert mapping['host']['supportStatus'] in ('verified', 'unverified')
    assert mapping['themes']['shopEligibility']['status'] == (
        'verified' if version == '26.16.0' else 'unsupported')
    if version == '26.16.0':
        assert len(arrays['shopEligibility']) == 23
        assert len(arrays['localPolicy']) == 3
        assert at(0x10a44eb50, len(b'line://shop/theme\0')) == b'line://shop/theme\0'
        assert at(0x10a742270, len(b'validateTheme result:\0')) == b'validateTheme result:\0'

        # The zero-context closure and two independent native save branches
        # remain exactly as found in pristine 26.16.
        assert adrp_add_target(0x105df505c) == 0x100233a1c
        call = word(0x100233a34)
        assert call & 0xfc000000 == 0x94000000
        assert 0x100233a34 + (signed(call & 0x03ffffff, 26) << 2) == 0x10285e424
        assert struct.unpack('<Q', at(0x10d33f148, 8))[0] == 32
        assert word(0x105df1834) == 0xd63f0120
        for branch_pc in (0x105df1838, 0x105df184c):
            branch = word(branch_pc)
            assert branch & 0xfff8001f == 0x36000000
            assert branch_pc + (signed((branch >> 5) & 0x3fff, 14) << 2) == 0x105df1890
        validity_call = word(0x105df1848)
        assert validity_call & 0xfc000000 == 0x94000000
        assert 0x105df1848 + (signed(validity_call & 0x03ffffff, 26) << 2) == 0x105df18a8
    else:
        assert len(arrays['validation']) == 2
        assert len(arrays['localPolicy']) == 4
        assert len(arrays['shopEligibility']) == 22
        assert at(0x10a647430, len(b'line://shop/theme\0')) == b'line://shop/theme\0'
        assert at(0x10a93cbf0, len(b'validateTheme result:\0')) == b'validateTheme result:\0'
        assert adrp_add_target(0x1057a5c94) == 0x10a93cbf0
        assert branch_target(0x1057a5ce8) == 0x10961fd00
        assert word(0x1025cc684) == 0x39402000
        assert word(0x1025cc688) == 0xd65f03c0
        assert arrays['shopNavigation'][0]['address'] == 0x100043524
        assert arrays['validation'][1]['address'] + 8 == 0x1057a5cec
        assert [row['address'] for row in arrays['localPolicy']] == [
            0x105951164, 0x105955ea0, 0x1059556d4, 0x10595829c]
        assert branch_target(0x105951168) == 0x1095c3048
        assert branch_target(0x105955ea4) == 0x105951120
        assert branch_target(0x1059556d8) == 0x105951120
        assert branch_target(0x1059582a0) == 0x105951120

        eligibility = mapping['themes']['shopEligibility']
        assert eligibility['nativeReadAdapterStatus'] == 'verified'
        assert eligibility['shopSchemeScopeStatus'] == 'unverified'
        assert eligibility['modeReturnPC'] == '0x106af1c60'
        assert eligibility['modeCopyReturnPC'] == '0x106ad9b30'
        assert eligibility['accountReturnPC'] == '0x106ad9cd4'
        assert eligibility['plainModeStackOffset'] == '0xb4'
        assert eligibility['preflightAccountReturnPC'] is None
        assert eligibility['themeActionReturnPC'] is None
        assert eligibility['accountChain'] == []
        assert eligibility['accountChainAlternatives'] == [
            {'count': 4, 'returnPCs': ['0x1028b6154', '0x1028b5abc', '0x1028b5a68', '0x1028b5cf4']},
            {'count': 3, 'returnPCs': ['0x1028b6154', '0x1028b5a74', '0x1028b5cf4']}
        ]
        assert branch_target(0x106ad9b2c) == 0x106af1c20
        assert word(0x106ad9b30) == 0xb814c3a0  # stur w0, [x29, #-0xb4]
        assert branch_target(0x106ad9b68) == 0x100008a34
        assert branch_target(0x106ad9cd0) == 0x109630960
        assert eligibility['shopSchemeReturnPCs'] == ['0x1003ac4ac', '0x1003ac4b8']
        assert eligibility['shopSchemeHandlerReturnPCs'] == ['0x1003acd98', '0x1003acf20']
        assert eligibility['nvSchemeReturnPC'] == '0x1003e9a8c'
        assert branch_target(0x1003e9a88) == 0x100764258

    proof = None
    if proof_path.is_file():
        proof = json.loads(proof_path.read_text())
    elif version == '26.17.0':
        raise AssertionError(f'Missing 26.17 mapping proof: {proof_path}')
    if proof:
        record = proof['binaries'][version]
        assert record['build'] == host['build'] and record['uuid'] == host['uuid']
        assert record['sha256'] == host['sha256']
        verify_local_policy_functions(data, record['localPolicy'], version)
        proof_names = {
            '26.16.0': {'shopNavigation': 'kShopNavigation2616',
                        'shopEligibility': 'kShopEligibility2616',
                        'validation': 'kThemeValidation2616',
                        'localPolicy': 'kThemeLocalPolicy2616'},
            '26.17.0': {'shopNavigation': 'kShopNavigation2617',
                        'shopEligibility': 'kShopEligibilityPartialRead2617',
                        'validation': 'kThemeValidation2617',
                        'localPolicy': 'kThemeLocalPolicy2617'}
        }[version]
        for name, rows in arrays.items():
            assert record['instructionAnchors'][proof_names[name]] == encoded_rows(rows), name
        if version == '26.17.0':
            assert record['shopNavigation']['status'] == 'ported'
            assert record['themeValidation']['status'] == 'ported'
            assert record['shopEligibility']['status'] == 'unported'
            partial = record['shopEligibility']['partialReadArray']
            assert partial['nativeReadAdapterStatus'] == 'verified'
            assert partial['shopSchemeScopeStatus'] == 'unverified'
            assert partial['accountReturnPC'] == '0x106ad9cd4'
            assert partial['routerEnabled'] is False
            assert record['localPolicy']['status'] == 'ported'
            assert record['shopNavigation']['implementation'] == '0x100043524'
            assert record['themeValidation']['resultReturnPC'] == '0x1057a5cec'
            assert record['localPolicy']['repositoryReturnPC'] == '0x10595116c'
            assert record['localPolicy']['serverSyncReturnPCs'] == ['0x105955ea8', '0x1059556dc']
            assert record['localPolicy']['readOnlyExcludedReturnPC'] == '0x1059582a4'
            baseline_path = ROOT / 'build/unsigned/Payload/LINE.app/LINE'
            if baseline_path.is_file():
                baseline_data = read_executable(baseline_path)
                baseline_host = verify_source(baseline_data)
                assert baseline_host['version'] == '26.16.0'
                verify_local_policy_functions(baseline_data,
                    proof['binaries']['26.16.0']['localPolicy'], baseline_host['version'])

    print(f"PASS: LINE {host['version']} / {host['build']}; {sum(map(len, arrays.values()))} bounded mapping anchors, UUID/SHA and read-only theme control-flow checks.")


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path, help='Pristine LINE IPA or executable')
    parser.add_argument('--proof', type=Path, default=PROOF, help='Optional read-only theme mapping evidence JSON')
    args = parser.parse_args()
    check(args.source, args.proof)
