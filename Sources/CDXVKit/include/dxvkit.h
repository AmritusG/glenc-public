/*
 * DXVKit: a clean-room decoder and encoder for Resolume's DXV video codec.
 *
 * MIT License. Copyright (c) 2026 Amrit Rosell. See LICENSE.
 */
#ifndef DXVKIT_H
#define DXVKIT_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define DXVKIT_VERSION "1.0.0"
#define DXVK_VERSION_MAJOR 1
#define DXVK_VERSION_MINOR 0
#define DXVK_VERSION_PATCH 0

/* The library's version string, DXVKIT_VERSION of the build that was linked. */
const char *dxvk_version_string(void);

/* Largest display width / height accepted (pixels). */
#define DXVK_MAX_DIMENSION 16384

/* ------------------------------------------------------------------------------------------------ */
/* Status codes                                                                                     */
/* ------------------------------------------------------------------------------------------------ */

typedef enum dxvk_status {
    DXVK_OK = 0,
    DXVK_ERR_ARGUMENT,          /* NULL pointer, bad dimension, unknown option */
    DXVK_ERR_BUFFER_TOO_SMALL,  /* a caller buffer is smaller than required */
    DXVK_ERR_TRUNCATED,         /* packet shorter than its header, or header length > packet */
    DXVK_ERR_UNKNOWN_VARIANT,   /* unknown texture variant (not returned by the 1.0 decoder: a packet
                                   without a DXV3 tag is legacy, and every legacy type byte is valid) */
    DXVK_ERR_UNSUPPORTED,       /* stored flag on an HQ variant (encoder only since 1.0) */
    DXVK_ERR_PAYLOAD_END,       /* the payload ends before the texture is complete */
    DXVK_ERR_BAD_DISTANCE,      /* a copy reaches before the first block */
    DXVK_ERR_LZF,               /* malformed LZF stream (truncated op, reference before start) */
    DXVK_ERR_LZF_LENGTH,        /* LZF output length differs from the texture size */
    DXVK_ERR_HQ_SECTION,        /* HQ section header: opcode-area offset out of range */
    DXVK_ERR_HQ_OPCODE_COUNT,   /* HQ opcode count larger than the channel's block count */
    DXVK_ERR_FSE_TABLE,         /* FSE frequency table malformed or truncated */
    DXVK_ERR_FSE_STREAM,        /* FSE bitstream area too short, past the payload, or exhausted */
    DXVK_ERR_HQ_OPCODES_USED_UP,/* a block needs an opcode after the channel's opcodes are used up */
    DXVK_ERR_HQ_BAD_OPCODE,     /* opcode value 18 or larger */
    DXVK_ERR_HQ_EMPTY_SLOT,     /* dictionary slot used before anything was stored in it */
    DXVK_ERR_HQ_LITERALS,       /* literal read past the literal area */
    DXVK_ERR_IO,                /* file could not be opened or read */
    DXVK_ERR_NOT_MOV,           /* not a QuickTime file */
    DXVK_ERR_NO_DXV_TRACK,      /* QuickTime file without a DXV video track */
    DXVK_ERR_MOV_CORRUPT,       /* malformed or inconsistent QuickTime structures */
    DXVK_ERR_OUT_OF_MEMORY,
    DXVK_ERR_RANGE,             /* frame index out of range */
    DXVK_ERR_BAD_HEADER         /* DXV3 header: version byte below 4, or stored flag other than 0 / 1 */
} dxvk_status;

/* Static English description of a status code. Never NULL. */
const char *dxvk_status_string(dxvk_status status);

/* ------------------------------------------------------------------------------------------------ */
/* Variants and geometry                                                                            */
/* ------------------------------------------------------------------------------------------------ */

/*
 * Generation of the container (a hint). Since 1.0 the packet decides, as Resolume Arena does (spec 2.2):
 * a packet whose first four bytes are a DXV3 texture tag is DXV3, any other packet is legacy, whatever
 * the FourCC. The three values therefore decode identically.
 */
typedef enum dxvk_generation {
    DXVK_GEN_DXV3 = 0,   /* sample-entry FourCC 'DXD3' or 'DXD4' */
    DXVK_GEN_LEGACY = 1, /* sample-entry FourCC 'DXDI' (DXV1 / DXV2) */
    DXVK_GEN_AUTO = 2    /* no container information */
} dxvk_generation;

