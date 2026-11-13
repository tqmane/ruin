#!/usr/bin/env python3
"""Run generated font hooks against real image proof with host UIKit/loader seams."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "src/interface/LocalFontUI.x").read_text()

SHIM = r'''
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import "FeatureImage.h"
#import "VersionMapping.h"
#include <assert.h>
#include <fcntl.h>
#include <unistd.h>

typedef CGFloat UIFontWeight;
typedef NSString *UIFontTextStyle;
@interface UITraitCollection : NSObject @end
@implementation UITraitCollection @end
@interface UIFontDescriptor : NSObject @end
@implementation UIFontDescriptor @end
@interface UIFont : NSObject
@property CGFloat pointSize;
@property(copy) NSString *fontName;
@property(copy) NSString *familyName;
+ (UIFont *)systemFontOfSize:(CGFloat)size;
+ (UIFont *)systemFontOfSize:(CGFloat)size weight:(UIFontWeight)weight;
+ (UIFont *)boldSystemFontOfSize:(CGFloat)size;
+ (UIFont *)italicSystemFontOfSize:(CGFloat)size;
+ (UIFont *)preferredFontForTextStyle:(UIFontTextStyle)style;
+ (UIFont *)preferredFontForTextStyle:(UIFontTextStyle)style compatibleWithTraitCollection:(UITraitCollection *)traits;
+ (UIFont *)fontWithName:(NSString *)name size:(CGFloat)size;
+ (UIFont *)fontWithDescriptor:(UIFontDescriptor *)descriptor size:(CGFloat)size;
@end
static UIFont *original, *replacement;
static unsigned originals, replacements, resolves, lookups, nativeResolves;
static CGFloat lastSize, lastWeight;
static id lastArgument, lastTraits;
@implementation UIFont
+ (UIFont *)systemFontOfSize:(CGFloat)size { originals++; lastSize=size; return original; }
+ (UIFont *)systemFontOfSize:(CGFloat)size weight:(UIFontWeight)weight {
    originals++; lastSize=size; lastWeight=weight; return original;
}
+ (UIFont *)boldSystemFontOfSize:(CGFloat)size { originals++; lastSize=size; return original; }
+ (UIFont *)italicSystemFontOfSize:(CGFloat)size { originals++; lastSize=size; return original; }
+ (UIFont *)preferredFontForTextStyle:(UIFontTextStyle)style {
    originals++; lastArgument=style; return original;
}
+ (UIFont *)preferredFontForTextStyle:(UIFontTextStyle)style compatibleWithTraitCollection:(UITraitCollection *)traits {
    originals++; lastArgument=style; lastTraits=traits; return original;
}
+ (UIFont *)fontWithName:(NSString *)name size:(CGFloat)size {
    originals++; lastArgument=name; lastSize=size; return original;
}
+ (UIFont *)fontWithDescriptor:(UIFontDescriptor *)descriptor size:(CGFloat)size {
    originals++; lastArgument=descriptor; lastSize=size; return original;
}
@end
@interface _TtC4LINE11AppDelegate : NSObject @end
@implementation _TtC4LINE11AppDelegate @end

typedef struct {
    struct mach_header_64 header;
    struct uuid_command uuid;
    struct { struct dylib_command command; char name[8]; } identifier;
    struct segment_command_64 text;
} TestImage;
static TestImage guest, foreign;
static char linePath[1024], processPath[1024], aliasPath[1024];
static const char *ownerPath;
static NSDictionary *info;
static const void *callerHeader;
static BOOL active, pinAllowed, processLifetime, throws, missingReplacement, nativeAvailable, missingOwner;
static BOOL RUINLocalFontIsRegistered(void) { return active; }
static UIFont *RUINLocalFontAtSize(CGFloat size) {
    replacements++;
    assert(size == original.pointSize);
    CGFloat outerSize=lastSize;
    assert([UIFont systemFontOfSize:9] == original); // Reentrant factory must forward once.
    lastSize=outerSize;
    if (throws) @throw [NSException exceptionWithName:@"Expected" reason:nil userInfo:nil];
    return missingReplacement ? nil : replacement;
}
static const RUINVersionMapping *FixtureMapping(NSDictionary *unused) {
    (void)unused; return RUINMappingForInfo(info);
}
static BOOL FixtureMain(RUINMainExecutableImage *image) {
    nativeResolves++;
    if (!nativeAvailable) return NO;
    *image = (RUINMainExecutableImage){.header=&guest.header};
    memcpy(image->uuid, guest.uuid.uuid, 16);
    return YES;
}
static BOOL FixtureResolve(const RUINHostIdentity *host, Class owner, RUINFeatureImage *image) {
    resolves++;
    assert(owner == _TtC4LINE11AppDelegate.class);
    RUINDyldImageCandidate candidates[] = {{&guest.header,0,linePath}, {&guest.header,0,aliasPath}};
    if (missingOwner || !RUINResolveFeatureImageFromCandidates(host,linePath,processPath,ownerPath,
        &guest.header,candidates,2,image)) return NO;
    if (processLifetime) { assert(!image->convertedExecutable); return YES; }
    // Runtime resolver supplies the NOLOAD lifetime proof; model both its outcomes.
    if (!pinAllowed) { memset(image,0,sizeof(*image)); return NO; }
    image->loaderReference = dlopen(NULL,RTLD_LAZY);
    assert(image->loaderReference);
    return YES;
}
static int FixtureDladdr(const void *caller, Dl_info *image) {
    (void)caller; lookups++; memset(image,0,sizeof(*image));
    image->dli_fbase = (void *)callerHeader; return callerHeader != NULL;
}
#define RUINMappingForInfo FixtureMapping
#define RUINResolveMainExecutableImage FixtureMain
#define RUINResolveFeatureImage FixtureResolve
#define dladdr FixtureDladdr
'''

CHECK = r'''
#undef RUINMappingForInfo
#undef RUINResolveMainExecutableImage
#undef RUINResolveFeatureImage
#undef dladdr
static void MakeImage(TestImage *image, const RUINHostIdentity *host) {
    memset(image,0,sizeof(*image));
    image->header = (struct mach_header_64){.magic=MH_MAGIC_64,.cputype=CPU_TYPE_ARM64,
        .cpusubtype=CPU_SUBTYPE_ARM64_ALL,.filetype=MH_DYLIB,.ncmds=3,
        .sizeofcmds=sizeof(*image)-sizeof(image->header),.flags=MH_NO_REEXPORTED_DYLIBS};
    image->uuid = (struct uuid_command){.cmd=LC_UUID,.cmdsize=sizeof(image->uuid)};
    [[[NSUUID alloc] initWithUUIDString:@(host->uuid)] getUUIDBytes:image->uuid.uuid];
    image->identifier.command = (struct dylib_command){.cmd=LC_ID_DYLIB,
        .cmdsize=sizeof(image->identifier),.dylib.name.offset=sizeof(struct dylib_command)};
    strcpy(image->identifier.name,"LINE");
    image->text = (struct segment_command_64){.cmd=LC_SEGMENT_64,.cmdsize=sizeof(image->text),
        .vmaddr=(uintptr_t)image,.vmsize=sizeof(*image),.initprot=VM_PROT_READ};
    strcpy(image->text.segname,"__TEXT");
}
static void ResetProof(void) {
    // Test-only process reset. Production never drops a published loader reference.
    atomic_store(&sFontCallerHeader,NULL); RUINReleaseFeatureImage(&sFontImage);
}
static void Rejected(void) {
    unsigned before=resolves;
    RUINInstallLocalFontHooks(); RUINInstallLocalFontHooks();
    assert(resolves == before+2); // Failure is retried only on explicit refresh.
    assert(!atomic_load(&sFontCallerHeader));
    unsigned proofCount=resolves;
    before=lookups;
    for (int i=0;i<10;i++) assert([UIFont systemFontOfSize:12] == original);
    assert(lookups == before && resolves == proofCount); // No lookup or reproof without explicit refresh.
}
static void ForwardFactories(UIFont *expected) {
    unsigned before=originals;
    assert([UIFont systemFontOfSize:11] == expected && lastSize == 11);
    assert([UIFont systemFontOfSize:12 weight:0.5] == expected && lastSize == 12 && lastWeight == 0.5);
    assert([UIFont boldSystemFontOfSize:13] == expected && lastSize == 13);
    assert([UIFont italicSystemFontOfSize:14] == expected && lastSize == 14);
    NSString *style=@"body";
    UITraitCollection *traits=[UITraitCollection new];
    assert([UIFont preferredFontForTextStyle:style] == expected && lastArgument == style);
    assert([UIFont preferredFontForTextStyle:style compatibleWithTraitCollection:traits] == expected &&
        lastArgument == style && lastTraits == traits);
    assert([UIFont fontWithName:@".SFUI-Regular" size:15] == expected && lastSize == 15 &&
        [lastArgument isEqual:@".SFUI-Regular"]);
    UIFontDescriptor *descriptor=[UIFontDescriptor new];
    assert([UIFont fontWithDescriptor:descriptor size:16] == expected && lastSize == 16 && lastArgument == descriptor);
    assert(originals == before + (expected == replacement ? 16 : 8)); // One original per outer/nested call.
}
int main(void) { @autoreleasepool {
    char directory[]="/tmp/ruin-font-scope.XXXXXX"; assert(mkdtemp(directory));
    snprintf(linePath,sizeof(linePath),"%s/LINE",directory);
    snprintf(processPath,sizeof(processPath),"%s/Container",directory);
    snprintf(aliasPath,sizeof(aliasPath),"%s/current",directory);
    int fd=open(linePath,O_CREAT|O_WRONLY,0600); assert(fd>=0); close(fd);
    fd=open(processPath,O_CREAT|O_WRONLY,0600); assert(fd>=0); close(fd);
    assert(!symlink(linePath,aliasPath)); ownerPath=aliasPath;
    info=@{@"CFBundleIdentifier":@"renamed.line",@"RUINOriginalBundleIdentifier":@"jp.naver.line",
        @"CFBundleShortVersionString":@"26.17.0",@"CFBundleVersion":@"2026.1103.1841"};
    const RUINVersionMapping *version=RUINMappingForInfo(info); assert(version);
    MakeImage(&guest,&version->host); MakeImage(&foreign,&version->host);
    original=[UIFont new]; original.pointSize=17; original.fontName=@".SFUI-Regular";
    original.familyName=@".AppleSystemUIFont"; replacement=[UIFont new];
    callerHeader=&guest.header;
    missingOwner=YES; Rejected(); missingOwner=NO;
    active=YES;
    ownerPath=processPath; Rejected(); ownerPath=aliasPath;
    guest.uuid.uuid[0]++; Rejected(); guest.uuid.uuid[0]--;
    guest.header.cpusubtype=CPU_SUBTYPE_ARM64E; Rejected(); guest.header.cpusubtype=CPU_SUBTYPE_ARM64_ALL;
    guest.header.flags|=MH_PIE; Rejected(); guest.header.flags&=~MH_PIE;
    Rejected(); // Correct identity without the loader reference is still insufficient.
    pinAllowed=YES; RUINInstallLocalFontHooks();
    assert(atomic_load(&sFontCallerHeader) == &guest.header && sFontImage.loaderReference);
    unsigned proofCount=resolves, nativeCount=nativeResolves;
    void *pin=sFontImage.loaderReference;
    for (int i=0;i<10;i++) RUINInstallLocalFontHooks();
    assert(resolves == proofCount && nativeResolves == nativeCount && sFontImage.loaderReference == pin);
    active=NO; unsigned before=lookups; ForwardFactories(original); assert(lookups == before);
    active=YES; callerHeader=&foreign.header; ForwardFactories(original);
    callerHeader=NULL; ForwardFactories(original);
    callerHeader=&guest.header; ForwardFactories(replacement);
    UIFont *savedOriginal=original; original=nil;
    before=lookups; assert([UIFont systemFontOfSize:12] == nil && lookups == before);
    original=savedOriginal;
    original.fontName=@"LINEIcon"; original.familyName=@"LINEIcon";
    before=replacements;
    assert([UIFont fontWithName:@"LINEIcon" size:12] == original);
    assert([UIFont fontWithDescriptor:[UIFontDescriptor new] size:12] == original);
    assert(replacements == before);
    original.fontName=@".SFUI-Regular";
    missingReplacement=YES; assert([UIFont systemFontOfSize:12] == original); missingReplacement=NO;
    throws=YES; BOOL caught=NO;
    @try { (void)[UIFont systemFontOfSize:12]; } @catch (NSException *exception) { (void)exception; caught=YES; }
    assert(caught && !sReplacingFont); throws=NO;
    assert([UIFont systemFontOfSize:12] == replacement);
    active=NO; before=lookups; assert([UIFont systemFontOfSize:12] == original && lookups == before);
    assert(resolves == proofCount && nativeResolves == nativeCount);
    NSString *diagnostics=RUINLocalFontHookDiagnostics().description;
    assert([diagnostics rangeOfString:@(directory)].location == NSNotFound);
    assert([RUINLocalFontHookDiagnostics()[@"callerImageLoaderPinned"] boolValue]);
    ResetProof(); guest.header.filetype=MH_EXECUTE; active=YES;
    RUINInstallLocalFontHooks(); assert([UIFont systemFontOfSize:12] == replacement); // LC type rewrite.
    ResetProof(); strcpy(processPath,linePath); guest.header.flags=MH_PIE; processLifetime=YES;
    RUINInstallLocalFontHooks(); assert([UIFont systemFontOfSize:12] == replacement); // Native/sideload.
    assert(!sFontImage.loaderReference && [RUINLocalFontHookDiagnostics()[@"callerImageProven"] boolValue]);
    ResetProof(); nativeAvailable=YES;
    info=@{@"CFBundleIdentifier":@"jp.naver.line",@"CFBundleShortVersionString":@"future",@"CFBundleVersion":@"future"};
    RUINInstallLocalFontHooks(); assert([UIFont systemFontOfSize:12] == replacement); // Unknown native UI remains supported.
    ResetProof(); guest.header.flags=MH_NO_REEXPORTED_DYLIBS; processLifetime=NO;
    RUINInstallLocalFontHooks(); assert(!atomic_load(&sFontCallerHeader)); // Unknown converted guest rejected.
    ResetProof(); unlink(aliasPath); unlink(linePath);
    snprintf(processPath,sizeof(processPath),"%s/Container",directory); unlink(processPath); rmdir(directory);
    puts("PASS local font: real owner/path/UUID/ARM64/LC proof, retry/pin/cache, all factories, forwarding/reentry/OFF/icons");
} return 0; }
'''


def main() -> None:
    assert "if (imported) RUINInstallLocalFontHooks();" in SOURCE
    tweak = (ROOT / "src/core/Tweak.x").read_text()
    activation = tweak.split("static void RUINApplicationDidBecomeActive(void) {", 1)[1].split(
        "__attribute__((constructor))", 1
    )[0]
    assert "RUINInstallLocalFontHooks();" in activation
    # Extract the complete production scope/hook/install/diagnostic section; only UIKit UI is omitted.
    production = "%config(generator=internal);\n" + SOURCE[SOURCE.index("#import <dlfcn.h>"):]
    with tempfile.TemporaryDirectory(prefix="ruin-font-host-") as temporary:
        directory = Path(temporary)
        logos = directory / "font.x"
        logos.write_text(SHIM + production + CHECK)
        generated = directory / "font.m"
        result = subprocess.run(["perl", str(ROOT / "vendor/logos/bin/logos.pl"), str(logos)],
                                check=True, capture_output=True, text=True)
        generated.write_text(result.stdout)
        executable = directory / "check"
        sources = [ROOT / "src/known" / name for name in
                   ("FeatureImage.m", "BinaryVerifier.m", "KnownMappings.m")]
        sources += sorted((ROOT / "src/known/versions").glob("*.m"))
        subprocess.run(["xcrun", "--sdk", "macosx", "clang", "-fobjc-arc", "-fblocks",
                        "-Wall", "-Wextra", "-Werror", "-I", str(ROOT / "src/known"),
                        str(generated), *map(str, sources), "-framework", "Foundation", "-o", str(executable)],
                       check=True)
        subprocess.run([str(executable)], check=True)


if __name__ == "__main__":
    main()
