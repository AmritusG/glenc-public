/*
 * DXVKit: packet headers, frame geometry and dispatch to the lossless layers.
 *
 * MIT License. Copyright (c) 2026 Amrit Rosell. See LICENSE.
 */
#include "dxvk_priv.h"

/* DXV3 texture tags: the four header bytes read as a little-endian u32 (spec 3.1). */
#define TAG_DXT1 0x44585431u
#define TAG_DXT5 0x44585435u
#define TAG_YCG6 0x59434736u
#define TAG_YG10 0x59473130u

#define DXV3_HEADER 12u
#define LEGACY_HEADER 4u

const char *dxvk_status_string(dxvk_status status)
{
    switch (status) {
    case DXVK_OK: return "ok";
    case DXVK_ERR_ARGUMENT: return "invalid argument";
    case DXVK_ERR_BUFFER_TOO_SMALL: return "output buffer too small";
    case DXVK_ERR_TRUNCATED: return "packet shorter than its header or its declared payload";
    case DXVK_ERR_UNKNOWN_VARIANT: return "unknown texture variant";
    case DXVK_ERR_UNSUPPORTED: return "stored flag on a High Quality variant";
    case DXVK_ERR_PAYLOAD_END: return "payload ends before the texture is complete";
    case DXVK_ERR_BAD_DISTANCE: return "copy distance reaches before the first block";
    case DXVK_ERR_LZF: return "malformed LZF stream";
    case DXVK_ERR_LZF_LENGTH: return "LZF output length differs from the texture size";
    case DXVK_ERR_HQ_SECTION: return "HQ section header out of range";
    case DXVK_ERR_HQ_OPCODE_COUNT: return "HQ opcode count exceeds the block count";
    case DXVK_ERR_FSE_TABLE: return "malformed FSE frequency table";
    case DXVK_ERR_FSE_STREAM: return "malformed FSE bitstream";
    case DXVK_ERR_HQ_OPCODES_USED_UP: return "HQ opcodes used up before the texture is complete";
    case DXVK_ERR_HQ_BAD_OPCODE: return "HQ opcode value out of range";
    case DXVK_ERR_HQ_EMPTY_SLOT: return "HQ dictionary slot is empty";
    case DXVK_ERR_HQ_LITERALS: return "HQ literal read past the literal area";
    case DXVK_ERR_IO: return "I/O error";
    case DXVK_ERR_NOT_MOV: return "not a QuickTime file";
    case DXVK_ERR_NO_DXV_TRACK: return "no DXV video track";
    case DXVK_ERR_MOV_CORRUPT: return "malformed QuickTime file";
    case DXVK_ERR_OUT_OF_MEMORY: return "out of memory";
    case DXVK_ERR_RANGE: return "frame index out of range";
    case DXVK_ERR_BAD_HEADER: return "DXV3 header: version byte below 4 or stored flag above 1";
    }
    return "unknown status";
}

const char *dxvk_version_string(void) { return DXVKIT_VERSION; }

const char *dxvk_variant_name(dxvk_variant variant)
{
    switch (variant) {
    case DXVK_VARIANT_DXT1: return "DXT1";
    case DXVK_VARIANT_DXT5: return "DXT5";
    case DXVK_VARIANT_YCG6: return "YCG6";
    case DXVK_VARIANT_YG10: return "YG10";
    case DXVK_VARIANT_LEGACY_DXT1: return "legacy DXT1";
    case DXVK_VARIANT_LEGACY_DXT5: return "legacy DXT5";
    }
    return "unknown";
}

int dxvk_variant_has_alpha(dxvk_variant variant)
{
    return variant == DXVK_VARIANT_DXT5 || variant == DXVK_VARIANT_YG10 ||
           variant == DXVK_VARIANT_LEGACY_DXT5;
}