typedef enum dxvk_variant {
    DXVK_VARIANT_DXT1 = 0,         /* DXV3 Normal Quality: BC1 */
    DXVK_VARIANT_DXT5,             /* DXV3 Normal Quality With Alpha: BC3 */
    DXVK_VARIANT_YCG6,             /* DXV3 High Quality: Y BC4 + CoCg BC5 */
    DXVK_VARIANT_YG10,             /* DXV3 High Quality With Alpha: YA BC5 + CoCg BC5 */
    DXVK_VARIANT_LEGACY_DXT1,      /* DXDI: BC1 */
    DXVK_VARIANT_LEGACY_DXT5       /* DXDI: BC3 */
} dxvk_variant;

/* Name such as "DXT1", "YCG6", "legacy DXT1". Never NULL. */
const char *dxvk_variant_name(dxvk_variant variant);

/* 1 when the variant carries alpha (DXT5, YG10, legacy DXT5), else 0. */
int dxvk_variant_has_alpha(dxvk_variant variant);

/* Block-stream layout per plane (the GPU upload format). */
typedef enum dxvk_block_format {
    DXVK_BLOCKS_NONE = 0,
    DXVK_BLOCKS_BC1,   /* 8-byte blocks, opaque (upload as an opaque BC1 format) */
    DXVK_BLOCKS_BC3,   /* 16-byte blocks */
    DXVK_BLOCKS_BC4,   /* 8-byte blocks, unsigned, one channel */
    DXVK_BLOCKS_BC5    /* 16-byte blocks: channel 0 BC4 block then channel 1 BC4 block, unsigned */
} dxvk_block_format;

/*
 * Geometry of a frame. The coded texture is the display size rounded up to 16 on both axes; all block
 * streams cover the whole coded texture, row by row, top row first.
 *
 *   plane 0: DXT1 / legacy DXT1: BC1 colour.        DXT5 / legacy DXT5: BC3 colour + alpha.
 *            YCG6: BC4 luma (Y).                    YG10: BC5 layout, channel 0 = Y, channel 1 = alpha.
 *            Size: coded_width x coded_height pixels.
 *   plane 1: YCG6 / YG10 only: BC5 layout, channel 0 = Co, channel 1 = Cg (YCoCg chroma, midpoint
 *            127.5, i.e. 0.5 in normalised texture units: spec 8.4).
 *            Size: coded_width/2 x coded_height/2 samples. Other variants: none (size 0).
 */
typedef struct dxvk_frame_layout {
    dxvk_variant variant;
    uint32_t display_width, display_height;
    uint32_t coded_width, coded_height;
    int plane_count;                       /* 1 or 2 */
    dxvk_block_format format[2];
    uint32_t blocks_x[2], blocks_y[2];     /* blocks per row / block rows */
    uint32_t pixels_x[2], pixels_y[2];     /* plane size in pixels (samples) */
    size_t bytes[2];                       /* exact block-stream size of each plane */
} dxvk_frame_layout;

/* Fills *layout for a variant and display size (1..DXVK_MAX_DIMENSION). */
dxvk_status dxvk_layout(dxvk_variant variant, uint32_t width, uint32_t height,
                        dxvk_frame_layout *layout);

/*
 * Reads the packet header only: the variant and whether the payload is stored. Cheap; does not
 * validate the payload. The packet decides the generation (see dxvk_generation); for DXV3 the tag
 * decides the variant, for legacy the type byte (0x40 = DXT5, anything else DXT1).
 */
dxvk_status dxvk_packet_variant(dxvk_generation generation, const void *packet, size_t packet_size,
                                dxvk_variant *variant, int *stored);

/* ------------------------------------------------------------------------------------------------ */
/* Packet decoding                                                                                  */
/* ------------------------------------------------------------------------------------------------ */

/*
 * Optional parallelism. run() must call job(job_arg, i) once for every i in 0..count-1, in any order,
 * possibly concurrently, and return when all calls have returned. The core never creates threads.
 * With no runner (NULL) everything runs on the calling thread.
 */
