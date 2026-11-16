#import <Foundation/Foundation.h>
#import "../src/known/VersionMapping.h"
#include <stdio.h>
#include <stdlib.h>

static NSMutableArray *gMappings;

static NSString *Hex(uint64_t value)
{
    return [NSString stringWithFormat:@"0x%llx", (unsigned long long)value];
}

static NSString *Status(RUINMappingStatus status)
{
    switch (status) {
        case RUINMappingStatusUnsupported: return @"unsupported";
        case RUINMappingStatusUnverified: return @"unverified";
        case RUINMappingStatusVerified: return @"verified";
    }
    return @"invalid";
}

static id Address(RUINMappingStatus status, uintptr_t value)
{
    return status == RUINMappingStatusVerified && value ? Hex(value) : NSNull.null;
}

static NSArray *AddressArray(RUINMappingStatus status, const uintptr_t *values, size_t count)
{
    if (status != RUINMappingStatusVerified || !values || !count) return @[];
    NSMutableArray *result = [NSMutableArray arrayWithCapacity:count];
    for (size_t i = 0; i < count; i++) [result addObject:Hex(values[i])];
    return result;
}

static NSArray *ShopChainArray(RUINMappingStatus status, const uintptr_t *values, size_t count)
{
    if (status != RUINMappingStatusVerified || !values || !count) return @[];
    for (size_t i = 0; i < count; i++) if (!values[i]) return @[];
    return AddressArray(status, values, count);
}

static NSArray *ShopChainAlternativesArray(RUINMappingStatus status,
    const RUINThemeShopReturnChain *chains, size_t count)
{
    if (status != RUINMappingStatusVerified || !chains || !count) return @[];
    NSMutableArray *result = [NSMutableArray arrayWithCapacity:count];
    for (size_t i = 0; i < count; i++) {
        const RUINThemeShopReturnChain *chain = &chains[i];
        NSArray *returnPCs = ShopChainArray(status, chain->returnPCs, chain->returnPCCount);
        if (returnPCs.count != chain->returnPCCount) return @[];
        [result addObject:@{@"count": @(chain->returnPCCount), @"returnPCs": returnPCs}];
    }
    return result;
}

static NSArray *WordArray(const uint32_t *values, size_t count)
{
    NSMutableArray *result = [NSMutableArray arrayWithCapacity:count];
    for (size_t i = 0; i < count; i++) [result addObject:Hex(values[i])];
    return result;
}

static NSArray *AnchorArray(const RUINInstructionAnchor *anchors, size_t count)
{
    NSMutableArray *result = [NSMutableArray arrayWithCapacity:count];
    for (size_t i = 0; i < count; i++) {
        const RUINInstructionAnchor *anchor = &anchors[i];
        [result addObject:@{
            @"address": Hex(anchor->address),
            @"wordCount": @(anchor->wordCount),
            @"words": WordArray(anchor->words, anchor->wordCount)
        }];
    }
    return result;
}

static NSDictionary *ReadBoundaryJSON(const RUINReadBoundaryMapping *mapping)
{
    return @{
        @"status": Status(mapping->status),
        @"callerReturnAddress": Address(mapping->status, mapping->callerReturnAddress),
        @"anchors": AnchorArray(mapping->anchors, mapping->anchorCount)
    };
}

static NSDictionary *UnsendJSON(const RUINUnsendOperationMapping *mapping)
{
    return @{
        @"parserStatus": Status(mapping->parserStatus),
        @"parserParam1ReturnAddress": Address(mapping->parserStatus, mapping->parserParam1ReturnAddress),
        @"parserAnchors": AnchorArray(mapping->parserAnchors, mapping->parserAnchorCount),
        @"lookupStatus": Status(mapping->lookupStatus),
        @"orderedLookupReturnAddresses": AddressArray(mapping->lookupStatus,
            mapping->orderedLookupReturnAddresses, mapping->orderedLookupReturnAddressCount)
    };
}

