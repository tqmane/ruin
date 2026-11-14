#!/usr/bin/env python3
"""Generated production Logos host check; optional read-only LINE nil-safety audit."""
import argparse
from pathlib import Path
import re
import struct
import subprocess
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[1]
UUID = "614CED59-07E5-372D-94B2-D4901870C7A0"

SHIM = r'''
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "TargetMetadata.h"
#import "FeatureImage.h"
#import <dlfcn.h>
#include <assert.h>
@interface INVocabulary : NSObject
+ (instancetype)sharedVocabulary;
- (void)setVocabularyStrings:(id)strings ofType:(NSInteger)type;
@end
@interface SiriFixtureParent : NSObject
+ (instancetype)sharedVocabulary;
@end
static unsigned originals, resolves, releases, entitlementReads, creates;
static id original;
@implementation SiriFixtureParent
+ (instancetype)sharedVocabulary { originals++; return original; }
@end
@interface _TtC4LINE32NLIntentVocabularyControllerObjC : NSObject @end
@implementation _TtC4LINE32NLIntentVocabularyControllerObjC @end
static NSString *mode;
static BOOL matchingCaller = YES, resolving = YES, failDladdr;
static struct mach_header_64 fixtureHeader;
static NSDictionary *FixtureInfo(void) {
    return @{@"CFBundleIdentifier":[mode isEqual:@"target"] ? @"other.app" : @"jp.naver.line",
        @"CFBundleShortVersionString":[mode isEqual:@"build"] ? @"26.16.0" : @"26.17.0",
        @"CFBundleVersion":[mode isEqual:@"build"] ? @"2026.1006.1718" : @"2026.1103.1841"};
}
static BOOL FixtureResolve(const RUINHostIdentity *host, Class owner, RUINFeatureImage *out) {
    assert(owner == _TtC4LINE32NLIntentVocabularyControllerObjC.class);
    assert(!strcmp(host->uuid,"614CED59-07E5-372D-94B2-D4901870C7A0"));
    resolves++;
    if (!resolving) return NO;
    *out = (RUINFeatureImage){.image={.header=&fixtureHeader},.convertedExecutable=YES};
    return YES;
}
static void FixtureRelease(RUINFeatureImage *image) { assert(image->image.header); releases++; }
static int FixtureDladdr(const void *address, Dl_info *info) {
    assert(address); memset(info,0,sizeof(*info));
    info->dli_fbase = matchingCaller ? &fixtureHeader : NULL;
    return !failDladdr;
}
#define RUINResolveFeatureImage FixtureResolve
#define RUINReleaseFeatureImage FixtureRelease
#define dladdr FixtureDladdr
'''