typedef struct dxvk_jobs {
    void (*run)(void *user, void (*job)(void *job_arg, int index), void *job_arg, int count);
    void *user;
} dxvk_jobs;

/* Decode options. A zeroed struct (or NULL) = defaults. */
#define DXVK_OPT_PREMULTIPLY 0x1u  /* RGBA output: convert straight alpha to premultiplied */

typedef struct dxvk_options {
    uint32_t flags;          /* DXVK_OPT_* */
    const dxvk_jobs *jobs;   /* NULL = single-threaded */
} dxvk_options;

/*
 * How much of the packet a decode used. Filled on success when requested. A packet "consumes its bytes
 * exactly" when payload_unused == 0, literals_unused == 0, opcodes_unused == 0 and fse_bits_left is 32
 * for every FSE stream (Resolume's encoders; see the spec). Resolume's HQ encoder sometimes leaves one
 * opcode after the texture is complete (spec 7.5); its literal bytes are then unread too:
 * literals_unused == literals_dangling means nothing else was left.
 */
typedef struct dxvk_consumption {
    size_t packet_size;
    size_t payload_size;      /* bytes after the header */
    size_t payload_unused;    /* payload bytes after the last byte the decoder needed */
    size_t literals_unused;   /* HQ: literal-area bytes not read (both sections) */
    size_t literals_dangling; /* HQ: literal bytes the unused opcodes would have read */
    uint32_t opcodes_unused;  /* HQ: opcodes decoded but not needed (all channels) */
    uint32_t fse_streams;     /* HQ: number of FSE-coded opcode streams */
    uint32_t fse_bits_left_min, fse_bits_left_max; /* HQ: bits left unread per FSE stream */
    uint32_t opcode_histogram[18]; /* HQ: opcodes used, by value */
} dxvk_consumption;

/*
 * Decodes one packet into block streams (output A). planes[i] must point to at least
 * layout.bytes[i] bytes for every plane of the variant (plane_count); capacities in plane_capacity.
 * width / height = display size from the container. The variant is taken from the packet; on success
 * *layout (optional) describes what was written. consumption may be NULL.
 *
 * Thread safety: no shared state; concurrent calls on different buffers are fine.
 */
dxvk_status dxvk_decode_blocks(dxvk_generation generation, const void *packet, size_t packet_size,
                               uint32_t width, uint32_t height, const dxvk_options *options,
                               void *const planes[2], const size_t plane_capacity[2],
                               dxvk_frame_layout *layout, dxvk_consumption *consumption);

/*
 * Converts decoded block streams (output A, layout as returned by dxvk_decode_blocks) to RGBA8 at the
 * display size (output B): rgba points to the top-left pixel, stride = bytes per row (>= width x 4).
 * DXT1 variants are opaque (alpha 255). BC1 / BC3: the reference integer convention of spec 8.1 / 8.2.
 * YCG6 / YG10 (since 1.0): Resolume Arena's convention (spec 8.4): exact BC4 palettes, chroma sampled
 * nearest-neighbour, chroma midpoint 127.5, R / B overflow folded into the other channel, rounded at the
 * end. Alpha is left as decoded unless options->flags has DXVK_OPT_PREMULTIPLY.
 */
dxvk_status dxvk_blocks_to_rgba(const dxvk_frame_layout *layout, const void *const planes[2],
                                const dxvk_options *options, uint8_t *rgba, size_t stride);

/* ------------------------------------------------------------------------------------------------ */
/* QuickTime demuxer                                                                                */
/* ------------------------------------------------------------------------------------------------ */

typedef struct dxvk_mov dxvk_mov;

/* Random-access reader: read_at returns the number of bytes read (fewer only at end of data / error). */
typedef struct dxvk_reader {
    size_t (*read_at)(void *user, uint64_t offset, void *buffer, size_t size);
    uint64_t size;   /* total size of the data in bytes */
    void *user;
    void (*close)(void *user);  /* optional; called by dxvk_mov_close */
} dxvk_reader;

