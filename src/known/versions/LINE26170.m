#import "../VersionMapping.h"

// Post-decode caller-owned Bool results, plus their native dispatch and Home
// constructor decisions. Raw config/cache, account role and regions stay native.
static const RUINInstructionAnchor kLegacyHome[] = {
    {0x1002097d8, 4, {0xd0069527, 0x912d40e7, 0xf0060fc6, 0x9112e0c6}},
    {0x10020ac24, 2, {0x910080e5, 0x17fffe9c}},
    {0x10020a6e0, 4, {0xf9400309, 0x91007fe8, 0x94000177, 0xb40001f5}},
    {0x10020acc4, 4, {0xaa1a03e0, 0xaa1903e1, 0xaa1403e2, 0xaa1703e3}},
    {0x10020acd4, 1, {0xd61f0120}},
    {0x102cb3f44, 4, {0xa9bf7bfd, 0x910003fd, 0x976ed862, 0xa8c17bfd}},
    {0x1034478dc, 4, {0xf81e0ff3, 0xa9017bfd, 0x910043fd, 0xaa0803f3}},
    {0x1034478ec, 4, {0x97ffffb6, 0xb5000215, 0x12000008, 0x39000268}},
    {0x10344792c, 4, {0xbc001260, 0xa9417bfd, 0xf84207f3, 0xd65f03c0}},
    {0x103448a7c, 4, {0xb0050188, 0xf9422100, 0xb4000040, 0xd65f03c0}},
    {0x103448a94, 4, {0x90034260, 0x9102c000, 0xd0047aa1, 0x9127c021}},
    {0x103448aa8, 4, {0xb0050188, 0x91110108, 0xc89ffd00, 0xa8c17bfd}},
    {0x1001dd088, 4, {0x94c8fc5d, 0x37000080, 0xa9465268, 0xd63f0100}},
    {0x1001dd0bc, 4, {0xf9402a61, 0x9100e260, 0x97f8c03d, 0xf9400014}},
    {0x1001dd3dc, 4, {0x97ffff01, 0x72001c08, 0x54000120, 0x7100051f}},
    {0x1001dd3f0, 4, {0xf94016a1, 0x910042a0, 0x97f8bf70, 0xf9400014}},
    {0x1001dd408, 4, {0xf94016a1, 0x910042a0, 0x97f8bf6a, 0xf9400014}}
};

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

