#!/usr/bin/env python3
"""Run production decoder gates through real Swift witnesses and throwing calls."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
HEADER = '''#include <stdint.h>
void FixtureBind(uintptr_t homeType, uintptr_t *homeTable, uintptr_t globalType, uintptr_t *globalTable);
void FixtureOption(int enabled, int ready);
void FixtureMismatch(int mode);
unsigned long FixtureReads(int kind);
'''

C = r'''
#include <assert.h>
#include <mach/mach.h>
#include <sys/mman.h>
#include <unistd.h>
#include <stdio.h>
#include "fixture.h"
static uintptr_t savedHomeMetadata, savedHomeWitness, savedGlobalMetadata, savedGlobalWitness;
static void Replace(uintptr_t *slot, uintptr_t replacement) {
    assert(SwapSlot(slot, *slot, replacement));
}
void FixtureBind(uintptr_t homeType, uintptr_t *homeTable, uintptr_t globalType, uintptr_t *globalTable) {
    homeMetadata = savedHomeMetadata = homeType; homeWitness = savedHomeWitness = (uintptr_t)homeTable;
    globalMetadata = savedGlobalMetadata = globalType; globalWitness = savedGlobalWitness = (uintptr_t)globalTable;
    // FixtureKey has one associated type and one decode requirement. Swift's
    // Decodable has one init requirement. Production maps use their own slots.
    atomic_store(&originalHome, homeTable[2]); atomic_store(&originalGlobal, globalTable[1]);
    assert(homeTable[2] && globalTable[1]);
    Replace(&homeTable[2], RUINNativeFunctionPointerRaw((const void *)HomeGate));
    Replace(&globalTable[1], RUINNativeFunctionPointerRaw((const void *)GlobalGate));
    atomic_store(&adapterReady, true);
}
void FixtureOption(int enabled, int ready) {
    atomic_store(&optionEnabled, enabled != 0); atomic_store(&adapterReady, ready != 0);
}
void FixtureMismatch(int mode) {
    homeMetadata = savedHomeMetadata; homeWitness = savedHomeWitness;
    globalMetadata = savedGlobalMetadata; globalWitness = savedGlobalWitness;
    if (mode == 1) homeMetadata++;
    if (mode == 2) homeWitness++;
    if (mode == 3) globalMetadata++;
    if (mode == 4) globalWitness++;
}
unsigned long FixtureReads(int kind) {
    return kind == 0 ? atomic_load(&homeReads) : kind == 1 ? atomic_load(&globalReads) : atomic_load(&projectedReads);
}
extern int SwiftLegacyHomeChecks(void);
int main(void) {
    uintptr_t value = 43, copied = 0;
    assert(CopyMemory((uintptr_t)&value, &copied, sizeof(copied)) && copied == value);
    assert(!SwapSlot(NULL, 43, 44));
    assert(!SwapSlot((uintptr_t *)((char *)&value + 1), 43, 44));
    assert(!SwapSlot(&value, 99, 44) && value == 43);
    assert(SwapSlot(&value, 43, 44) && value == 44);
    assert(SwapSlot(&value, 44, 43) && value == 43);
    assert(SwiftLegacyHomeChecks() == 0);
    assert(FixtureReads(0) > 0 && FixtureReads(1) > 0 && FixtureReads(2) > 0);
    puts("PASS production legacy Home gates: real Swift witnesses, native errors, OFF/true/false forwarding, scope rejection and four sibling Bool fields preserved");
    return 0;
}
'''

SWIFT = r'''
import Foundation
import FixtureC

enum Failure: Error { case invalid }
protocol FixtureKey {
    associatedtype Value
    static func decode(_ value: String) throws -> Value
}
enum HomeKey: FixtureKey {
    static func decode(_ value: String) throws -> Bool {
        if value == "Y" { return true }
        if value == "N" { return false }
        throw Failure.invalid
    }
}
struct GlobalHome: Decodable {
    let isEnabled: Bool
    let isOnboardingEnabled: Bool
    let isScrollAffordanceEnabled: Bool
    let isFriendListTooltipEnabled: Bool
    let isBirthdayEffectEnabled: Bool
}
struct MetadataPair {
    let type: UnsafeRawPointer
    let witness: UnsafeMutablePointer<UInt>
}
@inline(never) func read<K: FixtureKey>(_ type: K.Type, _ value: String) throws -> K.Value {
    return try type.decode(value)
}
@inline(never) func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
    return try JSONDecoder().decode(type, from: data)
}
func expectKey(_ value: String, _ expected: Bool) throws {
    let result = try read(HomeKey.self, value)
    precondition(result == expected)
}
func check(_ value: GlobalHome, enabled: Bool) {
    precondition(value.isEnabled == enabled)
    precondition(value.isOnboardingEnabled && !value.isScrollAffordanceEnabled)
    precondition(value.isFriendListTooltipEnabled && !value.isBirthdayEffectEnabled)
}
@_cdecl("SwiftLegacyHomeChecks") public func SwiftLegacyHomeChecks() -> Int32 {
    let key: any FixtureKey.Type = HomeKey.self
    let global: any Decodable.Type = GlobalHome.self
    precondition(MemoryLayout.size(ofValue: key) == MemoryLayout<MetadataPair>.size)
    precondition(MemoryLayout.size(ofValue: global) == MemoryLayout<MetadataPair>.size)
    let keyPair = unsafeBitCast(key, to: MetadataPair.self)
    let globalPair = unsafeBitCast(global, to: MetadataPair.self)
    FixtureBind(UInt(bitPattern: keyPair.type), keyPair.witness,
                UInt(bitPattern: globalPair.type), globalPair.witness)
    let input = Data(#"{"isEnabled":true,"isOnboardingEnabled":true,"isScrollAffordanceEnabled":false,"isFriendListTooltipEnabled":true,"isBirthdayEffectEnabled":false}"#.utf8)
    let inputCopy = input
    let falseInput = Data(String(decoding: input, as: UTF8.self)
        .replacingOccurrences(of: "\"isEnabled\":true", with: "\"isEnabled\":false").utf8)
    do {
        FixtureOption(0, 1)
        try expectKey("Y", true)
        try expectKey("N", false)
        check(try decode(GlobalHome.self, input), enabled: true)
        FixtureOption(1, 1)
        try expectKey("Y", false)
        try expectKey("N", false)
        check(try decode(GlobalHome.self, input), enabled: false)
        check(try decode(GlobalHome.self, falseInput), enabled: false)
        for mode: Int32 in [1, 2] {
            FixtureMismatch(mode)
            try expectKey("Y", true)
        }
        for mode: Int32 in [3, 4] {
            FixtureMismatch(mode)
            check(try decode(GlobalHome.self, input), enabled: true)
        }
        FixtureMismatch(0)
        FixtureOption(1, 0)
        try expectKey("Y", true)
        check(try decode(GlobalHome.self, input), enabled: true)
        FixtureOption(1, 1)
        let before = FixtureReads(2)
        do { _ = try read(HomeKey.self, "invalid"); preconditionFailure("Native error swallowed") }
        catch Failure.invalid {} // Original Swift error survives the C gate.
        let missingField = Data(#"{"isOnboardingEnabled":true}"#.utf8)
        do { _ = try decode(GlobalHome.self, missingField); preconditionFailure("Native decode error swallowed") }
        catch DecodingError.keyNotFound {} // No output bytes exist on this path.
        precondition(FixtureReads(2) == before)
        FixtureOption(0, 1)
        try expectKey("Y", true)
        check(try decode(GlobalHome.self, input), enabled: true)
        precondition(input == inputCopy) // Wire data stays native, including on OFF restoration.
        return 0
    } catch { fatalError("Unexpected native error: \(error)") }
}
'''


def main():
    source = (ROOT / "src/interface/LegacyHome.x").read_text()
    common = source.split("#if !defined(RUIN_LEGACY_HOME_HOST_CHECK)", 1)[0].replace("%config(generator=internal);", "")
    memory = source[source.index("static BOOL CopyMemory("):source.index("static BOOL VerifyRoute(")]
    with tempfile.TemporaryDirectory(prefix="ruin-legacy-home-") as folder:
        directory = Path(folder)
        (directory / "fixture.h").write_text(HEADER)
        (directory / "module.modulemap").write_text('module FixtureC { header "fixture.h" export * }\n')
        fixture = directory / "gates.m"
        fixture.write_text(common + '#include <mach/mach.h>\n' + memory + C)
        swift = directory / "consumer.swift"
        swift.write_text(SWIFT)
        obj = directory / "gates.o"
        executable = directory / "check"
        subprocess.run(["xcrun", "--sdk", "macosx", "clang", "-c", "-fobjc-arc", "-fblocks", "-Wall", "-Wextra", "-Werror",
                        "-Wno-unused-variable", "-I", str(ROOT / "src/interface"), "-I", str(ROOT / "src/known"),
                        "-I", str(directory), str(fixture), "-o", str(obj)], check=True, timeout=40)
        subprocess.run(["xcrun", "--sdk", "macosx", "swiftc", "-parse-as-library", "-Onone", "-I", str(directory), str(swift),
                        str(obj), "-framework", "Foundation", "-o", str(executable)], check=True, timeout=60)
        subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(executable)],
                       check=True, capture_output=True, timeout=15)
        subprocess.run([str(executable)], check=True, timeout=15)


if __name__ == "__main__":
    main()