typedef struct dxvk_mov_info {
    dxvk_generation generation;
    uint32_t fourcc;               /* sample-entry data format, big-endian value ('DXD3' = 0x44584433) */
    uint32_t width, height;        /* display size */
    uint32_t frame_count;
    uint32_t timescale;            /* media timescale (units per second) */
    uint32_t frame_duration;       /* first stts delta, in timescale units (0 if none) */
    double frame_rate;             /* timescale / frame_duration, 0 if unknown */
    uint64_t duration;             /* media duration, timescale units */
    uint32_t max_packet_size;      /* largest sample, bytes */
    uint32_t track_id;
} dxvk_mov_info;

/* Opens a file by path (stdio). The object reads the file on demand; close it with dxvk_mov_close. */
dxvk_status dxvk_mov_open_file(const char *path, dxvk_mov **mov);
/* Opens an in-memory file. The memory must outlive the object. */
dxvk_status dxvk_mov_open_memory(const void *data, size_t size, dxvk_mov **mov);
/* Opens through a caller reader (copied; its close() runs on dxvk_mov_close, also on failure). */
dxvk_status dxvk_mov_open_reader(const dxvk_reader *reader, dxvk_mov **mov);
void dxvk_mov_close(dxvk_mov *mov);

const dxvk_mov_info *dxvk_mov_get_info(const dxvk_mov *mov);
/* Byte offset and size of a sample. */
dxvk_status dxvk_mov_packet_location(const dxvk_mov *mov, uint32_t index, uint64_t *offset,
                                     uint32_t *size);
/* Reads sample `index` into buffer (capacity bytes); *size = the packet size. One thread at a time per
 * dxvk_mov object. */
dxvk_status dxvk_mov_read_packet(dxvk_mov *mov, uint32_t index, void *buffer, size_t capacity,
                                 size_t *size);

/* ------------------------------------------------------------------------------------------------ */
/* Encoder                                                                                          */
/* ------------------------------------------------------------------------------------------------ */

/*
 * Effort: how hard the BCn block search and the match / opcode search work.
 *   FAST  live / batch: principal-axis BC1 with one refit, min / max BC4, single-entry match tables,
 *         one opcode pass with a fixed opcode-cost prior.
 *   BEST  archive: iterated BC1 refits + endpoint search (+ three-colour mode for DXT1), BC4 endpoint
 *         search in both modes, larger match tables, two opcode passes with measured opcode costs.
 */
typedef enum dxvk_effort {
    DXVK_EFFORT_FAST = 0,
    DXVK_EFFORT_BEST = 1
} dxvk_effort;

/* HQ opcode-stream coding. AUTO: per stream the smallest of FSE / stored / fill (what Resolume does).
 * STORED: stored / fill only (no entropy coding; larger, simpler). */
typedef enum dxvk_opcode_coding {
    DXVK_OPCODES_AUTO = 0,
    DXVK_OPCODES_STORED = 1
} dxvk_opcode_coding;

/* The input colour is premultiplied by alpha and is written as such. Without it the input is straight
 * (unpremultiplied) colour and is written straight, like Resolume Alley. The encoder never converts
 * between the two and the file has no field for the convention, so the packet bytes are the same
 * either way: the flag records which convention the caller's file carries (see the spec, 8.5). */
#define DXVK_ENC_PREMULTIPLIED_INPUT 0x1u
/* DXT1 / DXT5 only: write stored-flag packets (payload = the raw block stream). Valid per the format but
 * never seen in a real file; off by default. Rejected for YCG6 / YG10 (DXVK_ERR_UNSUPPORTED): the decoder
 * reads stored HQ packets since 1.0, the encoder does not write them. */
#define DXVK_ENC_STORED_PAYLOAD 0x2u

/* Encoder options. A zeroed struct (or NULL) = defaults: FAST, AUTO, straight input, single thread. */
typedef struct dxvk_encode_options {
    uint32_t flags;               /* DXVK_ENC_* */
    dxvk_effort effort;
    dxvk_opcode_coding opcodes;
    const dxvk_jobs *jobs;        /* NULL = single-threaded; output is identical either way */
} dxvk_encode_options;

typedef struct dxvk_encoder dxvk_encoder;

/* Largest packet the encoder can produce for a variant and display size (0 on bad arguments). */
size_t dxvk_encode_bound(dxvk_variant variant, uint32_t width, uint32_t height);