CHECK = r'''
#undef dladdr
#undef RUINResolveFeatureImage
#undef RUINReleaseFeatureImage
RUINSiriTaskRef SecTaskCreateFromSelf(CFAllocatorRef allocator) {
    assert(allocator == kCFAllocatorDefault); creates++;
    return [mode isEqual:@"task"] ? NULL : (RUINSiriTaskRef)CFRetain(kCFBooleanTrue);
}
CFTypeRef SecTaskCopyValueForEntitlement(RUINSiriTaskRef task, CFStringRef name, CFErrorRef *error) {
    assert(task && CFEqual(name,CFSTR("com.apple.developer.siri")) && error && !*error);
    entitlementReads++;
    if ([mode isEqual:@"error"]) *error = CFErrorCreate(NULL,CFSTR("fixture"),1,NULL);
    if ([mode isEqual:@"true"]) return CFRetain(kCFBooleanTrue);
    if ([mode isEqual:@"false"]) return CFRetain(kCFBooleanFalse);
    if ([mode isEqual:@"number"]) { int one = 1; return CFNumberCreate(NULL,kCFNumberIntType,&one); }
    return NULL;
}
static id Factory(id self, SEL cmd) { (void)self; (void)cmd; originals++; return original; }
int main(int argc, const char **argv) { @autoreleasepool {
    assert(argc == 2); mode = @(argv[1]); original = [NSObject new];
    Class cls = objc_allocateClassPair(SiriFixtureParent.class,"INVocabulary",0);
    assert(cls);
    if (![mode isEqual:@"inherited"])
        assert(class_addMethod(object_getClass(cls),@selector(sharedVocabulary),(IMP)Factory,
            [mode isEqual:@"abi"] ? "@24@0:8@16" : "@16@0:8"));
    objc_registerClassPair(cls);
    resolving = ![mode isEqual:@"image"] && ![mode isEqual:@"retry"];
    RUINInstallSiriCompatibility();
    if ([mode isEqual:@"retry"]) { assert(!atomic_load(&sInstalled)); resolving = YES; RUINInstallSiriCompatibility(); }
    BOOL installed = [@[@"absent",@"false",@"retry"] containsObject:mode];
    NSDictionary *diagnostics = RUINSiriCompatibilityDiagnostics();
    assert([diagnostics[@"installed"] boolValue] == installed);
    if (!installed) {
        NSString *status = @{@"true":@"native_entitled", @"task":@"entitlement_unreadable",
            @"error":@"entitlement_unreadable", @"number":@"entitlement_unreadable",
            @"target":@"wrong_target", @"build":@"nil_safety_unproven",
            @"image":@"owner_image_unavailable", @"abi":@"factory_abi_unavailable",
            @"inherited":@"factory_abi_unavailable"}[mode];
        assert(status && [diagnostics[@"status"] isEqual:status]);
        assert([(id)cls sharedVocabulary] == original && originals == 1);
        assert(!atomic_load(&sSkipped));
        assert(releases == (unsigned)([mode isEqual:@"abi"] || [mode isEqual:@"inherited"]));
    } else {
        unsigned oldCreates = creates, oldResolves = resolves;
        RUINInstallSiriCompatibility();
        assert(creates == oldCreates && resolves == oldResolves);
        id value = [(id)cls sharedVocabulary];
        assert(!value && !originals);
        // Mirror both audited call sites: retain a nil result, message it, and release.
        [value setVocabularyStrings:[NSOrderedSet orderedSetWithObject:@"fixture"] ofType:1];
        [value setVocabularyStrings:[NSOrderedSet orderedSet] ofType:2];
        assert(!originals && atomic_load(&sSkipped) == 1);
        matchingCaller = NO;
        assert([(id)cls sharedVocabulary] == original && originals == 1);
        matchingCaller = YES; failDladdr = YES;
        assert([(id)cls sharedVocabulary] == original && originals == 2);
        failDladdr = NO;
        Class child = objc_allocateClassPair(cls,"SiriFixtureChild",0); objc_registerClassPair(child);
        assert([(id)child sharedVocabulary] == original && originals == 3);
        assert(atomic_load(&sForwarded) == 3);
        assert([RUINSiriCompatibilityDiagnostics()[@"skippedVocabularyFactories"] unsignedIntValue] == 1);
    }
    assert(entitlementReads == creates - (unsigned)[mode isEqual:@"task"]);
    printf("PASS Siri compatibility %s\n",argv[1]);
} return 0; }
'''


