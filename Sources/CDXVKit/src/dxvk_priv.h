/*
 * DXVKit internal helpers.
 *
 * MIT License. Copyright (c) 2026 Amrit Rosell. See LICENSE.
 */
#ifndef DXVK_PRIV_H
#define DXVK_PRIV_H

#include "dxvkit.h"

#include <string.h>

#if defined(__GNUC__) || defined(__clang__)
#define DXVK_INLINE static __inline__ __attribute__((always_inline))
#define DXVK_LIKELY(x) __builtin_expect(!!(x), 1)
#define DXVK_UNLIKELY(x) __builtin_expect(!!(x), 0)
#else
#define DXVK_INLINE static
#define DXVK_LIKELY(x) (x)
#define DXVK_UNLIKELY(x) (x)
#endif

DXVK_INLINE uint32_t dxvk_le16(const uint8_t *p) { return (uint32_t)p[0] | ((uint32_t)p[1] << 8); }
DXVK_INLINE uint32_t dxvk_le24(const uint8_t *p)
{
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16);
}
DXVK_INLINE uint32_t dxvk_le32(const uint8_t *p)
{
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}
DXVK_INLINE uint64_t dxvk_le64(const uint8_t *p)
{
    return (uint64_t)dxvk_le32(p) | ((uint64_t)dxvk_le32(p + 4) << 32);
}
DXVK_INLINE uint32_t dxvk_be16(const uint8_t *p) { return ((uint32_t)p[0] << 8) | p[1]; }
DXVK_INLINE uint32_t dxvk_be32(const uint8_t *p)
{
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3];
}
DXVK_INLINE uint64_t dxvk_be64(const uint8_t *p)
{
    return ((uint64_t)dxvk_be32(p) << 32) | dxvk_be32(p + 4);
}

/* Byte cursor over [pos, end). */
typedef struct dxvk_cursor {
    const uint8_t *pos;
    const uint8_t *end;
} dxvk_cursor;

DXVK_INLINE size_t dxvk_left(const dxvk_cursor *c) { return (size_t)(c->end - c->pos); }

/* Block-copy layers (blockcopy.c): decode into a stream of exactly `blocks` blocks. */
dxvk_status dxvk_decode_dxt1(const uint8_t *payload, size_t size, uint8_t *out, size_t blocks,
                             size_t *used);
dxvk_status dxvk_decode_dxt5(const uint8_t *payload, size_t size, uint8_t *out, size_t blocks,
                             size_t *used);

/* Legacy LZF (legacy.c): output must be exactly out_size bytes. */
dxvk_status dxvk_lzf_decode(const uint8_t *in, size_t in_size, uint8_t *out, size_t out_size);

/* HQ layer (hq.c). */
dxvk_status dxvk_decode_hq(const uint8_t *payload, size_t size, const dxvk_frame_layout *layout,
                           uint8_t *plane0, uint8_t *plane1, const dxvk_jobs *jobs,
                           dxvk_consumption *consumption);

#endif /* DXVK_PRIV_H */
