#import "NativeTabMappings.h"
#include <string.h>

static const RUINNativeTabMapping mappings[] = {
    {"26.16.0", "2026.1006.1718", 0x100010f38, 0x10bee1590, 0x107d5cf48,
        0x109670bf0, 0x100725540,
        {0xaa1603e0, 0xaa1503e1, 0xd61f0100}, {0x24, 0x10, 0x20, 0x18, 0x40},
        {0x28, 0x50, 0x70, 0x80, 0x98},
        {0x107d5cbdc, 4, {0xd10183ff, 0xa90167fa, 0xa9025ff8, 0xa90357f6}}, 0x107d5cf48,
        {0x10072529c, 0x100725304, 0x100725440, 0x1007254c8, 0x100725520}},
    {"26.17.0", "2026.1103.1841", 0x100011130, 0x10c123698, 0x107ee13c4,
        0x10984f1b0, 0x1007365a4,
        {0xaa1603e0, 0xaa1503e1, 0xd61f0100}, {0x24, 0x10, 0x20, 0x18, 0x40},
        {0x28, 0x50, 0x70, 0x80, 0x98},
        {0x107ee1058, 4, {0xd10183ff, 0xa90167fa, 0xa9025ff8, 0xa90357f6}}, 0x107ee13c4,
        {0x100736300, 0x100736368, 0x1007364a4, 0x10073652c, 0x100736584}}
};

const RUINNativeTabMapping *RUINNativeTabMappingForHost(const RUINHostIdentity *host) {
    if (!host) return NULL;
    for (size_t i = 0; i < sizeof(mappings) / sizeof(mappings[0]); i++)
        if (!strcmp(host->version,mappings[i].version) && !strcmp(host->build,mappings[i].build)) return &mappings[i];
    return NULL;
}
