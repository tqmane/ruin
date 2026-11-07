#!/usr/bin/env python3
import hashlib
import struct
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
TIMELINE_CASES = ["squareTab", "voom", "shopping", "twShopping"]

MAPPINGS = [
    {
        "version": "26.16.0",
        "build": "2026.1006.1718",
        "sha256": "e1ad61171b021566f4a318c93ba1260747bfb220c81a79d5a80121311787d6ad",
        "uuid": "292883E8-E011-3583-ADF5-F02241E3277B",
        "bridge": 0x100010F38,
        "table": 0x10BEE1590,
        "case_table": 0x107D5CF48,
        "first_witness": 0x109670BF0,
        "last_witness": 0x100725540,
        "getters": [0x10072529C, 0x100725304, 0x100725440, 0x1007254C8, 0x100725520],
        "generation_function": 0x107D5CBDC,
        "generation": {
            "switch_ref": 0x107D5CCEC,
            "switch_words": [0x90000009, 0x913D2129, 0x1000000A, 0xB8A8792B, 0x8B0B014A, 0xD61F0140],
            "calls": [(0x107D5CCDC, 0x28), (0x107D5CD6C, 0x50), (0x107D5CD34, 0x70),
                      (0x107D5CDC8, 0x80), (0x107D5CDD4, 0x98)],
            "shopping_case": 0x107D5CD14,
            "tw_shopping_case": 0x107D5CD0C,
            "none_case": 0x107D5CD34,
        },
    },
    {
        "version": "26.17.0",
        "build": "2026.1103.1841",
        "sha256": "a3de1677f3140ed076554f642933209db2d41b838d2a28b98ab4a2bdcacf1bd8",
        "uuid": "614CED59-07E5-372D-94B2-D4901870C7A0",
        "bridge": 0x100011130,
        "table": 0x10C123698,
        "case_table": 0x107EE13C4,
        "first_witness": 0x10984F1B0,
        "last_witness": 0x1007365A4,
        "getters": [0x100736300, 0x100736368, 0x1007364A4, 0x10073652C, 0x100736584],
        "generation_function": 0x107EE1058,
        "generation": {
            "switch_ref": 0x107EE1168,
            "switch_words": [0x90000009, 0x910F1129, 0x1000000A, 0xB8A8792B, 0x8B0B014A, 0xD61F0140],
            "calls": [(0x107EE1158, 0x28), (0x107EE11E8, 0x50), (0x107EE11B0, 0x70),
                      (0x107EE1244, 0x80), (0x107EE1250, 0x98)],
            "shopping_case": 0x107EE1190,
            "tw_shopping_case": 0x107EE1188,
            "none_case": 0x107EE11B0,
        },
    },
]
SLOTS = [0x28, 0x50, 0x70, 0x80, 0x98]
EXPECTED_CASE_TABLE = [0x24, 0x10, 0x20, 0x18, 0x40]
EXPECTED_BRIDGE = [0xAA1603E0, 0xAA1503E1, 0xD61F0100]
EXPECTED_GENERATOR_PROLOGUE = [0xD10183FF, 0xA90167FA, 0xA9025FF8, 0xA90357F6]


def parse_image(data):
    assert data[:4] == b"\xcf\xfa\xed\xfe", "expected a thin little-endian ARM64 Mach-O"
    ncmds = struct.unpack_from("<I", data, 16)[0]
    pos = 32
    segments = []
    sections = {}
    image_uuid = None
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, pos)
        if cmd == 0x19:
            fields = struct.unpack_from("<16sQQQQiiII", data, pos + 8)
            segment = fields[0].rstrip(b"\0").decode()
            vmaddr, vmsize, fileoff, filesize, _, _, nsects, _ = fields[1:]
            segments.append((segment, vmaddr, vmsize, fileoff, filesize))
            for index in range(nsects):
                at = pos + 72 + index * 80
                sect, seg, address, size, offset = struct.unpack_from("<16s16sQQI", data, at)
                sections[(seg.rstrip(b"\0").decode(), sect.rstrip(b"\0").decode())] = (address, size, offset)
        elif cmd == 0x1B:
            image_uuid = data[pos + 8:pos + 24]
        pos += cmdsize
    return segments, sections, image_uuid


def vm_offset(segments, address, length=1):
    for _, vmaddr, vmsize, fileoff, filesize in segments:
        if vmaddr <= address and address + length <= vmaddr + filesize:
            return fileoff + address - vmaddr
    raise AssertionError(f"VM address outside file-backed segments: {address:#x}")


def word(data, segments, address):
    return struct.unpack_from("<I", data, vm_offset(segments, address, 4))[0]


def relative_string(data, segments, address):
    field = vm_offset(segments, address, 4)
    target = address + struct.unpack_from("<i", data, field)[0]
    offset = vm_offset(segments, target)
    end = data.find(b"\0", offset, min(offset + 512, len(data)))
    assert end >= 0, f"unterminated string at {target:#x}"
    return data[offset:end].decode("utf-8", "replace")