static const uintptr_t kShopEligibilityAccountChainA[] = {
    0x1028b6154, 0x1028b5abc, 0x1028b5a68, 0x1028b5cf4
};
static const uintptr_t kShopEligibilityAccountChainB[] = {
    0x1028b6154, 0x1028b5a74, 0x1028b5cf4
};
static const RUINThemeShopReturnChain kShopEligibilityAccountChains[] = {
    {kShopEligibilityAccountChainA, sizeof(kShopEligibilityAccountChainA) / sizeof(*kShopEligibilityAccountChainA)},
    {kShopEligibilityAccountChainB, sizeof(kShopEligibilityAccountChainB) / sizeof(*kShopEligibilityAccountChainB)}
};
static const RUINInstructionAnchor kShopEligibility[] = {
    {0x106af1c58, 2, {0xaa1403e2, 0x94ac9651}},
    {0x106ad9b2c, 4, {0x9400603d, 0xb814c3a0, 0x72001c1f, 0xf81403b4}},
    {0x106ad9b3c, 1, {0x540000c0}},
    {0x106ad9b54, 4, {0xaa1a03f6, 0xaa1c03e0, 0x52800021, 0x52800022}},
    {0x106ad9b64, 2, {0xaa1703e3, 0x9654bbb3}},
    {0x106ad9cc8, 4, {0xaa1403e0, 0xaa1503e2, 0x94ad5b24, 0xaa1d03fd}},
    {0x109630960, 4, {0x9001cf81, 0xf9434021, 0xd0015390, 0xf942b210}},
    {0x109630970, 1, {0xd61f0200}},
    {0x1028b6150, 2, {0x95088df2, 0x910123e0}},
    {0x1028b5ab8, 2, {0x94000198, 0x12001c28}},
    {0x1028b5a64, 2, {0x9400000a, 0x975db3df}},
    {0x1028b5cf0, 2, {0x940000ff, 0x7100001f}},
    {0x1028b5a70, 2, {0x940001aa, 0x12001c28}},
    {0x1007642a0, 3, {0x9485468e, 0x12000000, 0xa9447bfd}},
    {0x1002387dc, 2, {0x9499f53f, 0x12000000}},
    {0x105f7d7c4, 4, {0xb003b1c8, 0xf9407508, 0x8b080288, 0xa9405109}},
    {0x105f7d7d4, 2, {0xd63f0120, 0x360002c0}},
    {0x1003ac4a8, 2, {0x940edf6c, 0x360000a0}},
    {0x1003ac4b4, 2, {0x940edf69, 0x12000000}},
    {0x1003acd94, 2, {0xd63f02c0, 0xaa0003f6}},
    {0x1003acf1c, 2, {0xd63f02a0, 0xaa0003f5}},
    {0x1003e9a84, 4, {0x52800020, 0x940de9f4, 0xf94006c1, 0x12000000}}
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

// LineMessaging.MessagingGeneralSettingsService : LineMessagingV2.GeneralSettingsService.
// Its only requirement is a scalar Bool getter. The menu policy supplies
// metadata in x0, conformance in x1 and borrowed self in x20 before BLR x8.
static const RUINInstructionAnchor kNativeMuteSend[] = {
    {0x10403172c, 2, {0x150903b6, 0x17ffffff}},
    {0x108272604, 4, {0xa9be4ff4, 0xa9017bfd, 0x910043fd, 0x94000910}},
    {0x108272614, 4, {0x54000040, 0x97ffccbc, 0x94000903, 0x975e79f8}},
    {0x108272624, 4, {0x975b2126, 0xd0013d68, 0x91018108, 0x94000921}},
    {0x108272634, 4, {0xd2800241, 0x94000923, 0x97e702d5, 0x12000260}},
    {0x108272644, 2, {0xa9417bfd, 0x17e688dd}},
    {0x108274ab4, 4, {0xd1008108, 0xb2410102, 0x52800000, 0xd65f03c0}},
    {0x108274ac4, 2, {0xf2fa0001, 0x17ffbf67}},
    {0x104733d30, 4, {0xa942da75, 0x91004260, 0xaa1503e1, 0x96e3651f}},
    {0x104733d40, 4, {0xf94006c8, 0xaa0003f4, 0xaa1503e0, 0xaa1603e1}},
    {0x104733d50, 4, {0xd63f0100, 0x14000002, 0x52800000, 0x12000000}},
    {0x10462f558, 4, {0x9400029e, 0x910003e0, 0x91004294, 0x940411c8}},
    {0x10462f568, 1, {0x12000000}},
    {0x109d41400, 4, {0x02728051, 0x00e207e4, 0x02728018, 0x00000000}},
    {0x10ab847f0, 4, {0x00010043, 0xffffe98c, 0xff1fbf58, 0x00000000}},
    {0x10ab84800, 4, {0x00000001, 0x00000000, 0x00000013, 0x00000000}},
    {0x10aa20060, 4, {0x74616863, 0x6c69732e, 0x6d746e65, 0x61737365}},
    {0x10aa20070, 1, {0x00006567}},
    // CompositeConfigurationKey<LabsSilentMessageEnabledKey> returns Bool
    // indirectly through x8; x0 is the configuration snapshot, x1/x2 are
    // key metadata/conformance and x20 is the static method's metatype.
    {0x104788560, 4, {0xa9be4ff4, 0xa9017bfd, 0x910043fd, 0xaa0803f3}},
    {0x104788570, 4, {0x97ffffcc, 0x12000008, 0x39000268, 0xa9417bfd}},
    {0x104788580, 2, {0xa8c24ff4, 0xd65f03c0}},
    {0x1047884a0, 4, {0xd10103ff, 0xa90157f6, 0xa9024ff4, 0xa9037bfd}},
    {0x1047884b0, 4, {0x9100c3fd, 0xaa0003f4, 0x97ff9c9d, 0x36000060}},
    {0x1047884c0, 2, {0x52800000, 0x14000022}},
    {0x103403e24, 4, {0xa9be4ff4, 0xa9017bfd, 0x910043fd, 0xaa0103e0}},
    {0x103403e34, 4, {0xf9400869, 0xaa0203f4, 0xaa0203e1, 0xaa0303e2}},
    {0x103403e44, 3, {0xd63f0120, 0xa9417bfd, 0x1730228f}},
    {0x104733ce0, 4, {0x9002b297, 0x910342f7, 0xaa1703e0, 0x953a6086}},
    {0x104733cf0, 4, {0xf9000be0, 0x910082e0, 0x910043e1, 0x953a6082}},
    {0x104733d00, 4, {0xaa0003f7, 0xd0046ee3, 0x912c4063, 0x91003fe8}},
    {0x104733d10, 3, {0xaa1603e1, 0xaa1503e2, 0x97b37a38}},
    {0x109d89988, 4, {0x02746c51, 0x00dfd2cc, 0x03788180, 0x00000000}},
    {0x104788484, 4, {0x90030708, 0x9126c108, 0xd1008108, 0xb2410101}},
    {0x104788494, 3, {0xd2800360, 0xf2fa0000, 0xd65f03c0}},
    {0x10a8689b0, 4, {0x636e7566, 0x6e6f6974, 0x62616c2e, 0x6c69732e}},
    {0x10a8689c0, 3, {0x5f746e65, 0x7373656d, 0x00656761}}
};

static const RUINInstructionAnchor kChatBackgroundIdiom[] = {
    // UIDevice.isPad calls -[UIDevice userInterfaceIdiom] (return PC 0x106fc4b6c).
    {0x106fc4b64, 4, {0xaa0003f3, 0x949b625e, 0x97ffcb5e, 0xf100069f}},
    // ChatControllersContainer+ChatTheme clears background image views when isPad && !isDefaultTheme.
    {0x104349d38, 4, {0x96f3046c, 0xaa0003f4, 0x94b1eb82, 0x36000480}},
    // ChatBackgroundView builder clears background image views when isPad && !isDefaultTheme.
    {0x10026860c, 4, {0x97f68a37, 0xaa0003f4, 0x95b5714d, 0x36000260}}
};

const RUINVersionMapping RUINLINE26170 = {
    .host = {"26.17.0", "2026.1103.1841", "614CED59-07E5-372D-94B2-D4901870C7A0",
        "a3de1677f3140ed076554f642933209db2d41b838d2a28b98ab4a2bdcacf1bd8", RUINMappingStatusUnverified},
    .themes = {
        .shopNavigation = {RUINMappingStatusVerified, 0x100043524, 0x10a647430,
            kShopNavigation, sizeof(kShopNavigation) / sizeof(*kShopNavigation)},
        // The exact native read adapter is ready; generic ShopScheme ownership is not proven.
        .shopEligibility = {
            .status = RUINMappingStatusUnsupported,
            .nativeReadAdapterStatus = RUINMappingStatusVerified,
            .shopSchemeScopeStatus = RUINMappingStatusUnverified,
            .modeReturnPC = 0x106af1c60,
            .accountReturnPC = 0x106ad9cd4,
            .modeCopyReturnPC = 0x106ad9b30,
            .accountChainAlternatives = kShopEligibilityAccountChains,
            .accountChainAlternativeCount = sizeof(kShopEligibilityAccountChains) / sizeof(*kShopEligibilityAccountChains),
            .stylesheetEligibilityReturnPC = 0x1002387e0,
            .stylesheetSaveReturnPC = 0x105f7d7d8,
            .capabilityReturnPC = 0x1007642a4,
            .shopSchemeReturnPCs = {0x1003ac4ac, 0x1003ac4b8},
            .shopSchemeHandlerReturnPCs = {0x1003acd98, 0x1003acf20},
            .nvSchemeReturnPC = 0x1003e9a8c,
            .plainModeStackOffset = 0xb4,
            .anchors = kShopEligibility,
            .anchorCount = sizeof(kShopEligibility) / sizeof(*kShopEligibility)
        },
        .validation = {RUINMappingStatusVerified, 0x1057a5cec, 0x1025cc684, 0x10a93cbf0,
            kThemeValidation, sizeof(kThemeValidation) / sizeof(*kThemeValidation)},
        .localPolicy = {RUINMappingStatusVerified, 0x10595116c, {0x105955ea8, 0x1059556dc},
            0x1059582a4, kThemeLocalPolicy, sizeof(kThemeLocalPolicy) / sizeof(*kThemeLocalPolicy)},
        .featureAddresses = {.status = RUINMappingStatusUnsupported},
        .chatBackgroundIdiom = {RUINMappingStatusVerified, 0x106fc4b6c, {0x104349d44, 0x100268618},
            kChatBackgroundIdiom, sizeof(kChatBackgroundIdiom) / sizeof(*kChatBackgroundIdiom)}
    },
    .messaging = {
        // This version's cursor comparison runs after server success.
        // Preserve native synchronization; suppress reads at their producer.
        .readBoundary = {.status = RUINMappingStatusUnsupported},
        .unsendOperation = {RUINMappingStatusVerified, kUnsendParser,
            sizeof(kUnsendParser) / sizeof(*kUnsendParser), 0x10476ec44,
            RUINMappingStatusVerified, kUnsendLookup, sizeof(kUnsendLookup) / sizeof(*kUnsendLookup)},
        .readUntilABIStatus = RUINMappingStatusVerified,
        .nativeMuteSend = {
            .status = RUINMappingStatusVerified,
            .witnessTableVA = 0x10c469420,
            .conformanceVA = 0x109d41400,
            .getterVA = 0x104031730,
            .policyReturnVA = 0x104733d54,
            .anchors = kNativeMuteSend,
            .anchorCount = sizeof(kNativeMuteSend) / sizeof(*kNativeMuteSend),
            .configurationWitnessTableVA = 0x10d511b10,
            .configurationConformanceVA = 0x109d89988,
            .configurationValueTypeVA = 0x10a20b821,
            .configurationGetterVA = 0x104788560,
            .configurationReturnVA = 0x103403e48
        }
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
    },
    .legacyHome = {
        .status = RUINMappingStatusVerified,
        .factoryClassVA = 0x10d300170,
        .homeWitnessVA = 0x10d4afb50,
        .homeConformanceVA = 0x109cf32b4,
        .homeMetadataVA = 0x10c4044b8,
        .homeDecoderVA = 0x102cb3f44,
        .globalWitnessAccessorVA = 0x103448a7c,
        .globalConformanceVA = 0x109c940b0,
        .globalMetadataVA = 0x10c39e9f0,
        .globalDecoderVA = 0x1034478dc,
        .homeFlagStringVA = 0x10a8b4440,
        .globalHomeFlagStringVA = 0x10a86dfd0,
        .anchors = kLegacyHome,
        .anchorCount = sizeof(kLegacyHome) / sizeof(*kLegacyHome)
    }
};
