#import "../VersionMapping.h"

static const RUINInstructionAnchor kShopNavigation[] = {
    {0x100043398, 4, {0xa9bd57f6, 0xa9014ff4, 0xa9027bfd, 0x910083fd}}
};

static const RUINInstructionAnchor kShopEligibility[] = {
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

static const RUINInstructionAnchor kThemeValidation[] = {
    {0x1056453d0, 4, {0xaa1303e0, 0x94f800f3, 0xaa0003f4, 0x94f6ad09}}
};

static const RUINInstructionAnchor kThemeLocalPolicy[] = {
    {0x1057f9050, 4, {0xd2800015, 0x94efbee3, 0xb40000d5, 0xaa1503e0}},
    {0x1057fdd98, 4, {0xaa1303e0, 0x97ffec9c, 0xaa0003f4, 0xf9400afb}},
    {0x1057fd5cc, 4, {0xf90033f4, 0x97ffee8f, 0xaa0003f4, 0xf9400a79}}
};

static const RUINInstructionAnchor kReadBoundary[] = {
    {0x103e15638, 3, {0xaa1603e0, 0x95593b59, 0xaa0003f5}}
};

static const RUINInstructionAnchor kUnsendParser[] = {
    {0x1000bac24, 1, {0xf277053f}}, {0x1000bac30, 1, {0x951590af}},
    {0x1000bac44, 1, {0x94f5bb78}}, {0x103e29b2c, 1, {0x94000003}},
    {0x103e29b7c, 1, {0x9407fdd4}}, {0x103e29b80, 1, {0xb4000415}},
    {0x103e29c04, 1, {0xb4fffc20}}, {0x103e29dcc, 1, {0x9400057e}},
    {0x1040292fc, 1, {0x97fa9bd2}}, {0x103ed03a8, 1, {0x9554620e}},
    {0x103ed03c4, 1, {0xb4000160}}, {0x103ed03f4, 1, {0xd2800017}},
    {0x10461ef0c, 1, {0x9538eaa5}}, {0x10461f234, 1, {0xf10102bf}},
    {0x10461f23c, 1, {0xf10106bf}}
};

static const uintptr_t kUnsendLookupReturnAddresses[] = {
    0x103ed03ac, 0x104029300, 0x103e29b80, 0x103e29b30, 0x1000bac48
};

const RUINVersionMapping RUINLINE26160 = {
    .host = {"26.16.0", "2026.1006.1718", "292883E8-E011-3583-ADF5-F02241E3277B",
        "e1ad61171b021566f4a318c93ba1260747bfb220c81a79d5a80121311787d6ad", RUINMappingStatusVerified},
    .themes = {
        .shopNavigation = {RUINMappingStatusVerified, 0x100043398, 0x10a44eb50,
            kShopNavigation, sizeof(kShopNavigation) / sizeof(*kShopNavigation)},
        .shopEligibility = {
            .status = RUINMappingStatusVerified,
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
            .anchors = kShopEligibility,
            .anchorCount = sizeof(kShopEligibility) / sizeof(*kShopEligibility)
        },
        .validation = {RUINMappingStatusVerified, 0x1056453d8, 0x10257a434, 0x10a742270,
            kThemeValidation, sizeof(kThemeValidation) / sizeof(*kThemeValidation)},
        .localPolicy = {RUINMappingStatusVerified, 0x1057f9058, {0x1057fdda0, 0x1057fd5d4},
            0x10580019c, kThemeLocalPolicy, sizeof(kThemeLocalPolicy) / sizeof(*kThemeLocalPolicy)},
        .featureAddresses = {RUINMappingStatusVerified, 0xfd0c8, 0x105733ce8,
            0x128c18, 0xfd688, 0x10579271c}
    },
    .messaging = {
        .readBoundary = {RUINMappingStatusVerified, kReadBoundary,
            sizeof(kReadBoundary) / sizeof(*kReadBoundary), 0x103e15640},
        .unsendOperation = {RUINMappingStatusVerified, kUnsendParser,
            sizeof(kUnsendParser) / sizeof(*kUnsendParser), 0x10461ef10,
            RUINMappingStatusVerified, kUnsendLookupReturnAddresses,
            sizeof(kUnsendLookupReturnAddresses) / sizeof(*kUnsendLookupReturnAddresses)},
        .readUntilABIStatus = RUINMappingStatusUnsupported
    },
    .nativeTabs = {
        .status = RUINMappingStatusVerified,
        .bridgeVA = 0x100010f38,
        .witnessTableVA = 0x10bee1590,
        .caseTableVA = 0x107d5cf48,
        .firstWitnessVA = 0x109670bf0,
        .lastWitnessVA = 0x100725540,
        .bridgeWords = {0xaa1603e0, 0xaa1503e1, 0xd61f0100},
        .caseWords = {0x24, 0x10, 0x20, 0x18, 0x40},
        .slots = {0x28, 0x50, 0x70, 0x80, 0x98},
        .menuGenerator = {0x107d5cbdc, 4, {0xd10183ff, 0xa90167fa, 0xa9025ff8, 0xa90357f6}},
        .menuGeneratorEndVA = 0x107d5cf48,
        .getters = {0x10072529c, 0x100725304, 0x100725440, 0x1007254c8, 0x100725520},
        .refreshReads = {
            {0x30, 0x1007252a0, 0x1003d57a4, {0xf9401ae8, 0xaa0003f4, 0xaa1603e0, 0xaa1703e1, 0xd63f0100}},
            {0x40, 0x1007252c4, 0x1003d5844, {0xf94022e8, 0xaa0003f4, 0xaa1603e0, 0xaa1703e1, 0xd63f0100}},
            {0x48, 0x1007252e4, 0x1003d57e8, {0xf94026e8, 0xaa0003f4, 0xaa1603e0, 0xaa1703e1, 0xd63f0100}},
            {0x70, 0x100725440, 0x1003d59a8, {0xf9403ac8, 0xaa0003f4, 0xaa1303e0, 0xaa1603e1, 0xd63f0100}},
            {0x50, 0x100725304, 0x1003d5170, {0x8b080260, 0xa941d815, 0x97f20c47, 0xf9402ac8, 0x97f21c0c}}
        }
    }
};
