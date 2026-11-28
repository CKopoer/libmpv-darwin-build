// SPDX-License-Identifier: LGPL-2.1-or-later
#include <assert.h>
#include "joc_dependent.h"

int main(void)
{
    // Synthetic bitstream information only. Surround back pair and JOC complexity index 16.
    const uint8_t surround[] = {0x0b, 0x77, 0x47, 0xff, 0x3a, 0x83, 0xd1,
                                0xa0, 0x02, 0x08, 0x08, 0x80};
    const uint8_t center_pair[] = {0x0b, 0x77, 0x47, 0xff, 0x3a, 0x83, 0xd0,
                            0x40, 0x02, 0x08, 0x08, 0x18};
    const uint8_t lfe2[] = {0x0b, 0x77, 0x47, 0xff, 0x3a, 0x83, 0xd0,
                            0x00, 0x20};
    struct joc_dependent_info info = {0};
    for (size_t n = 0; n < sizeof(surround); n++)
        assert(!joc_read_dependent(surround, n, &info));
    assert(!info.locations && !info.complexity);
    assert(joc_read_dependent(surround, sizeof(surround), &info));
    assert(info.locations == 2 && info.complexity == 16);
    info = (struct joc_dependent_info){0};
    assert(joc_read_dependent(lfe2, sizeof(lfe2), &info));
    assert(info.locations == 0x100 && !info.complexity);
    assert(joc_read_dependent(center_pair, sizeof(center_pair), &info));
    assert(info.locations == 0x101 && info.complexity == 3);
    return 0;
}
