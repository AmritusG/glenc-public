/*
 * DXVKit: LZF decompression for legacy (DXDI) packets.
 *
 * Written from the format description in docs/spec/DXV_FORMAT.md section 4.2 and the public liblzf
 * format description.
 *
 * MIT License. Copyright (c) 2026 Amrit Rosell. See LICENSE.
 */
#include "dxvk_priv.h"

dxvk_status dxvk_lzf_decode(const uint8_t *in, size_t in_size, uint8_t *out, size_t out_size)
{
    const uint8_t *ip = in, *const in_end = in + in_size;
    size_t op = 0;

    while (ip < in_end) {
        unsigned ctrl = *ip++;
        if (ctrl < 32u) {
            size_t run = (size_t)ctrl + 1u;
            if ((size_t)(in_end - ip) < run)
                return DXVK_ERR_LZF;
            if (out_size - op < run)
                return DXVK_ERR_LZF_LENGTH;
            memcpy(out + op, ip, run);
            ip += run;
            op += run;
        } else {
            size_t len = ctrl >> 5, back;
            if (len == 7u) {
                if (ip >= in_end)
                    return DXVK_ERR_LZF;
                len += *ip++;
            }
            if (ip >= in_end)
                return DXVK_ERR_LZF;
            back = (((size_t)ctrl & 31u) << 8) + *ip++ + 1u;
            len += 2u;
            if (back > op)
                return DXVK_ERR_LZF;
            if (out_size - op < len)
                return DXVK_ERR_LZF_LENGTH;
            if (back >= len) {
                memcpy(out + op, out + op - back, len);
                op += len;
            } else {
                /* overlapping: byte by byte, repeating the pattern */
                const uint8_t *src = out + op - back;
                for (size_t i = 0; i < len; i++)
                    out[op + i] = src[i];
                op += len;
            }
        }
    }
    return op == out_size ? DXVK_OK : DXVK_ERR_LZF_LENGTH;
}