def host_check():
    production = ROOT / "src/platform/SiriCompatibility.x"
    source = production.read_text()
    source = source.replace("#import <Intents/INVocabulary.h>", "")
    source = source.replace("NSBundle.mainBundle.infoDictionary", "FixtureInfo()")
    with tempfile.TemporaryDirectory(prefix="ruin-siri-host-") as temporary:
        directory = Path(temporary)
        logos = directory / "siri.x"
        logos.write_text(SHIM + source + CHECK)
        generated = directory / "siri.m"
        result = subprocess.run(["perl", str(ROOT / "vendor/logos/bin/logos.pl"),
            "-c", "generator=internal", "-c", "warnings=error", str(logos)],
            check=True, capture_output=True, text=True)
        generated.write_text(result.stdout)
        assert "MSHook" not in result.stdout and "substrate.h" not in result.stdout
        sources = [ROOT / "src/known/KnownMappings.m", ROOT / "src/known/BinaryVerifier.m",
                   *sorted((ROOT / "src/known/versions").glob("*.m"))]
        subprocess.run(["xcrun", "--sdk", "macosx", "clang", "-fobjc-arc", "-fblocks",
            "-std=gnu11", "-Wall", "-Wextra", "-Werror",
            *[arg for name in ("core", "known", "platform") for arg in ("-I", str(ROOT / "src" / name))],
            str(generated), *map(str,sources), "-framework", "Foundation", "-o", str(directory / "check")], check=True)
        for mode in ("absent", "false", "true", "task", "error", "number", "target", "build",
                     "image", "abi", "inherited", "retry"):
            subprocess.run([str(directory / "check"),mode],check=True,timeout=10)
        # Compile-check the unmodified adapter against the real iOS SDK. No link,
        # app build, Makefile invocation, or generated files in the repository.
        result = subprocess.run(["perl", str(ROOT / "vendor/logos/bin/logos.pl"),
            "-c", "generator=internal", "-c", "warnings=error", str(production)],
            check=True, capture_output=True, text=True)
        generated.write_text(result.stdout)
        sdk = subprocess.check_output(["xcrun","--sdk","iphoneos","--show-sdk-path"],text=True).strip()
        for arch in ("arm64", "arm64e"):
            subprocess.run(["xcrun","--sdk","iphoneos","clang","-arch",arch,"-isysroot",sdk,
                "-miphoneos-version-min=18.0","-fobjc-arc","-fblocks","-std=gnu11",
                "-Wall","-Wextra","-Werror","-fsyntax-only","-I",str(ROOT / "src/platform"),
                str(generated)],check=True)
        print("PASS unmodified Siri adapter iOS SDK syntax: arm64 and arm64e")