static NSDictionary *MappingJSON(const RUINVersionMapping *mapping)
{
    const RUINThemeMappings *theme = &mapping->themes;
    const RUINThemeShopNavigationMapping *navigation = &theme->shopNavigation;
    const RUINThemeShopEligibilityMapping *eligibility = &theme->shopEligibility;
    const RUINThemeValidationMapping *validation = &theme->validation;
    const RUINThemeLocalPolicyMapping *localPolicy = &theme->localPolicy;
    const RUINThemeFeatureAddressesMapping *featureAddresses = &theme->featureAddresses;
    const RUINNativeTabMapping *tabs = &mapping->nativeTabs;
    NSMutableArray *refreshReads = [NSMutableArray arrayWithCapacity:5];
    for (size_t i = 0; i < sizeof(tabs->refreshReads) / sizeof(*tabs->refreshReads); i++) {
        const RUINNativeTabRefreshRead *read = &tabs->refreshReads[i];
        [refreshReads addObject:@{
            @"slot": Hex(read->slot),
            @"getterVA": Address(tabs->status, read->getterVA),
            @"returnVA": Address(tabs->status, read->returnVA),
            @"callWords": WordArray(read->callWords, 5)
        }];
    }
    return @{
        @"host": @{
            @"version": [NSString stringWithUTF8String:mapping->host.version],
            @"build": [NSString stringWithUTF8String:mapping->host.build],
            @"uuid": [NSString stringWithUTF8String:mapping->host.uuid],
            @"sourceSHA256": [NSString stringWithUTF8String:mapping->host.sourceSHA256],
            @"supportStatus": Status(mapping->host.supportStatus)
        },
        @"legacyHome": @{
            @"status": Status(mapping->legacyHome.status),
            @"factoryClassVA": Address(mapping->legacyHome.status, mapping->legacyHome.factoryClassVA),
            @"homeWitnessVA": Address(mapping->legacyHome.status, mapping->legacyHome.homeWitnessVA),
            @"homeConformanceVA": Address(mapping->legacyHome.status, mapping->legacyHome.homeConformanceVA),
            @"homeMetadataVA": Address(mapping->legacyHome.status, mapping->legacyHome.homeMetadataVA),
            @"homeDecoderVA": Address(mapping->legacyHome.status, mapping->legacyHome.homeDecoderVA),
            @"globalWitnessAccessorVA": Address(mapping->legacyHome.status, mapping->legacyHome.globalWitnessAccessorVA),
            @"globalConformanceVA": Address(mapping->legacyHome.status, mapping->legacyHome.globalConformanceVA),
            @"globalMetadataVA": Address(mapping->legacyHome.status, mapping->legacyHome.globalMetadataVA),
            @"globalDecoderVA": Address(mapping->legacyHome.status, mapping->legacyHome.globalDecoderVA),
            @"homeFlagStringVA": Address(mapping->legacyHome.status, mapping->legacyHome.homeFlagStringVA),
            @"globalHomeFlagStringVA": Address(mapping->legacyHome.status, mapping->legacyHome.globalHomeFlagStringVA),
            @"anchors": AnchorArray(mapping->legacyHome.anchors, mapping->legacyHome.anchorCount)
        },
        @"themes": @{
            @"shopNavigation": @{
                @"status": Status(navigation->status),
                @"methodIMP": Address(navigation->status, navigation->methodIMP),
                @"themeURLString": Address(navigation->status, navigation->themeURLString),
                @"anchors": AnchorArray(navigation->anchors, navigation->anchorCount)
            },
            @"shopEligibility": @{
                @"status": Status(eligibility->status),
                @"nativeReadAdapterStatus": Status(eligibility->nativeReadAdapterStatus),
                @"shopSchemeScopeStatus": Status(eligibility->shopSchemeScopeStatus),
                @"modeReturnPC": Address(eligibility->nativeReadAdapterStatus, eligibility->modeReturnPC),
                @"accountReturnPC": Address(eligibility->nativeReadAdapterStatus, eligibility->accountReturnPC),
                @"modeCopyReturnPC": Address(eligibility->nativeReadAdapterStatus, eligibility->modeCopyReturnPC),
                @"preflightAccountReturnPC": Address(eligibility->nativeReadAdapterStatus, eligibility->preflightAccountReturnPC),
                @"accountChain": ShopChainArray(eligibility->nativeReadAdapterStatus, eligibility->accountChain, 3),
                @"accountChainAlternatives": ShopChainAlternativesArray(eligibility->nativeReadAdapterStatus,
                    eligibility->accountChainAlternatives, eligibility->accountChainAlternativeCount),
                @"stylesheetEligibilityReturnPC": Address(eligibility->nativeReadAdapterStatus, eligibility->stylesheetEligibilityReturnPC),
                @"stylesheetSaveReturnPC": Address(eligibility->nativeReadAdapterStatus, eligibility->stylesheetSaveReturnPC),
                @"capabilityReturnPC": Address(eligibility->nativeReadAdapterStatus, eligibility->capabilityReturnPC),
                @"themeActionReturnPC": Address(eligibility->nativeReadAdapterStatus, eligibility->themeActionReturnPC),
                @"shopSchemeReturnPCs": AddressArray(eligibility->nativeReadAdapterStatus, eligibility->shopSchemeReturnPCs, 2),
                @"shopSchemeHandlerReturnPCs": AddressArray(eligibility->nativeReadAdapterStatus, eligibility->shopSchemeHandlerReturnPCs, 2),
                @"nvSchemeReturnPC": Address(eligibility->nativeReadAdapterStatus, eligibility->nvSchemeReturnPC),
                @"plainModeStackOffset": Address(eligibility->nativeReadAdapterStatus, eligibility->plainModeStackOffset),
                @"anchors": AnchorArray(eligibility->anchors, eligibility->anchorCount)
            },
            @"validation": @{
                @"status": Status(validation->status),
                @"resultReturnPC": Address(validation->status, validation->resultReturnPC),
                @"resultMethodIMP": Address(validation->status, validation->resultMethodIMP),
                @"resultLogString": Address(validation->status, validation->resultLogString),
                @"anchors": AnchorArray(validation->anchors, validation->anchorCount)
            },
            @"localPolicy": @{
                @"status": Status(localPolicy->status),
                @"repositoryReturnPC": Address(localPolicy->status, localPolicy->repositoryReturnPC),
                @"serverSyncReturnPCs": AddressArray(localPolicy->status, localPolicy->serverSyncReturnPCs, 2),
                @"readOnlyExcludedReturnPC": Address(localPolicy->status, localPolicy->readOnlyExcludedReturnPC),
                @"anchors": AnchorArray(localPolicy->anchors, localPolicy->anchorCount)
            },
            @"featureAddresses": @{
                @"status": Status(featureAddresses->status),
                @"priceTierReplacementVA": Address(featureAddresses->status, featureAddresses->priceTierReplacementVA),
                @"applyObserverMethodVA": Address(featureAddresses->status, featureAddresses->applyObserverMethodVA),
                @"defaultsFreezeReplacementVA": Address(featureAddresses->status, featureAddresses->defaultsFreezeReplacementVA),
                @"manualDownloadSourceReplacementVA": Address(featureAddresses->status, featureAddresses->manualDownloadSourceReplacementVA),
                @"resetMethodVA": Address(featureAddresses->status, featureAddresses->resetMethodVA)
            }
        },
        @"messaging": @{
            @"readBoundary": ReadBoundaryJSON(&mapping->messaging.readBoundary),
            @"unsendOperation": UnsendJSON(&mapping->messaging.unsendOperation),
            @"readUntilABIStatus": Status(mapping->messaging.readUntilABIStatus),
            @"nativeMuteSend": @{
                @"status": Status(mapping->messaging.nativeMuteSend.status),
                @"witnessTableVA": Address(mapping->messaging.nativeMuteSend.status, mapping->messaging.nativeMuteSend.witnessTableVA),
                @"conformanceVA": Address(mapping->messaging.nativeMuteSend.status, mapping->messaging.nativeMuteSend.conformanceVA),
                @"getterVA": Address(mapping->messaging.nativeMuteSend.status, mapping->messaging.nativeMuteSend.getterVA),
                @"policyReturnVA": Address(mapping->messaging.nativeMuteSend.status, mapping->messaging.nativeMuteSend.policyReturnVA),
                @"configurationWitnessTableVA": Address(mapping->messaging.nativeMuteSend.status, mapping->messaging.nativeMuteSend.configurationWitnessTableVA),
                @"configurationConformanceVA": Address(mapping->messaging.nativeMuteSend.status, mapping->messaging.nativeMuteSend.configurationConformanceVA),
                @"configurationValueTypeVA": Address(mapping->messaging.nativeMuteSend.status, mapping->messaging.nativeMuteSend.configurationValueTypeVA),
                @"configurationGetterVA": Address(mapping->messaging.nativeMuteSend.status, mapping->messaging.nativeMuteSend.configurationGetterVA),
                @"configurationReturnVA": Address(mapping->messaging.nativeMuteSend.status, mapping->messaging.nativeMuteSend.configurationReturnVA),
                @"anchors": AnchorArray(mapping->messaging.nativeMuteSend.anchors, mapping->messaging.nativeMuteSend.anchorCount)
            }
        },
        @"nativeTabs": @{
            @"status": Status(tabs->status),
            @"bridgeVA": Address(tabs->status, tabs->bridgeVA),
            @"witnessTableVA": Address(tabs->status, tabs->witnessTableVA),
            @"caseTableVA": Address(tabs->status, tabs->caseTableVA),
            @"firstWitnessVA": Address(tabs->status, tabs->firstWitnessVA),
            @"lastWitnessVA": Address(tabs->status, tabs->lastWitnessVA),
            @"bridgeWords": WordArray(tabs->bridgeWords, 3),
            @"caseWords": @[@(tabs->caseWords[0]), @(tabs->caseWords[1]), @(tabs->caseWords[2]), @(tabs->caseWords[3]), @(tabs->caseWords[4])],
            @"slots": @[@(tabs->slots[0]), @(tabs->slots[1]), @(tabs->slots[2]), @(tabs->slots[3]), @(tabs->slots[4])],
            @"menuGenerator": @{
                @"address": Address(tabs->status, tabs->menuGenerator.address),
                @"wordCount": @(tabs->menuGenerator.wordCount),
                @"words": WordArray(tabs->menuGenerator.words, tabs->menuGenerator.wordCount)
            },
            @"menuGeneratorEndVA": Address(tabs->status, tabs->menuGeneratorEndVA),
            @"getters": AddressArray(tabs->status, tabs->getters, 5),
            @"refreshReads": refreshReads
        }
    };
}

