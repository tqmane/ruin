#import "../VersionMapping.h"

static const RUINInstructionAnchor kShopNavigation[] = {
    {0x100043524, 4, {0xa9bd57f6, 0xa9014ff4, 0xa9027bfd, 0x910083fd}}
};

static const RUINInstructionAnchor kThemeValidation[] = {
    {0x1057a5c94, 2, {0xf0028ca8, 0x912fc108}},
    {0x1057a5ce4, 2, {0xaa1303e0, 0x94f9e806}}
};

static const RUINInstructionAnchor kThemeLocalPolicy[] = {
    {0x105951164, 4, {0xd2800015, 0x94f1c7b8, 0xb40000d5, 0xaa1503e0}},
    {0x105955ea0, 4, {0xaa1303e0, 0x97ffec9f, 0xaa0003f4, 0xf9400afb}},
    {0x1059556d4, 4, {0xf90033f4, 0x97ffee92, 0xaa0003f4, 0xf9400a79}},
    {0x10595829c, 4, {0xaa1303e0, 0x97ffe3a0, 0xaa0003f4, 0xf9400ab3}}
};

static const RUINInstructionAnchor kUnsendParser[] = {
    {0x1000bb634, 3, {0x951acd7b, 0xb400d2c0, 0xaa0003f3}},
    {0x1000bb648, 1, {0x94f85864}},
    {0x103ed1824, 1, {0x9401f111}},
    {0x10476ec40, 1, {0x953b14d8}},
    {0x10476ec68, 1, {0x953b14d6}},
    {0x10476eea4, 1, {0x953b144f}},
    {0x10476ef5c, 1, {0x953ca309}},
    {0x10476ef68, 1, {0xf10102bf}},
    {0x10476ef70, 1, {0xf10106bf}},
    {0x103f7e610, 1, {0x9559128e}},
    {0x103f7e4cc, 1, {0x9400002f}},
    {0x1040da76c, 1, {0x97fa8f50}},
    {0x103ed1930, 2, {0x94082383, 0xb4000415}},
    {0x103ed19b8, 1, {0xb4fffc20}},
    {0x103ed18e0, 1, {0x94000003}},
    {0x103f7e628, 2, {0xd63f02c0, 0xb4000160}}
};
static const uintptr_t kUnsendLookup[] = {
    0x103f7e614, 0x103f7e4d0, 0x1040da770,
    0x103ed1934, 0x103ed18e4, 0x1000bb64c
};

const RUINVersionMapping RUINLINE26170 = {
    .host = {"26.17.0", "2026.1103.1841", "614CED59-07E5-372D-94B2-D4901870C7A0",
        "a3de1677f3140ed076554f642933209db2d41b838d2a28b98ab4a2bdcacf1bd8", RUINMappingStatusUnverified},
    .themes = {
        .shopNavigation = {RUINMappingStatusVerified, 0x100043524, 0x10a647430,
            kShopNavigation, sizeof(kShopNavigation) / sizeof(*kShopNavigation)},
        .shopEligibility = {.status = RUINMappingStatusUnsupported},
        .validation = {RUINMappingStatusVerified, 0x1057a5cec, 0x1025cc684, 0x10a93cbf0,
            kThemeValidation, sizeof(kThemeValidation) / sizeof(*kThemeValidation)},
        .localPolicy = {RUINMappingStatusVerified, 0x10595116c, {0x105955ea8, 0x1059556dc},
            0x1059582a4, kThemeLocalPolicy, sizeof(kThemeLocalPolicy) / sizeof(*kThemeLocalPolicy)},
        .featureAddresses = {.status = RUINMappingStatusUnsupported}
    },
    .messaging = {
        // This version's cursor comparison runs after server success.
        // Preserve native synchronization; suppress reads at their producer.
        .readBoundary = {.status = RUINMappingStatusUnsupported},
        .unsendOperation = {RUINMappingStatusVerified, kUnsendParser,
            sizeof(kUnsendParser) / sizeof(*kUnsendParser), 0x10476ec44,
            RUINMappingStatusVerified, kUnsendLookup, sizeof(kUnsendLookup) / sizeof(*kUnsendLookup)},
        .readUntilABIStatus = RUINMappingStatusVerified
    },
    .nativeTabs = {
        .status = RUINMappingStatusVerified,
        .bridgeVA = 0x100011130,
        .witnessTableVA = 0x10c123698,
        .caseTableVA = 0x107ee13c4,
        .firstWitnessVA = 0x10984f1b0,
        .lastWitnessVA = 0x1007365a4,
        .bridgeWords = {0xaa1603e0, 0xaa1503e1, 0xd61f0100},
        .caseWords = {0x24, 0x10, 0x20, 0x18, 0x40},
        .slots = {0x28, 0x50, 0x70, 0x80, 0x98},
        .menuGenerator = {0x107ee1058, 4, {0xd10183ff, 0xa90167fa, 0xa9025ff8, 0xa90357f6}},
        .menuGeneratorEndVA = 0x107ee13c4,
        .getters = {0x100736300, 0x100736368, 0x1007364a4, 0x10073652c, 0x100736584},
        .refreshReads = {
            {0x30, 0x100736304, 0x1003dea3c, {0xf9401ae8, 0xaa0003f4, 0xaa1603e0, 0xaa1703e1, 0xd63f0100}},
            {0x40, 0x100736328, 0x1003deadc, {0xf94022e8, 0xaa0003f4, 0xaa1603e0, 0xaa1703e1, 0xd63f0100}},
            {0x48, 0x100736348, 0x1003dea80, {0xf94026e8, 0xaa0003f4, 0xaa1603e0, 0xaa1703e1, 0xd63f0100}},
            {0x70, 0x1007364a4, 0x1003dec40, {0xf9403ac8, 0xaa0003f4, 0xaa1303e0, 0xaa1603e1, 0xd63f0100}},
            {0x50, 0x100736368, 0x1003de408, {0x8b080260, 0xa941d815, 0x97f1e7c9, 0xf9402ac8, 0x97f1f79a}}
        }
    }
};