dxvk_status dxvk_layout(dxvk_variant variant, uint32_t width, uint32_t height,
                        dxvk_frame_layout *layout)
{
    dxvk_frame_layout l;
    if (!layout || width == 0 || height == 0 || width > DXVK_MAX_DIMENSION ||
        height > DXVK_MAX_DIMENSION)
        return DXVK_ERR_ARGUMENT;
    memset(&l, 0, sizeof l);
    l.variant = variant;
    l.display_width = width;
    l.display_height = height;
    l.coded_width = (width + 15u) & ~15u;
    l.coded_height = (height + 15u) & ~15u;
    l.pixels_x[0] = l.coded_width;
    l.pixels_y[0] = l.coded_height;
    l.blocks_x[0] = l.coded_width / 4u;
    l.blocks_y[0] = l.coded_height / 4u;
    l.plane_count = 1;
    switch (variant) {
    case DXVK_VARIANT_DXT1:
    case DXVK_VARIANT_LEGACY_DXT1: l.format[0] = DXVK_BLOCKS_BC1; break;
    case DXVK_VARIANT_DXT5:
    case DXVK_VARIANT_LEGACY_DXT5: l.format[0] = DXVK_BLOCKS_BC3; break;
    case DXVK_VARIANT_YCG6: l.format[0] = DXVK_BLOCKS_BC4; break;
    case DXVK_VARIANT_YG10: l.format[0] = DXVK_BLOCKS_BC5; break;
    default: return DXVK_ERR_ARGUMENT;
    }
    if (variant == DXVK_VARIANT_YCG6 || variant == DXVK_VARIANT_YG10) {
        l.plane_count = 2;
        l.format[1] = DXVK_BLOCKS_BC5;
        l.pixels_x[1] = l.coded_width / 2u;
        l.pixels_y[1] = l.coded_height / 2u;
        l.blocks_x[1] = l.coded_width / 8u;
        l.blocks_y[1] = l.coded_height / 8u;
    }
    for (int i = 0; i < l.plane_count; i++) {
        size_t block_bytes =
            (l.format[i] == DXVK_BLOCKS_BC1 || l.format[i] == DXVK_BLOCKS_BC4) ? 8u : 16u;
        l.bytes[i] = (size_t)l.blocks_x[i] * l.blocks_y[i] * block_bytes;
    }
    *layout = l;
    return DXVK_OK;
}

/* 1 when the packet is a DXV3 packet: its first four bytes are one of the four texture tags. Any other
 * packet is legacy. The packet decides, never the container FourCC (spec 2.2). */
static int is_dxv3_packet(const uint8_t *p, size_t size, dxvk_variant *variant)
{
    if (size < 4u)
        return 0;
    switch (dxvk_le32(p)) {
    case TAG_DXT1: *variant = DXVK_VARIANT_DXT1; return 1;
    case TAG_DXT5: *variant = DXVK_VARIANT_DXT5; return 1;
    case TAG_YCG6: *variant = DXVK_VARIANT_YCG6; return 1;
    case TAG_YG10: *variant = DXVK_VARIANT_YG10; return 1;
    }
    return 0;
}

/* Parses the header. *header_size = header bytes, *payload_size = declared payload length. The
 * generation argument is only validated: the packet itself decides (spec 2.2). */
static dxvk_status parse_header(dxvk_generation generation, const uint8_t *p, size_t size,
                                dxvk_variant *variant, int *stored, size_t *header_size,
                                size_t *payload_size)
{
    if (generation != DXVK_GEN_DXV3 && generation != DXVK_GEN_LEGACY && generation != DXVK_GEN_AUTO)
        return DXVK_ERR_ARGUMENT;
    if (is_dxv3_packet(p, size, variant)) {
        if (size < DXV3_HEADER)
            return DXVK_ERR_TRUNCATED;
        /* version byte = version + 1: below 4 is invalid; stored flag only 0 or 1 (spec 3.2) */
        if (p[4] < 4u || p[6] > 1u)
            return DXVK_ERR_BAD_HEADER;
        *stored = p[6];
        *header_size = DXV3_HEADER;
        *payload_size = dxvk_le32(p + 8);
    } else {
        uint32_t word, type;
        if (size < LEGACY_HEADER)
            return DXVK_ERR_TRUNCATED;
        word = dxvk_le32(p);
        type = word >> 24;
        /* bit 0x40 selects DXT5, everything else is DXT1; no type byte is rejected (spec 4.1) */
        *variant = (type & 0x40u) ? DXVK_VARIANT_LEGACY_DXT5 : DXVK_VARIANT_LEGACY_DXT1;
        *stored = (type & 0x80u) != 0;
        *header_size = LEGACY_HEADER;
        *payload_size = word & 0xFFFFFFu;
    }
    if (*payload_size > size - *header_size)
        return DXVK_ERR_TRUNCATED;
    return DXVK_OK;
}