static void AppendMapping(const RUINVersionMapping *mapping, void *context)
{
    (void)context;
    [gMappings addObject:MappingJSON(mapping)];
}

static NSData *ManifestData(NSError **error)
{
    gMappings = [NSMutableArray array];
    RUINEnumerateVersionMappings(AppendMapping, NULL);
    NSDictionary *manifest = @{@"formatVersion":@1, @"mappings":[gMappings copy]};
    return [NSJSONSerialization dataWithJSONObject:manifest
        options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:error];
}

static int WriteManifest(NSString *path)
{
    NSError *error = nil;
    NSData *data = ManifestData(&error);
    if (!data || ![data writeToFile:path options:NSDataWritingAtomic error:&error]) {
        fprintf(stderr, "mapping manifest write failed: %s\n", error.localizedDescription.UTF8String ?: "unknown error");
        return 1;
    }
    return 0;
}

static int CheckManifest(NSString *path)
{
    NSError *error = nil;
    NSData *expected = ManifestData(&error);
    NSData *actual = [NSData dataWithContentsOfFile:path options:0 error:&error];
    id expectedObject = expected ? [NSJSONSerialization JSONObjectWithData:expected options:0 error:&error] : nil;
    id actualObject = actual ? [NSJSONSerialization JSONObjectWithData:actual options:0 error:&error] : nil;
    if (!expectedObject || !actualObject || ![expectedObject isEqual:actualObject]) {
        fprintf(stderr, "compiled mappings differ from the checked manifest; regenerate it with --write\n");
        return 1;
    }
    puts("PASS compiled mapping manifest matches");
    return 0;
}

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        if (argc == 3 && !strcmp(argv[1], "--write"))
            return WriteManifest([NSString stringWithUTF8String:argv[2]]);
        if (argc == 3 && !strcmp(argv[1], "--check"))
            return CheckManifest([NSString stringWithUTF8String:argv[2]]);
        if (argc != 1) {
            fputs("usage: export_version_mappings [--write path | --check path]\n", stderr);
            return 2;
        }
        NSError *error = nil;
        NSData *data = ManifestData(&error);
        if (!data || fwrite(data.bytes, 1, data.length, stdout) != data.length) return 1;
        fputc('\n', stdout);
        return 0;
    }
}