/*
 * Creates an encoder for one DXV3 variant (DXT1, DXT5, YCG6, YG10) and display size. All memory the
 * encoder needs is allocated here; encoding a frame allocates nothing. The options are copied (the jobs
 * runner pointer must stay valid). One thread at a time per encoder object.
 */
dxvk_status dxvk_encoder_create(dxvk_variant variant, uint32_t width, uint32_t height,
                                const dxvk_encode_options *options, dxvk_encoder **encoder);
void dxvk_encoder_destroy(dxvk_encoder *encoder);

/* The block-stream layout this encoder reads / writes (the same as dxvk_decode_blocks produces). */
const dxvk_frame_layout *dxvk_encoder_layout(const dxvk_encoder *encoder);

/*
 * RGBA8 (display size, rows top first, stride bytes per row) -> block planes in the decoder's layout
 * (plane 0 / plane 1 of dxvk_encoder_layout), padded to the coded size by edge replication.
 * DXT1 ignores alpha. YCG6 / YG10 (since 1.0, like Resolume Alley): the exact forward YCoCg transform
 * with chroma midpoint 127.5 and a 2 x 2 box average for chroma, unrounded into the BC4 encoder
 * (ENCODING_NOTES 5), so a grey 128 plays as 128 in Arena.
 */
dxvk_status dxvk_encoder_compress(dxvk_encoder *encoder, const uint8_t *rgba, size_t stride,
                                  void *const planes[2], const size_t plane_capacity[2]);

/*
 * Blocks-in path: block planes (any BCn encoder's output, in dxvk_encoder_layout's layout) -> one DXV3
 * packet. Lossless: decoding the packet returns exactly these planes. *packet_size = bytes written.
 */
dxvk_status dxvk_encoder_pack(dxvk_encoder *encoder, const void *const planes[2], void *packet,
                              size_t capacity, size_t *packet_size);

/* RGBA8 -> packet: dxvk_encoder_compress into the encoder's own planes, then dxvk_encoder_pack. */
dxvk_status dxvk_encoder_encode(dxvk_encoder *encoder, const uint8_t *rgba, size_t stride,
                                void *packet, size_t capacity, size_t *packet_size);

/* The planes of the last dxvk_encoder_encode (what was packed), or NULL before the first one. */
const void *dxvk_encoder_plane(const dxvk_encoder *encoder, int plane);

/* ------------------------------------------------------------------------------------------------ */
/* QuickTime writer (video only)                                                                    */
/* ------------------------------------------------------------------------------------------------ */

typedef struct dxvk_mov_writer dxvk_mov_writer;

/* Random-access sink: write_at returns the number of bytes written (fewer = error). */
typedef struct dxvk_sink {
    size_t (*write_at)(void *user, uint64_t offset, const void *data, size_t size);
    void *user;
    void (*close)(void *user);  /* optional; called by dxvk_mov_writer_close */
} dxvk_sink;

/*
 * Starts a .mov with one DXV3 ('DXD3') video track of the given display size. Frame rate =
 * timescale / frame_duration (e.g. 30000 / 1001). Packets are appended as they come; finish writes the
 * sample tables. Allocation: the sample-size / offset tables grow while packets are added.
 */
dxvk_status dxvk_mov_writer_open_file(const char *path, uint32_t width, uint32_t height,
                                      uint32_t timescale, uint32_t frame_duration,
                                      dxvk_mov_writer **writer);
dxvk_status dxvk_mov_writer_open_sink(const dxvk_sink *sink, uint32_t width, uint32_t height,
                                      uint32_t timescale, uint32_t frame_duration,
                                      dxvk_mov_writer **writer);
/* Appends one packet (one frame). Every packet of a file must have the same variant. */
dxvk_status dxvk_mov_writer_add(dxvk_mov_writer *writer, const void *packet, size_t size);
/* Writes the movie header and sample tables. The file is complete after this returns DXVK_OK. */
dxvk_status dxvk_mov_writer_finish(dxvk_mov_writer *writer);
/* Releases the writer (and closes the file / sink). Without finish the file is incomplete. */
void dxvk_mov_writer_close(dxvk_mov_writer *writer);

#ifdef __cplusplus
}
#endif

#endif /* DXVKIT_H */