def binary_check(path):
    """Evidence only: addresses below are never used to dispatch or patch production."""
    data = path.read_bytes()
    assert struct.unpack_from("<I",data)[0] == 0xFEEDFACF
    sections, segments = {}, []
    offset = 32
    actual_uuid = None
    for _ in range(struct.unpack_from("<I",data,16)[0]):
        command, size = struct.unpack_from("<II",data,offset)
        if command == 0x1B:
            actual_uuid = str(uuid.UUID(bytes=data[offset+8:offset+24])).upper()
        if command == 0x19:
            address, length, file_offset, file_size = struct.unpack_from("<QQQQ",data,offset+24)
            segments.append((address,file_size,file_offset))
            for i in range(struct.unpack_from("<I",data,offset+64)[0]):
                entry = offset+72+i*80
                name = data[entry:entry+16].split(b"\0")[0].decode()
                address, length, file_offset = struct.unpack_from("<QQI",data,entry+32)
                sections[name] = (address,length,file_offset)
        offset += size
    assert actual_uuid == UUID

    def read(address, length):
        for base,size,offset in segments:
            if base <= address and address+length <= base+size:
                return data[offset+address-base:offset+address-base+length]
        raise AssertionError(hex(address))

    def pointer(address):
        raw, = struct.unpack("<Q",read(address,8))
        return 0x100000000 + (raw & ((1 << 36)-1))

    def cstring(address):
        return read(address,128).split(b"\0")[0].decode()

    # A single sharedVocabulary selector ref, used by the one ObjC stub below.
    assert cstring(pointer(0x10D036470)) == "sharedVocabulary"
    base,length,offset = sections["__objc_selrefs"]
    refs = [base+i for i in range(0,length,8) if pointer(base+i) == pointer(0x10D036470)]
    assert refs == [0x10D036470]
    assert cstring(pointer(0x10D035B80)) == "setVocabularyStrings:ofType:"

    base,length,offset = sections["__text"]
    branches = {0x107C12AE0:[], 0x109688120:[]}
    for i,(word,) in enumerate(struct.iter_unpack("<I",data[offset:offset+length])):
        if word & 0x7C000000 == 0x14000000:
            immediate = word & 0x3FFFFFF
            if immediate & 0x2000000:
                immediate -= 1 << 26
            address = base+i*4
            target = address+immediate*4
            if target in branches:
                branches[target].append(address)
    assert branches == {0x107C12AE0:[0x1001FB9F0,0x1001FC2DC],0x109688120:[0x107C12AE0]}

    def disassemble(start,end):
        output = subprocess.check_output(["xcrun", "llvm-objdump", "--disassemble",
            f"--start-address={start:#x}", f"--stop-address={end:#x}", str(path)],text=True)
        rows = []
        for line in output.splitlines():
            match = re.match(r"([0-9a-f]+):\s+[0-9a-f]{8}\s+(.+)",line)
            if match:
                rows.append((int(match[1],16),match[2].split(" ;")[0].strip()))
        return rows

    # Callee-saved holder never dereferenced or passed as data. Both uses are
    # receiver-only objc_msgSend; release_x24/release_x26 tolerate nil as well.
    first = disassemble(0x1001FB9F4,0x1001FBBE4)
    uses = [(pc,text) for pc,text in first if re.search(r"\bx24\b",text)]
    assert uses == [(0x1001FB9FC,"mov\tx24, x0"),(0x1001FBA58,"mov\tx0, x24"),
                    (0x1001FBBD4,"ldp\tx24, x23, [sp, #0x20]")], uses
    second = disassemble(0x1001FC2E0,0x1001FC338)
    uses = [(pc,text) for pc,text in second if re.search(r"\bx26\b",text)]
    assert uses == [(0x1001FC2E8,"mov\tx26, x0"),(0x1001FC31C,"mov\tx0, x26"),
                    (0x1001FC334,"ldr\tx26, [x25, #0x58]")], uses
    # Audit exact message and ARC thunks, including their indirect import slots.
    expected = {
        0x107C12AE0:0x1469D590, 0x109688120:0xD001CD61, 0x109688124:0xF9423821,
        0x107C1290C:0x1469CD15, 0x109685D60:0x9001CD81, 0x109685D64:0xF945C021,
        0x1001FBA5C:0x95E85BAC, 0x1001FC328:0x95E85979,
        0x1001FB9F8:0x95E8FE56, 0x1001FC2E4:0x95E8FC1B,
        0x107C3B350:0x14663E88, 0x1095CAD74:0xF9432E10,
        0x1001FBA8C:0x95E8FE27, 0x107C3B328:0x14663E6B, 0x1095CACD8:0xF942FA10,
        0x1001FC32C:0x95E8FC01, 0x107C3B330:0x14663E6F, 0x1095CACF0:0xF9430210,
    }
    for address,word in expected.items():
        assert struct.unpack("<I",read(address,4))[0] == word, hex(address)
    indirect = subprocess.check_output(["xcrun","llvm-objdump","--macho","--indirect-symbols",str(path)],text=True)
    for address,name in ((0x10C0A25F0,"_objc_release_x24"),(0x10C0A2600,"_objc_release_x26"),
                         (0x10C0A2658,"_objc_retainAutoreleasedReturnValue"),(0x10C0A2560,"_objc_msgSend")):
        assert re.search(rf"0x{address:016x}\s+\d+\s+{name}\s",indirect), name
    print("PASS pristine LINE UUID; both factory results are nil-safe message receivers and ARC operands")
    print("Evidence: +1fb9f0 -> x24 -> setVocabularyStrings/release_x24; +1fc2dc -> x26 -> setVocabularyStrings/release_x26")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary",type=Path,help="also audit the pristine local LINE executable (read-only)")
    args = parser.parse_args()
    host_check()
    if args.binary:
        binary_check(args.binary)
