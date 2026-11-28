// SPDX-License-Identifier: LGPL-2.1-or-later
// ETSI TS 102 366 E.1.2.2 (dependent syncframe BSI), tables E.1.4 and F.6.1.
// The independent stream section of the EC3SpecificBox still comes from movenc.
#ifndef BILISAIL_JOC_DEPENDENT_H
#define BILISAIL_JOC_DEPENDENT_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

struct joc_bits {
    const uint8_t *data;
    size_t position, end;
    bool truncated;
};

static unsigned joc_bits_read(struct joc_bits *b, unsigned count)
{
    if (count > b->end - b->position) {
        b->truncated = true;
        return 0;
    }
    unsigned value = 0;
    while (count--) {
        size_t i = b->position++;
        value = (value << 1) | ((b->data[i / 8] >> (7 - i % 8)) & 1);
    }
    return value;
}

struct joc_dependent_info {
    unsigned locations;
    unsigned complexity;
};

static bool joc_read_dependent(const uint8_t *frame, size_t size,
                               struct joc_dependent_info *info)
{
    // The caller has separated this syncframe with av_ac3_parse_header.
    if (size < 7 || size > 4096 || (frame[2] >> 6) != 1) return false;
    struct joc_bits b = { .data = frame, .position = 45, .end = size * 8 };
    unsigned fscod = frame[4] >> 6;
    unsigned acmod = (frame[4] >> 1) & 7;
    bool lfe = frame[4] & 1;
    int programs = acmod == 0 ? 2 : 1;
    for (int i = 0; i < programs; i++) {
        joc_bits_read(&b, 5); // dialnorm
        if (joc_bits_read(&b, 1)) joc_bits_read(&b, 8);
    }
    unsigned locations = 0;
    if (joc_bits_read(&b, 1)) {
        unsigned map = joc_bits_read(&b, 16);
        // chanmap is MSB-first; chan_loc numbers extra positions from the LSB.
        for (unsigned i = 0; i < 8; i++)
            if (map & (1u << (10 - i))) locations |= 1u << i;
        if (map & 2) locations |= 1u << 8; // LFE2; Lts/Rts has no chan_loc bit.
    }
    if (joc_bits_read(&b, 1)) { // mixmdate
        if (acmod > 2) {
            joc_bits_read(&b, 2);
            if (acmod & 1) joc_bits_read(&b, 6);
            if (acmod & 4) joc_bits_read(&b, 6);
        }
        if (lfe && joc_bits_read(&b, 1)) joc_bits_read(&b, 5);
    }
    if (joc_bits_read(&b, 1)) { // infomdate
        joc_bits_read(&b, 5);
        if (acmod == 2) joc_bits_read(&b, 4);
        if (acmod >= 6) joc_bits_read(&b, 2);
        for (int i = 0; i < programs; i++)
            if (joc_bits_read(&b, 1)) joc_bits_read(&b, 8);
        if (fscod != 3) joc_bits_read(&b, 1);
    }
    unsigned complexity = 0;
    if (joc_bits_read(&b, 1)) {
        unsigned length = joc_bits_read(&b, 6) + 1;
        if (length * 8 > b.end - b.position) return false;
        if (joc_bits_read(&b, 8) & 1) {
            if (length < 2) return false;
            complexity = joc_bits_read(&b, 8);
            if (!complexity) return false;
        }
    }
    if (b.truncated) return false;
    info->locations |= locations;
    if (complexity) info->complexity = complexity;
    return true;
}
#endif
