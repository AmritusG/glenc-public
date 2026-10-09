/*
 * DXVKit C++ wrapper: header-only RAII over dxvkit.h (decoder, encoder, MOV writer). No exceptions (every call returns a
 * dxvk_status), so it fits plugin code that is built without them.
 *
 *   dxvk::Movie movie;
 *   if (movie.open("clip.mov") != DXVK_OK) ...
 *   dxvk::Frame frame;                       // reusable; grows once, then no allocation
 *   movie.decode(n, frame);                  // block streams: frame.plane(0), frame.plane(1)
 *   frame.to_rgba(rgba, stride);             // optional CPU conversion (HQ: Arena's convention)
 *
 *   dxvk::Encoder enc;                       // encoder: RGBA8 or block planes -> DXV3 packet
 *   enc.create(DXVK_VARIANT_YCG6, 1920, 1080, &options);
 *   enc.encode(rgba, stride, packet);        // packet: std::vector<uint8_t>, resized to fit
 *   dxvk::MovWriter mov;                     // .mov with one DXD3 video track
 *   mov.open("out.mov", 1920, 1080, 30000, 1001); mov.add(packet); mov.finish();
 *
 * MIT License. Copyright (c) 2026 Amrit Rosell. See LICENSE.
 */
#ifndef DXVKIT_HPP
#define DXVKIT_HPP

#include "dxvkit.h"

#include <cstddef>
#include <cstdint>
#include <utility>
#include <vector>

namespace dxvk {

/* The linked library's version string ("1.0.0"); DXVKIT_VERSION is the header's. */
inline const char *version() { return dxvk_version_string(); }

/* Decoded frame: the block streams of the last decode plus its layout. Reuse it across frames. */
class Frame {
public:
    const dxvk_frame_layout &layout() const { return layout_; }
    int plane_count() const { return layout_.plane_count; }
    const uint8_t *plane(int i) const { return planes_[i].data(); }
    size_t plane_bytes(int i) const { return layout_.bytes[i]; }
    bool has_alpha() const { return dxvk_variant_has_alpha(layout_.variant) != 0; }

    /* Decodes a packet into this frame's buffers. */
    dxvk_status decode(dxvk_generation generation, const void *packet, size_t size, uint32_t width,
                       uint32_t height, const dxvk_options *options = nullptr)
    {
        dxvk_frame_layout big;
        dxvk_status st = dxvk_layout(DXVK_VARIANT_YG10, width, height, &big);
        if (st != DXVK_OK)
            return st;
        for (int i = 0; i < 2; i++)
            if (planes_[i].size() < big.bytes[i])
                planes_[i].resize(big.bytes[i]);
        void *planes[2] = {planes_[0].data(), planes_[1].data()};
        size_t caps[2] = {planes_[0].size(), planes_[1].size()};
        return dxvk_decode_blocks(generation, packet, size, width, height, options, planes, caps,
                                  &layout_, nullptr);
    }

    /* RGBA8 at the display size into caller memory (stride in bytes). */
    dxvk_status to_rgba(uint8_t *rgba, size_t stride, const dxvk_options *options = nullptr) const
    {
        const void *planes[2] = {planes_[0].data(), planes_[1].data()};
        return dxvk_blocks_to_rgba(&layout_, planes, options, rgba, stride);
    }

private:
    dxvk_frame_layout layout_{};
    std::vector<uint8_t> planes_[2];
};

/* An open DXV QuickTime file. Move-only; closes on destruction. One thread at a time per Movie. */
class Movie {
public:
    Movie() = default;
    ~Movie() { close(); }
    Movie(const Movie &) = delete;
    Movie &operator=(const Movie &) = delete;
    Movie(Movie &&o) noexcept : mov_(std::exchange(o.mov_, nullptr)), packet_(std::move(o.packet_)) {}
    Movie &operator=(Movie &&o) noexcept
    {
        if (this != &o) {
            close();
            mov_ = std::exchange(o.mov_, nullptr);
            packet_ = std::move(o.packet_);
        }
        return *this;
    }

    dxvk_status open(const char *path)
    {
        close();
        return dxvk_mov_open_file(path, &mov_);
    }
    dxvk_status open_memory(const void *data, size_t size)
    {
        close();
        return dxvk_mov_open_memory(data, size, &mov_);
    }
    void close()
    {
        dxvk_mov_close(mov_);
        mov_ = nullptr;
    }
    bool is_open() const { return mov_ != nullptr; }
    const dxvk_mov_info &info() const { return *dxvk_mov_get_info(mov_); }
    uint32_t frame_count() const { return mov_ ? info().frame_count : 0; }

    /* Reads packet `index` into `out` (resized to the packet size). */
    dxvk_status read_packet(uint32_t index, std::vector<uint8_t> &out)
    {
        if (!mov_)
            return DXVK_ERR_ARGUMENT;
        out.resize(info().max_packet_size);
        size_t n = 0;
        dxvk_status st = dxvk_mov_read_packet(mov_, index, out.data(), out.size(), &n);
        out.resize(st == DXVK_OK ? n : 0);
        return st;
    }

