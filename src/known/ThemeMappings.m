#import "ThemeMappings.h"
#import "KnownMappings.h"

static const RUINInstructionAnchor kShopNavigation2616[] = {
    {0x100043398, 4, {0xa9bd57f6, 0xa9014ff4, 0xa9027bfd, 0x910083fd}}
};

static const RUINInstructionAnchor kShopNavigation2617[] = {
    {0x100043524, 4, {0xa9bd57f6, 0xa9014ff4, 0xa9027bfd, 0x910083fd}}
};

static const RUINInstructionAnchor kShopEligibility2616[] = {
    {0x105df505c, 2, {0xd0fd21e3, 0x91287063}},
    {0x100233a28, 4, {0xd2800000, 0x9498ab76, 0xaa0003f4, 0x9498aa7c}},
    {0x105df1824, 4, {0xd003aa68, 0xf940a508, 0x8b080288, 0xa9405109}},
    {0x105df1834, 4, {0xd63f0120, 0x360002c0, 0xaa1803e0, 0xaa1703e1}},
    {0x105df1844, 3, {0xaa1903f4, 0x94000018, 0x36000220}},
    {0x106946774, 3, {0xaa1403e2, 0x94abda32, 0xaa0003f3}},
    {0x10692e634, 2, {0x94006042, 0xb814c3a0}},
    {0x10692e63c, 3, {0x72001c1f, 0xf81403b4, 0x540000c0}},
    {0x10692e7d4, 3, {0xaa1503e2, 0x94ac9ee2, 0xaa1d03fd}},
    {0x10692e924, 2, {0xb854c3a8, 0x12001d14}},
    {0x10692e94c, 3, {0x340000b4, 0xaa1603e0, 0xaa1803e1}},
    {0x10285e89c, 1, {0x95033ee1}},
    {0x10285e1bc, 1, {0x940001aa}},
    {0x10285e43c, 3, {0x940000ff, 0x7100001f, 0x1a9f17e0}},
    {0x100753654, 2, {0x94842b74, 0x12000000}},
    {0x1003e06c0, 3, {0x52800020, 0x940dcbd2, 0xf94006c1}},
    {0x1003a33a4, 4, {0xd2800000, 0x940ec099, 0x360000a0, 0x52800020}},
    {0x1003a33b4, 2, {0x940ec096, 0x12000000}},
    {0x1003a3df4, 4, {0xa9405296, 0x97f1a542, 0xd63f02c0, 0xaa0003f6}},
    {0x1003a3f7c, 4, {0xa9405295, 0x97f1a4e0, 0xd63f02a0, 0xaa0003f5}},
    {0x10285f9c0, 3, {0xf9400008, 0xf90007e8, 0x94000045}},
    {0x10285f9e0, 1, {0x9503490a}},
    {0x106931ee4, 1, {0x94aad524}}
};

static const RUINInstructionAnchor kThemeValidation2616[] = {
    {0x1056453d0, 4, {0xaa1303e0, 0x94f800f3, 0xaa0003f4, 0x94f6ad09}}
};

static const RUINInstructionAnchor kThemeValidation2617[] = {
    {0x1057a5c94, 2, {0xf0028ca8, 0x912fc108}},
    {0x1057a5ce4, 2, {0xaa1303e0, 0x94f9e806}}
};

static const RUINInstructionAnchor kThemeLocalPolicy2616[] = {
    {0x1057f9050, 4, {0xd2800015, 0x94efbee3, 0xb40000d5, 0xaa1503e0}},
    {0x1057fdd98, 4, {0xaa1303e0, 0x97ffec9c, 0xaa0003f4, 0xf9400afb}},
    {0x1057fd5cc, 4, {0xf90033f4, 0x97ffee8f, 0xaa0003f4, 0xf9400a79}}
};