dxvk_status dxvk_packet_variant(dxvk_generation generation, const void *packet, size_t packet_size,
                                dxvk_variant *variant, int *stored)
{
    size_t header_size, payload_size;
    dxvk_variant v;
    int s;
    dxvk_status st;
    if (!packet)
        return DXVK_ERR_ARGUMENT;
    st = parse_header(generation, (const uint8_t *)packet, packet_size, &v, &s, &header_size,
                      &payload_size);
    if (st != DXVK_OK)
        return st;
    if (variant)
        *variant = v;
    if (stored)
        *stored = s;
    return DXVK_OK;
}

dxvk_status dxvk_decode_blocks(dxvk_generation generation, const void *packet, size_t packet_size,
                               uint32_t width, uint32_t height, const dxvk_options *options,
                               void *const planes[2], const size_t plane_capacity[2],
                               dxvk_frame_layout *layout_out, dxvk_consumption *consumption)
{
    const uint8_t *p = (const uint8_t *)packet;
    const uint8_t *payload;
    size_t header_size, payload_size, used = 0;
    dxvk_variant variant;
    dxvk_frame_layout layout;
    dxvk_consumption cons;
    int stored;
    dxvk_status st;

    if (!packet || !planes || !plane_capacity)
        return DXVK_ERR_ARGUMENT;
    st = parse_header(generation, p, packet_size, &variant, &stored, &header_size, &payload_size);
    if (st != DXVK_OK)
        return st;
    st = dxvk_layout(variant, width, height, &layout);
    if (st != DXVK_OK)
        return st;
    for (int i = 0; i < layout.plane_count; i++) {
        if (!planes[i])
            return DXVK_ERR_ARGUMENT;
        if (plane_capacity[i] < layout.bytes[i])
            return DXVK_ERR_BUFFER_TOO_SMALL;
    }
    payload = p + header_size;
    memset(&cons, 0, sizeof cons);

    if (stored) {
        /* the plane streams back to back: HQ = plane 0 then plane 1 (spec 3.3, 4.2) */
        size_t need = layout.bytes[0] + layout.bytes[1];
        if (payload_size < need)
            return DXVK_ERR_PAYLOAD_END;
        memcpy(planes[0], payload, layout.bytes[0]);
        if (layout.plane_count == 2)
            memcpy(planes[1], payload + layout.bytes[0], layout.bytes[1]);
        used = need;
    } else {
        size_t blocks = (size_t)layout.blocks_x[0] * layout.blocks_y[0];
        switch (variant) {
        case DXVK_VARIANT_LEGACY_DXT1:
        case DXVK_VARIANT_LEGACY_DXT5:
            st = dxvk_lzf_decode(payload, payload_size, (uint8_t *)planes[0], layout.bytes[0]);
            used = payload_size;
            break;
        case DXVK_VARIANT_DXT1:
            st = dxvk_decode_dxt1(payload, payload_size, (uint8_t *)planes[0], blocks, &used);
            break;
        case DXVK_VARIANT_DXT5:
            st = dxvk_decode_dxt5(payload, payload_size, (uint8_t *)planes[0], blocks, &used);
            break;
        case DXVK_VARIANT_YCG6:
        case DXVK_VARIANT_YG10:
            st = dxvk_decode_hq(payload, payload_size, &layout, (uint8_t *)planes[0],
                                (uint8_t *)planes[1], options ? options->jobs : NULL, &cons);
            used = payload_size - cons.payload_unused;
            break;
        }
        if (st != DXVK_OK)
            return st;
    }
    if (layout_out)
        *layout_out = layout;
    if (consumption) {
        cons.packet_size = packet_size;
        cons.payload_size = payload_size;
        cons.payload_unused = payload_size - used;
        *consumption = cons;
    }
    return DXVK_OK;
}