def timeline_enum_cases(data, segments, sections):
    address, size, _ = sections[("__TEXT", "__swift5_types")]
    for slot in range(address, address + size - 3, 4):
        descriptor = slot + struct.unpack_from("<i", data, vm_offset(segments, slot, 4))[0]
        flags = struct.unpack_from("<I", data, vm_offset(segments, descriptor, 4))[0]
        if flags & 0x1F != 18 or relative_string(data, segments, descriptor + 8) != "TimelineTab":
            continue
        field_rel = struct.unpack_from("<i", data, vm_offset(segments, descriptor + 16, 4))[0]
        field_descriptor = descriptor + 16 + field_rel
        fd_offset = vm_offset(segments, field_descriptor, 16)
        record_size = struct.unpack_from("<H", data, fd_offset + 10)[0]
        field_count = struct.unpack_from("<I", data, fd_offset + 12)[0]
        assert record_size == 12
        return [relative_string(data, segments, field_descriptor + 16 + i * record_size + 8)
                for i in range(field_count)]
    raise AssertionError("TimelineTab enum descriptor missing")


def chained_pointer(data, segments, address):
    raw = struct.unpack_from("<Q", data, vm_offset(segments, address, 8))[0]
    assert not raw >> 63, f"unexpected chained bind at {address:#x}"
    target = raw & ((1 << 36) - 1)
    high8 = (raw >> 36) & 0xFF
    image_base = min(vmaddr for name, vmaddr, _, _, _ in segments if name == "__TEXT")
    return image_base + target + (high8 << 56)


def assert_bl_to(data, segments, address, target):
    instruction = word(data, segments, address)
    assert instruction & 0xFC000000 == 0x94000000, f"expected BL at {address:#x}"
    immediate = instruction & 0x03FFFFFF
    if immediate & (1 << 25):
        immediate -= 1 << 26
    destination = address + (immediate << 2)
    assert destination == target, f"wrong BL target at {address:#x}"
    return destination


def function_end(data, segments, start):
    cursor = 32
    base = next(vmaddr for name, vmaddr, *_ in segments if name == "__TEXT")
    for _ in range(struct.unpack_from("<I", data, 16)[0]):
        command, size = struct.unpack_from("<II", data, cursor)
        if command == 0x26:  # LC_FUNCTION_STARTS
            offset, length = struct.unpack_from("<II", data, cursor + 8)
            address = base
            found = False
            end = offset + length
            while offset < end:
                delta = shift = 0
                while True:
                    assert offset < end and shift < 64, "invalid function-start ULEB128"
                    value = data[offset]
                    offset += 1
                    delta |= (value & 0x7F) << shift
                    if not value & 0x80:
                        break
                    shift += 7
                if not delta:
                    break
                address += delta
                if found:
                    return address
                found = address == start
            raise AssertionError("native menu generator bounds missing")
        cursor += size
    raise AssertionError("LC_FUNCTION_STARTS missing")