static const RUINInstructionAnchor kThemeLocalPolicy2617[] = {
    {0x105951164, 4, {0xd2800015, 0x94f1c7b8, 0xb40000d5, 0xaa1503e0}},
    {0x105955ea0, 4, {0xaa1303e0, 0x97ffec9f, 0xaa0003f4, 0xf9400afb}},
    {0x1059556d4, 4, {0xf90033f4, 0x97ffee92, 0xaa0003f4, 0xf9400a79}},
    {0x10595829c, 4, {0xaa1303e0, 0x97ffe3a0, 0xaa0003f4, 0xf9400ab3}}
};

static const RUINThemeMappings kMappings[] = {
    {
        .host = &RUINKnownHosts[0],
        .shopNavigation = {YES, 0x100043398, 0x10a44eb50,
            kShopNavigation2616, sizeof(kShopNavigation2616) / sizeof(*kShopNavigation2616)},
        .shopEligibility = {
            .verified = YES,
            .modeReturnPC = 0x10694677c,
            .accountReturnPC = 0x10692e7dc,
            .modeCopyReturnPC = 0x10692e638,
            .preflightAccountReturnPC = 0x10285e208,
            .accountChain = {0x10285e8a0, 0x10285e1c0, 0x10285e440},
            .stylesheetEligibilityReturnPC = 0x100233a38,
            .stylesheetSaveReturnPC = 0x105df1838,
            .capabilityReturnPC = 0x100753658,
            .themeActionReturnPC = 0x1003e06c8,
            .shopSchemeReturnPCs = {0x1003a33ac, 0x1003a33b8},
            .shopSchemeHandlerReturnPCs = {0x1003a3f88, 0x1003a3e00},
            .plainModeStackOffset = 0xb4,
            .anchors = kShopEligibility2616,
            .anchorCount = sizeof(kShopEligibility2616) / sizeof(*kShopEligibility2616)
        },
        .validation = {YES, 0x1056453d8, 0x10257a434, 0x10a742270,
            kThemeValidation2616, sizeof(kThemeValidation2616) / sizeof(*kThemeValidation2616)},
        .localPolicy = {YES, 0x1057f9058, {0x1057fdda0, 0x1057fd5d4}, 0x10580019c,
            kThemeLocalPolicy2616, sizeof(kThemeLocalPolicy2616) / sizeof(*kThemeLocalPolicy2616)}
    },
    {
        .host = &RUINKnownHosts[1],
        .shopNavigation = {YES, 0x100043524, 0x10a647430,
            kShopNavigation2617, sizeof(kShopNavigation2617) / sizeof(*kShopNavigation2617)},
        // Eligibility remains unported; the independent revocation closure pair is mapped.
        .shopEligibility = {.verified = NO},
        .validation = {YES, 0x1057a5cec, 0x1025cc684, 0x10a93cbf0,
            kThemeValidation2617, sizeof(kThemeValidation2617) / sizeof(*kThemeValidation2617)},
        .localPolicy = {YES, 0x10595116c, {0x105955ea8, 0x1059556dc}, 0x1059582a4,
            kThemeLocalPolicy2617, sizeof(kThemeLocalPolicy2617) / sizeof(*kThemeLocalPolicy2617)}
    }
};

const RUINThemeMappings *RUINThemeMappingsForHost(const RUINHostIdentity *host)
{
    if (!host) return NULL;
    for (size_t i = 0; i < sizeof(kMappings) / sizeof(*kMappings); i++) {
        const RUINThemeMappings *mapping = &kMappings[i];
        if (mapping->host == host) return mapping;
    }
    return NULL;
}

BOOL RUINThemeLocalPolicyCallersMatch(const RUINThemeLocalPolicyMapping *mapping,
    const uintptr_t *PCs, size_t count)
{
    return mapping && mapping->verified && PCs && count >= 2 &&
        PCs[0] == mapping->repositoryReturnPC &&
        (PCs[1] == mapping->serverSyncReturnPCs[0] || PCs[1] == mapping->serverSyncReturnPCs[1]);
}