    /* Reads and decodes frame `index` into `frame`. */
    dxvk_status decode(uint32_t index, Frame &frame, const dxvk_options *options = nullptr)
    {
        dxvk_status st = read_packet(index, packet_);
        if (st != DXVK_OK)
            return st;
        const dxvk_mov_info &in = info();
        return frame.decode(in.generation, packet_.data(), packet_.size(), in.width, in.height,
                            options);
    }

    dxvk_mov *handle() const { return mov_; }

private:
    dxvk_mov *mov_ = nullptr;
    std::vector<uint8_t> packet_;
};

/* DXV3 encoder for one variant and frame size. Move-only; destroys on destruction. One thread at a time
 * per Encoder (use the options' jobs runner for parallelism inside a frame). */
class Encoder {
public:
    Encoder() = default;
    ~Encoder() { reset(); }
    Encoder(const Encoder &) = delete;
    Encoder &operator=(const Encoder &) = delete;
    Encoder(Encoder &&o) noexcept : enc_(std::exchange(o.enc_, nullptr)) {}
    Encoder &operator=(Encoder &&o) noexcept
    {
        if (this != &o) {
            reset();
            enc_ = std::exchange(o.enc_, nullptr);
        }
        return *this;
    }

    dxvk_status create(dxvk_variant variant, uint32_t width, uint32_t height,
                       const dxvk_encode_options *options = nullptr)
    {
        reset();
        return dxvk_encoder_create(variant, width, height, options, &enc_);
    }
    void reset()
    {
        dxvk_encoder_destroy(enc_);
        enc_ = nullptr;
    }
    bool is_open() const { return enc_ != nullptr; }
    const dxvk_frame_layout &layout() const { return *dxvk_encoder_layout(enc_); }
    size_t bound() const
    {
        const dxvk_frame_layout &l = layout();
        return dxvk_encode_bound(l.variant, l.display_width, l.display_height);
    }

    /* RGBA8 -> packet (resized to the packet size). */
    dxvk_status encode(const uint8_t *rgba, size_t stride, std::vector<uint8_t> &packet)
    {
        if (!enc_)
            return DXVK_ERR_ARGUMENT;
        packet.resize(bound());
        size_t n = 0;
        dxvk_status st = dxvk_encoder_encode(enc_, rgba, stride, packet.data(), packet.size(), &n);
        packet.resize(st == DXVK_OK ? n : 0);
        return st;
    }
    /* Blocks-in path: block planes in layout() -> packet. */
    dxvk_status pack(const void *plane0, const void *plane1, std::vector<uint8_t> &packet)
    {
        if (!enc_)
            return DXVK_ERR_ARGUMENT;
        packet.resize(bound());
        const void *planes[2] = {plane0, plane1};
        size_t n = 0;
        dxvk_status st = dxvk_encoder_pack(enc_, planes, packet.data(), packet.size(), &n);
        packet.resize(st == DXVK_OK ? n : 0);
        return st;
    }
    /* RGBA8 -> block planes only (sized by layout().bytes). */
    dxvk_status compress(const uint8_t *rgba, size_t stride, void *plane0, void *plane1)
    {
        if (!enc_)
            return DXVK_ERR_ARGUMENT;
        void *planes[2] = {plane0, plane1};
        return dxvk_encoder_compress(enc_, rgba, stride, planes, layout().bytes);
    }
    /* Planes packed by the last encode() (nullptr before). */
    const void *plane(int i) const { return dxvk_encoder_plane(enc_, i); }
    dxvk_encoder *handle() const { return enc_; }

private:
    dxvk_encoder *enc_ = nullptr;
};

/* Writes a .mov with one DXD3 video track. Move-only; closes on destruction (finish() first). */
class MovWriter {
public:
    MovWriter() = default;
    ~MovWriter() { close(); }
    MovWriter(const MovWriter &) = delete;
    MovWriter &operator=(const MovWriter &) = delete;
    MovWriter(MovWriter &&o) noexcept : w_(std::exchange(o.w_, nullptr)) {}
    MovWriter &operator=(MovWriter &&o) noexcept
    {
        if (this != &o) {
            close();
            w_ = std::exchange(o.w_, nullptr);
        }
        return *this;
    }

    dxvk_status open(const char *path, uint32_t width, uint32_t height, uint32_t timescale,
                     uint32_t frame_duration)
    {
        close();
        return dxvk_mov_writer_open_file(path, width, height, timescale, frame_duration, &w_);
    }
    dxvk_status add(const void *packet, size_t size)
    {
        return w_ ? dxvk_mov_writer_add(w_, packet, size) : DXVK_ERR_ARGUMENT;
    }
    dxvk_status add(const std::vector<uint8_t> &packet) { return add(packet.data(), packet.size()); }
    dxvk_status finish() { return w_ ? dxvk_mov_writer_finish(w_) : DXVK_ERR_ARGUMENT; }
    void close()
    {
        dxvk_mov_writer_close(w_);
        w_ = nullptr;
    }

private:
    dxvk_mov_writer *w_ = nullptr;
};

} // namespace dxvk

#endif /* DXVKIT_HPP */
