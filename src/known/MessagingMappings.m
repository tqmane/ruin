#import "MessagingMappings.h"

static const RUINInstructionAnchor readBoundary2616Anchors[] = {
    {0x103e15638, 3, {0xaa1603e0, 0x95593b59, 0xaa0003f5}}
};

static const RUINInstructionAnchor unsend2616Anchors[] = {
    {0x1000bac24, 1, {0xf277053f}}, {0x1000bac30, 1, {0x951590af}},
    {0x1000bac44, 1, {0x94f5bb78}}, {0x103e29b2c, 1, {0x94000003}},
    {0x103e29b7c, 1, {0x9407fdd4}}, {0x103e29b80, 1, {0xb4000415}},
    {0x103e29c04, 1, {0xb4fffc20}}, {0x103e29dcc, 1, {0x9400057e}},
    {0x1040292fc, 1, {0x97fa9bd2}}, {0x103ed03a8, 1, {0x9554620e}},
    {0x103ed03c4, 1, {0xb4000160}}, {0x103ed03f4, 1, {0xd2800017}},
    {0x10461ef0c, 1, {0x9538eaa5}}, {0x10461f234, 1, {0xf10102bf}},
    {0x10461f23c, 1, {0xf10106bf}}
};
static const uintptr_t unsend2616LookupReturnAddresses[] = {
    0x103ed03ac, 0x104029300, 0x103e29b80, 0x103e29b30, 0x1000bac48
};

static const RUINInstructionAnchor readBoundary2617Anchors[] = {
    {0x103ebdce8, 4, {0xaa1403e0, 0x955e035d, 0xeb13001f, 0x5400026a}}
};

// The parser and dispatcher are identified exactly. Retention stays disabled
// until the ordered Core Data lookup chain across Swift indirect dispatch is
// independently mapped for this host.
static const RUINInstructionAnchor unsend2617ParserAnchors[] = {
    {0x1000bb634, 3, {0x951acd7b, 0xb400d2c0, 0xaa0003f3}},
    {0x1000bb648, 1, {0x94f85864}},
    {0x103ed1824, 1, {0x9401f111}},
    {0x10476ec40, 1, {0x953b14d8}},
    {0x10476ec68, 1, {0x953b14d6}},
    {0x10476eea4, 1, {0x953b144f}},
    {0x10476ef5c, 1, {0x953ca309}},
    {0x10476ef68, 1, {0xf10102bf}},
    {0x10476ef70, 1, {0xf10106bf}}
};

static const RUINMessagingMapping mappings[] = {
    {
        &RUINKnownHosts[0],
        {readBoundary2616Anchors, sizeof(readBoundary2616Anchors) / sizeof(readBoundary2616Anchors[0]), 0x103e15640},
        {unsend2616Anchors, sizeof(unsend2616Anchors) / sizeof(unsend2616Anchors[0]), 0x10461ef10,
            unsend2616LookupReturnAddresses, sizeof(unsend2616LookupReturnAddresses) / sizeof(unsend2616LookupReturnAddresses[0])}
    },
    {
        &RUINKnownHosts[1],
        {readBoundary2617Anchors, sizeof(readBoundary2617Anchors) / sizeof(readBoundary2617Anchors[0]), 0x103ebdcf0},
        {unsend2617ParserAnchors, sizeof(unsend2617ParserAnchors) / sizeof(unsend2617ParserAnchors[0]), 0x10476ec44, NULL, 0}
    }
};

const RUINMessagingMapping *RUINMessagingMappingForHost(const RUINHostIdentity *host) {
    if (!host) return NULL;
    for (size_t i = 0; i < sizeof(mappings) / sizeof(mappings[0]); i++)
        if (mappings[i].host == host) return &mappings[i];
    return NULL;
}

const RUINMessagingMapping *RUINMessagingMappingForInfo(NSDictionary *info) {
    return RUINMessagingMappingForHost(RUINKnownHostForInfo(info));
}