def check_binary(path, mapping):
    data = path.read_bytes()
    assert hashlib.sha256(data).hexdigest() == mapping["sha256"], f"wrong binary: {path}"
    segments, sections, raw_uuid = parse_image(data)
    assert raw_uuid is not None
    assert raw_uuid.hex().upper() == mapping["uuid"].replace("-", ""), f"wrong UUID: {path}"
    enum_cases = timeline_enum_cases(data, segments, sections)
    assert enum_cases == TIMELINE_CASES
    assert [word(data, segments, mapping["generation_function"] + 4*i)
            for i in range(4)] == EXPECTED_GENERATOR_PROLOGUE
    assert function_end(data, segments, mapping["generation_function"]) == mapping["case_table"]

    bridge_words = [word(data, segments, mapping["bridge"] + i * 4) for i in range(3)]
    assert bridge_words == EXPECTED_BRIDGE
    case_values = list(struct.unpack_from("<5i", data, vm_offset(segments, mapping["case_table"], 20)))
    assert case_values == EXPECTED_CASE_TABLE

    assert chained_pointer(data, segments, mapping["table"]) == mapping["first_witness"]
    assert chained_pointer(data, segments, mapping["table"] + 22 * 8) == mapping["last_witness"]
    getter_pointers = {}
    for slot, getter in zip(SLOTS, mapping["getters"]):
        actual = chained_pointer(data, segments, mapping["table"] + (slot // 8) * 8)
        assert actual == getter
        getter_pointers[hex(slot)] = hex(actual)

    generation = mapping["generation"]
    for address, expected in zip(range(generation["switch_ref"], generation["switch_ref"] + 24, 4),
                                 generation["switch_words"]):
        assert word(data, segments, address) == expected, f"changed switch instruction at {address:#x}"
    call_proof = []
    for load_address, slot in generation["calls"]:
        load_word = word(data, segments, load_address)
        assert load_word == 0xF94002A8 | ((slot // 8) << 10), \
            f"wrong witness slot load at {load_address:#x}"
        call_address = load_address + 4
        call_word = word(data, segments, call_address)
        assert_bl_to(data, segments, call_address, mapping["bridge"])
        call_proof.append({"loadVA": hex(load_address), "slot": hex(slot),
                           "loadWord": hex(load_word), "callVA": hex(call_address),
                           "callWord": hex(call_word), "callTargetVA": hex(mapping["bridge"])})
    dispatch_pc = generation["switch_ref"] + 8
    case_targets = [dispatch_pc + delta for delta in case_values]
    assert case_targets[2] == generation["shopping_case"]
    assert case_targets[3] == generation["tw_shopping_case"]
    assert case_targets[4] == generation["none_case"]
    assert word(data, segments, dispatch_pc - 0x10) == 0x52800058  # squareTab -> menu kind 2
    assert word(data, segments, dispatch_pc + 0x10) == 0x52800078  # voom -> menu kind 3
    assert word(data, segments, generation["shopping_case"]) == 0x52800098  # mov w24, #4
    assert word(data, segments, generation["tw_shopping_case"]) == 0x528000B8  # mov w24, #5
    assert word(data, segments, generation["none_case"]) == 0xF9403AA8  # skip TimelineTab; test NewsRow
    return {
        "version": mapping["version"], "build": mapping["build"],
        "sha256": mapping["sha256"], "uuid": mapping["uuid"],
        "timelineEnumCases": enum_cases,
        "nativeGenerationFunctionVA": hex(mapping["generation_function"]),
        "nativeGenerationFunctionFirstWord": hex(word(data, segments, mapping["generation_function"])),
        "bridgeVA": hex(mapping["bridge"]), "bridgeWords": [hex(x) for x in bridge_words],
        "witnessTableVA": hex(mapping["table"]), "witnessFirst": hex(mapping["first_witness"]),
        "witnessLast": hex(mapping["last_witness"]), "getterPointers": getter_pointers,
        "caseTableVA": hex(mapping["case_table"]), "caseTableWords": [hex(x) for x in case_values],
        "switchReferenceVA": hex(generation["switch_ref"]),
        "switchWords": [hex(x) for x in generation["switch_words"]],
        "getterCallSites": call_proof,
        "timelineSwitchTargets": {
            "squareTab": hex(case_targets[0]),
            "voom": hex(case_targets[1]),
            "shopping": hex(case_targets[2]),
            "twShopping": hex(case_targets[3]),
            "none": hex(case_targets[4]),
        },
    }


def main():
    binary = Path(sys.argv[1])
    source = (ROOT / "src/interface/InterfaceFeatures.x").read_text()
    header = (ROOT / "src/interface/InterfaceFeatures.h").read_text()
    native = (ROOT / "src/interface/NativeTabAvailability.m").read_text()
    shopping_controller = "_TtC17LineTWCommerceTab27TWCommerceTabViewController"

    assert "RUINNativeTabIdentifiers" in header
    assert "RUINInterfaceTabShopping" in header and "RUINInterfaceTabShopping" in source
    assert "RUINHideShoppingTabDefaultsKey" in header
    assert 'RUINHideShoppingTabDefaultsKey = @"RUINInterfaceHideShoppingTab"' in source
    assert "case RUINTabShoppingKind: return [defaults boolForKey:RUINHideShoppingTabDefaultsKey]" in source
    assert "case TimelineShopping: case TimelineTWShopping: return ChoiceShopping;" in native
    assert "nativeMenuAndIndexGenerationPreserved" in native
    for mapping in MAPPINGS:
        mapping_source = (ROOT / "src/known/NativeTabMappings.m").read_text()
        row_start = mapping_source.index(f'{{"{mapping["version"]}", "{mapping["build"]}",')
        depth = 0
        row_end = row_start
        for row_end in range(row_start, len(mapping_source)):
            if mapping_source[row_end] == "{":
                depth += 1
            elif mapping_source[row_end] == "}":
                depth -= 1
                if depth == 0:
                    row_end += 1
                    break
        row = mapping_source[row_start:row_end]
        values = [mapping["bridge"], mapping["table"], mapping["case_table"],
                  mapping["first_witness"], mapping["last_witness"], *mapping["getters"],
                  mapping["generation_function"], *EXPECTED_GENERATOR_PROLOGUE,
                  *SLOTS, *EXPECTED_CASE_TABLE, *EXPECTED_BRIDGE]
        assert all(f"0x{value:x}" in row.lower() for value in values)
    strings = subprocess.run(["strings", "-a", str(binary)], check=True, capture_output=True, text=True).stdout
    assert shopping_controller in strings
    for filename in sys.argv[1:]:
        path = Path(filename)
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        mapping = next((row for row in MAPPINGS if row["sha256"] == digest), None)
        assert mapping is not None, f"unrecognized pristine executable: {path}"
        check_binary(path, mapping)


if __name__ == "__main__":
    main()
