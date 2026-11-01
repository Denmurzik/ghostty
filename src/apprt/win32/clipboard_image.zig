//! Clipboard image codecs: CF_DIB / CF_DIBV5 <-> RGBA, PNG encoding, PNG
//! and JPEG decoding (through wuffs) and a small preview scaler. Pure
//! functions over bytes: no Win32 calls. A DIB read from the clipboard
//! comes from another program, so every size and offset in it is checked
//! against the block before it is used.
const std = @import("std");
const Allocator = std.mem.Allocator;
const wuffs = @import("wuffs");

/// Largest accepted image side, in pixels.
pub const max_side: u32 = 16384;
/// Largest RGBA buffer built from a DIB or handed to the PNG encoder.
pub const max_rgba_bytes: u64 = 256 * 1024 * 1024;
/// Largest RGBA buffer accepted from a PNG or JPEG decoder.
pub const max_decoded_bytes: u64 = 128 * 1024 * 1024;

pub const Error = Allocator.Error || error{
    /// The data is malformed or lies about its size.
    Invalid,
    /// A well-formed image in a format or depth we do not read.
    Unsupported,
    /// A side or the pixel count is over the limits above.
    TooLarge,
};

/// Straight (non-premultiplied) 8-bit RGBA, top row first.
pub const Rgba = struct {
    width: u32,
    height: u32,
    /// `width * height * 4` bytes: R, G, B, A.
    pixels: []u8,

    pub fn deinit(self: *Rgba, alloc: Allocator) void {
        alloc.free(self.pixels);
        self.* = undefined;
    }

    pub fn eql(a: Rgba, b: Rgba) bool {
        return a.width == b.width and a.height == b.height and
            std.mem.eql(u8, a.pixels, b.pixels);
    }
};

/// Premultiplied 8-bit BGRA, top row first (what GDI and the D3D11
/// swap chain expect for a bitmap with alpha).
pub const Bgra = struct {
    width: u32,
    height: u32,
    /// `width * height * 4` bytes: B, G, R, A.
    pixels: []u8,

    pub fn deinit(self: *Bgra, alloc: Allocator) void {
        alloc.free(self.pixels);
        self.* = undefined;
    }
};

fn rd16(b: []const u8, at: usize) u16 {
    return std.mem.readInt(u16, b[at..][0..2], .little);
}
fn rd32(b: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, b[at..][0..4], .little);
}
fn rdi32(b: []const u8, at: usize) i32 {
    return std.mem.readInt(i32, b[at..][0..4], .little);
}
fn wr16(b: []u8, at: usize, v: u16) void {
    std.mem.writeInt(u16, b[at..][0..2], v, .little);
}
fn wr32(b: []u8, at: usize, v: u32) void {
    std.mem.writeInt(u32, b[at..][0..4], v, .little);
}

const bi_rgb = 0;
const bi_bitfields = 3;

const info_header_size = 40;
const v4_header_size = 108;
const v5_header_size = 124;

const Channel = struct {
    shift: u5,
    max: u32,

    /// A mask must be one run of ones; zero means "no such channel".
    fn fromMask(mask: u32) error{Invalid}!?Channel {
        if (mask == 0) return null;
        const shift: u5 = @intCast(@ctz(mask));
        const run = mask >> shift;
        if (run & (run +% 1) != 0) return error.Invalid;
        return .{ .shift = shift, .max = run };
    }

    fn extract(self: Channel, px: u32) u8 {
        const v: u64 = (px >> self.shift) & self.max;
        if (self.max == 255) return @intCast(v);
        return @intCast((v * 255 + self.max / 2) / self.max);
    }
};

/// The four channels of a 32 bpp `BI_BITFIELDS` image.
const Layout = struct {
    r: Channel,
    g: Channel,
    b: Channel,
    a: ?Channel,

    fn fromMasks(r_mask: u32, g_mask: u32, b_mask: u32, a_mask: u32) error{Invalid}!Layout {
        if ((r_mask & g_mask) | (r_mask & b_mask) | (g_mask & b_mask) | (a_mask & (r_mask | g_mask | b_mask)) != 0)
            return error.Invalid;
        return .{
            .r = (try Channel.fromMask(r_mask)) orelse return error.Invalid,
            .g = (try Channel.fromMask(g_mask)) orelse return error.Invalid,
            .b = (try Channel.fromMask(b_mask)) orelse return error.Invalid,
            .a = try Channel.fromMask(a_mask),
        };
    }
};

/// Decodes a packed DIB (a BITMAPINFOHEADER, BITMAPV4HEADER or
/// BITMAPV5HEADER followed by optional masks, a colour table and the
/// pixels, as stored in CF_DIB / CF_DIBV5) of 24 or 32 bits per pixel,
/// `BI_RGB` or `BI_BITFIELDS`. A 32 bpp `BI_RGB` image whose alpha bytes
/// are all zero is taken as opaque. The caller owns the result.
pub fn fromDib(alloc: Allocator, block: []const u8) Error!Rgba {
    if (block.len < info_header_size) return error.Invalid;
    const hdr_size = rd32(block, 0);
    switch (hdr_size) {
        info_header_size, v4_header_size, v5_header_size => {},
        else => return error.Unsupported,
    }
    if (block.len < hdr_size) return error.Invalid;

    const width_i = rdi32(block, 4);
    const height_i = rdi32(block, 8);
    const bpp = rd16(block, 14);
    const compression = rd32(block, 16);
    const clr_used = rd32(block, 32);

    if (bpp != 24 and bpp != 32) return error.Unsupported;
    if (compression != bi_rgb and compression != bi_bitfields) return error.Unsupported;
    if (bpp == 24 and compression != bi_rgb) return error.Unsupported;
    if (width_i <= 0 or height_i == 0) return error.Invalid;

    const width: u32 = @intCast(width_i);
    const height: u32 = @abs(height_i); // minInt(i32) -> 2^31, caught below
    const top_down = height_i < 0;
    if (width > max_side or height > max_side) return error.TooLarge;
    const out_len: u64 = @as(u64, width) * height * 4;
    if (out_len > max_rgba_bytes) return error.TooLarge;

    // Channel layout. BI_RGB 32 bpp is B, G, R, A in memory.
    var r_mask: u32 = 0x00FF0000;
    var g_mask: u32 = 0x0000FF00;
    var b_mask: u32 = 0x000000FF;
    var a_mask: u32 = 0xFF000000;
    var data_at: u64 = hdr_size;
    var alpha_zero_means_opaque = bpp == 32;
    if (bpp == 32 and compression == bi_bitfields) {
        alpha_zero_means_opaque = false;
        if (hdr_size == info_header_size) {
            // Three mask DWORDs follow the header; there is no alpha mask.
            if (block.len < info_header_size + 12) return error.Invalid;
            r_mask = rd32(block, 40);
            g_mask = rd32(block, 44);
            b_mask = rd32(block, 48);
            a_mask = 0;
            data_at += 12;
        } else {
            r_mask = rd32(block, 40);
            g_mask = rd32(block, 44);
            b_mask = rd32(block, 48);
            a_mask = rd32(block, 52);
        }
    }
    data_at += @as(u64, clr_used) * 4;

    const stride: u64 = ((@as(u64, width) * bpp + 31) / 32) * 4;
    const need: u64 = stride * height;
    if (data_at > block.len or need > block.len - data_at) return error.Invalid;
    const data: []const u8 = block[@intCast(data_at)..][0..@intCast(need)];

    // A lying mask costs nothing: validate before allocating.
    const lay: Layout = if (bpp == 32)
        try Layout.fromMasks(r_mask, g_mask, b_mask, a_mask)
    else
        undefined;

    const stride_us: usize = @intCast(stride);
    const out = try alloc.alloc(u8, @intCast(out_len));
    errdefer alloc.free(out);

    if (bpp == 24) {
        var y: usize = 0;
        while (y < height) : (y += 1) {
            const src_y = if (top_down) y else height - 1 - y;
            const src = data[src_y * stride_us ..][0 .. @as(usize, width) * 3];
            const dst = out[y * @as(usize, width) * 4 ..][0 .. @as(usize, width) * 4];
            for (0..width) |x| {
                dst[x * 4 + 0] = src[x * 3 + 2];
                dst[x * 4 + 1] = src[x * 3 + 1];
                dst[x * 4 + 2] = src[x * 3 + 0];
                dst[x * 4 + 3] = 255;
            }
        }
        return .{ .width = width, .height = height, .pixels = out };
    }

    const rc = lay.r;
    const gc = lay.g;
    const bc = lay.b;
    const ac = lay.a;

    var any_alpha = false;
    var y: usize = 0;
    while (y < height) : (y += 1) {
        const src_y = if (top_down) y else height - 1 - y;
        const src = data[src_y * stride_us ..][0 .. @as(usize, width) * 4];
        const dst = out[y * @as(usize, width) * 4 ..][0 .. @as(usize, width) * 4];
        for (0..width) |x| {
            const px = rd32(src, x * 4);
            dst[x * 4 + 0] = rc.extract(px);
            dst[x * 4 + 1] = gc.extract(px);
            dst[x * 4 + 2] = bc.extract(px);
            const a: u8 = if (ac) |c| c.extract(px) else 255;
            if (a != 0) any_alpha = true;
            dst[x * 4 + 3] = a;
        }
    }
    if (alpha_zero_means_opaque and !any_alpha) {
        var i: usize = 3;
        while (i < out.len) : (i += 4) out[i] = 255;
    }
    return .{ .width = width, .height = height, .pixels = out };
}

/// Encodes `img` as a packed CF_DIBV5 block: a BITMAPV5HEADER
/// (`BI_BITFIELDS`, B/G/R/A masks, `LCS_sRGB`) followed by bottom-up
/// 32 bpp BGRA pixels with straight alpha. The caller owns the result.
pub fn toDibV5(alloc: Allocator, img: Rgba) Error![]u8 {
    if (img.width == 0 or img.height == 0) return error.Invalid;
    if (img.width > max_side or img.height > max_side) return error.TooLarge;
    const px_len: u64 = @as(u64, img.width) * img.height * 4;
    if (px_len > max_rgba_bytes) return error.TooLarge;
    if (img.pixels.len != px_len) return error.Invalid;

    const px_len_us: usize = @intCast(px_len);
    const out = try alloc.alloc(u8, v5_header_size + px_len_us);
    errdefer alloc.free(out);
    @memset(out[0..v5_header_size], 0);

    wr32(out, 0, v5_header_size);
    wr32(out, 4, img.width);
    wr32(out, 8, img.height); // positive: bottom-up
    wr16(out, 12, 1);
    wr16(out, 14, 32);
    wr32(out, 16, bi_bitfields);
    wr32(out, 20, @intCast(px_len));
    wr32(out, 40, 0x00FF0000);
    wr32(out, 44, 0x0000FF00);
    wr32(out, 48, 0x000000FF);
    wr32(out, 52, 0xFF000000);
    wr32(out, 56, 0x73524742); // LCS_sRGB, 'sRGB'
    wr32(out, 108, 4); // LCS_GM_IMAGES

    const w: usize = img.width;
    const h: usize = img.height;
    const dst = out[v5_header_size..];
    for (0..h) |y| {
        const src_row = img.pixels[y * w * 4 ..][0 .. w * 4];
        const dst_row = dst[(h - 1 - y) * w * 4 ..][0 .. w * 4];
        for (0..w) |x| {
            dst_row[x * 4 + 0] = src_row[x * 4 + 2];
            dst_row[x * 4 + 1] = src_row[x * 4 + 1];
            dst_row[x * 4 + 2] = src_row[x * 4 + 0];
            dst_row[x * 4 + 3] = src_row[x * 4 + 3];
        }
    }
    return out;
}

fn appendChunk(
    alloc: Allocator,
    out: *std.ArrayList(u8),
    kind: *const [4]u8,
    data: []const u8,
) Allocator.Error!void {
    var len: [4]u8 = undefined;
    std.mem.writeInt(u32, &len, @intCast(data.len), .big);
    try out.appendSlice(alloc, &len);
    try out.appendSlice(alloc, kind);
    try out.appendSlice(alloc, data);
    var crc = std.hash.Crc32.init();
    crc.update(kind);
    crc.update(data);
    var tail: [4]u8 = undefined;
    std.mem.writeInt(u32, &tail, crc.final(), .big);
    try out.appendSlice(alloc, &tail);
}

/// Encodes `img` as a PNG: 8-bit RGBA (colour type 6), filter 0 on every
/// row, one IDAT chunk holding a zlib stream at the fastest level. The
/// caller owns the result.
pub fn encodePng(alloc: Allocator, img: Rgba) Error![]u8 {
    if (img.width == 0 or img.height == 0) return error.Invalid;
    if (img.width > max_side or img.height > max_side) return error.TooLarge;
    const px_len: u64 = @as(u64, img.width) * img.height * 4;
    if (px_len > max_rgba_bytes) return error.TooLarge;
    if (img.pixels.len != px_len) return error.Invalid;

    const w: usize = img.width;
    const h: usize = img.height;

    // The zlib stream of `filter byte + row` for every row.
    var zout = try std.Io.Writer.Allocating.initCapacity(alloc, 4096);
    defer zout.deinit();
    {
        const window = try alloc.alloc(u8, std.compress.flate.max_window_len);
        defer alloc.free(window);
        var comp = std.compress.flate.Compress.init(
            &zout.writer,
            window,
            .zlib,
            std.compress.flate.Compress.Options.fastest,
        ) catch return error.OutOfMemory;
        for (0..h) |y| {
            comp.writer.writeAll(&.{0}) catch return error.OutOfMemory;
            comp.writer.writeAll(img.pixels[y * w * 4 ..][0 .. w * 4]) catch return error.OutOfMemory;
        }
        comp.finish() catch return error.OutOfMemory;
    }
    const zdata = zout.written();
    // A chunk length is a 31-bit value.
    if (zdata.len > std.math.maxInt(i32)) return error.TooLarge;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.ensureTotalCapacity(alloc, 8 + 25 + 12 + zdata.len + 12);

    out.appendSliceAssumeCapacity("\x89PNG\r\n\x1a\n");

    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], img.width, .big);
    std.mem.writeInt(u32, ihdr[4..8], img.height, .big);
    ihdr[8] = 8; // bit depth
    ihdr[9] = 6; // colour type: RGBA
    ihdr[10] = 0; // compression
    ihdr[11] = 0; // filter method
    ihdr[12] = 0; // no interlace
    try appendChunk(alloc, &out, "IHDR", &ihdr);
    try appendChunk(alloc, &out, "IDAT", zdata);
    try appendChunk(alloc, &out, "IEND", "");

    return out.toOwnedSlice(alloc);
}

fn baseMime(mime: []const u8) []const u8 {
    const semi = std.mem.indexOfScalar(u8, mime, ';') orelse mime.len;
    return std.mem.trim(u8, mime[0..semi], " \t");
}

/// Refuses a PNG whose IHDR announces more than the decode budget for the
/// RGBA result. wuffs' work buffer (a filter byte plus one source row per
/// row, so at most about twice the result for 16-bit RGBA) comes on top:
/// peak memory is about three times the cap. Data that is not even a PNG
/// header is left to the decoder to reject.
fn checkPngHeader(data: []const u8) error{TooLarge}!void {
    if (data.len < 24 or !std.mem.eql(u8, data[0..8], "\x89PNG\r\n\x1a\n")) return;
    // IHDR is the first chunk: width and height at 16 and 20.
    const w: u64 = std.mem.readInt(u32, data[16..20], .big);
    const h: u64 = std.mem.readInt(u32, data[20..24], .big);
    if (w * h * 4 > max_decoded_bytes) return error.TooLarge;
}

const JpegDims = struct { width: u32, height: u32 };

/// Reads the frame size from the first SOFn segment of a JPEG without
/// decoding anything. Walks at most a bounded number of segments and
/// never reads past `data`.
fn jpegDimensions(data: []const u8) error{Invalid}!JpegDims {
    if (data.len < 4 or data[0] != 0xFF or data[1] != 0xD8) return error.Invalid;

    var pos: usize = 2;
    var segments: usize = 0;
    while (segments < 1024) : (segments += 1) {
        // Skip fill bytes, then read the marker.
        if (pos >= data.len or data[pos] != 0xFF) return error.Invalid;
        while (pos < data.len and data[pos] == 0xFF) pos += 1;
        if (pos >= data.len) return error.Invalid;
        const marker = data[pos];
        pos += 1;

        switch (marker) {
            // Stuffed zero, TEM, RSTn, SOI: no length.
            0x00, 0x01, 0xD0...0xD8 => continue,
            // EOI, or the scan starts before any frame header.
            0xD9, 0xDA => return error.Invalid,
            else => {},
        }

        if (data.len - pos < 2) return error.Invalid;
        const seg_len = std.mem.readInt(u16, data[pos..][0..2], .big);
        if (seg_len < 2 or data.len - pos < seg_len) return error.Invalid;

        const is_sof = marker >= 0xC0 and marker <= 0xCF and
            marker != 0xC4 and marker != 0xC8 and marker != 0xCC;
        if (is_sof) {
            // length(2) precision(1) height(2) width(2)
            if (seg_len < 8) return error.Invalid;
            return .{
                .height = std.mem.readInt(u16, data[pos + 3 ..][0..2], .big),
                .width = std.mem.readInt(u16, data[pos + 5 ..][0..2], .big),
            };
        }
        pos += seg_len;
    }
    return error.Invalid;
}

/// Decodes an `image/png` or `image/jpeg` payload to RGBA. Anything else
/// is `error.Unsupported`; a result over 128 MiB is `error.TooLarge`
/// (a PNG whose header already announces that is refused before the
/// decoder allocates anything). The caller owns the result.
pub fn decode(alloc: Allocator, mime: []const u8, data: []const u8) Error!Rgba {
    const base = baseMime(mime);
    const is_png = std.ascii.eqlIgnoreCase(base, "image/png");
    const is_jpeg = std.ascii.eqlIgnoreCase(base, "image/jpeg");
    if (!is_png and !is_jpeg) return error.Unsupported;

    // wuffs allocates the whole result (up to 4 GiB) before we could look
    // at it, so the announced size is checked from the headers first.
    if (is_png) {
        try checkPngHeader(data);
    } else {
        const dims = try jpegDimensions(data);
        if (@as(u64, dims.width) * dims.height * 4 > max_decoded_bytes) return error.TooLarge;
    }

    const decoded = (if (is_png) wuffs.png.decode(alloc, data) else wuffs.jpeg.decode(alloc, data)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Invalid,
    };
    errdefer alloc.free(decoded.data);

    const expect: u64 = @as(u64, decoded.width) * decoded.height * 4;
    if (expect > max_decoded_bytes) return error.TooLarge;
    if (decoded.data.len != expect) return error.Invalid;
    return .{ .width = decoded.width, .height = decoded.height, .pixels = decoded.data };
}

/// Scales `img` down to fit inside `max_w` x `max_h` (never up) with a box
/// filter, keeping the aspect ratio, and returns premultiplied BGRA. The
/// caller owns the result.
pub fn preview(alloc: Allocator, img: Rgba, max_w: u32, max_h: u32) Error!Bgra {
    if (img.width == 0 or img.height == 0 or max_w == 0 or max_h == 0) return error.Invalid;
    if (img.width > max_side or img.height > max_side) return error.TooLarge;
    const px_len: u64 = @as(u64, img.width) * img.height * 4;
    if (px_len > max_rgba_bytes) return error.TooLarge;
    if (img.pixels.len != px_len) return error.Invalid;

    const sw: u64 = img.width;
    const sh: u64 = img.height;
    var ow: u64 = sw;
    var oh: u64 = sh;
    if (sw > max_w or sh > max_h) {
        if (sw * max_h >= sh * max_w) {
            // Width is the tighter side.
            ow = max_w;
            oh = @max(1, sh * max_w / sw);
        } else {
            oh = max_h;
            ow = @max(1, sw * max_h / sh);
        }
    }

    const out = try alloc.alloc(u8, @intCast(ow * oh * 4));
    errdefer alloc.free(out);

    const src_w: usize = img.width;
    for (0..@as(usize, @intCast(oh))) |oy| {
        const y0: usize = @intCast(oy * sh / oh);
        const y1: usize = @max(y0 + 1, @as(usize, @intCast((oy + 1) * sh / oh)));
        for (0..@as(usize, @intCast(ow))) |ox| {
            const x0: usize = @intCast(ox * sw / ow);
            const x1: usize = @max(x0 + 1, @as(usize, @intCast((ox + 1) * sw / ow)));

            // Average colour weighted by alpha, which is the same as
            // averaging premultiplied values.
            var sum_r: u64 = 0;
            var sum_g: u64 = 0;
            var sum_b: u64 = 0;
            var sum_a: u64 = 0;
            for (y0..y1) |y| {
                const row = img.pixels[y * src_w * 4 ..][0 .. src_w * 4];
                for (x0..x1) |x| {
                    const a: u64 = row[x * 4 + 3];
                    sum_r += @as(u64, row[x * 4 + 0]) * a;
                    sum_g += @as(u64, row[x * 4 + 1]) * a;
                    sum_b += @as(u64, row[x * 4 + 2]) * a;
                    sum_a += a;
                }
            }
            const count: u64 = (y1 - y0) * (x1 - x0);
            const div = 255 * count;
            const dst = out[(oy * @as(usize, @intCast(ow)) + ox) * 4 ..][0..4];
            dst[0] = @intCast((sum_b + div / 2) / div);
            dst[1] = @intCast((sum_g + div / 2) / div);
            dst[2] = @intCast((sum_r + div / 2) / div);
            dst[3] = @intCast((sum_a + count / 2) / count);
        }
    }
    return .{ .width = @intCast(ow), .height = @intCast(oh), .pixels = out };
}

// -- tests ----------------------------------------------------------------

/// Builds a BITMAPINFOHEADER-based DIB for the tests.
fn testDib(
    alloc: Allocator,
    width: i32,
    height: i32,
    bpp: u16,
    compression: u32,
    masks: ?[3]u32,
    pixels: []const u8,
) ![]u8 {
    const extra: usize = if (masks != null) 12 else 0;
    const out = try alloc.alloc(u8, info_header_size + extra + pixels.len);
    @memset(out[0..info_header_size], 0);
    wr32(out, 0, info_header_size);
    std.mem.writeInt(i32, out[4..8], width, .little);
    std.mem.writeInt(i32, out[8..12], height, .little);
    wr16(out, 12, 1);
    wr16(out, 14, bpp);
    wr32(out, 16, compression);
    if (masks) |m| {
        wr32(out, 40, m[0]);
        wr32(out, 44, m[1]);
        wr32(out, 48, m[2]);
    }
    @memcpy(out[info_header_size + extra ..], pixels);
    return out;
}

test "win32 clipboard image: dib 24 and 32 bpp" {
    const alloc = std.testing.allocator;

    // 2x2 bottom-up 24 bpp. Row stride is 6 bytes padded to 8.
    // Bottom row first: (blue, white), then (red, green).
    {
        const px = [_]u8{
            // bottom row (y = 1 in the image): blue, white
            255, 0, 0,   255, 255, 255, 0, 0,
            // top row (y = 0): red, green
            0,   0, 255, 0,   255, 0,   0, 0,
        };
        const dib = try testDib(alloc, 2, 2, 24, bi_rgb, null, &px);
        defer alloc.free(dib);
        var img = try fromDib(alloc, dib);
        defer img.deinit(alloc);
        try std.testing.expectEqual(@as(u32, 2), img.width);
        try std.testing.expectEqual(@as(u32, 2), img.height);
        try std.testing.expectEqualSlices(u8, &.{
            255, 0, 0,   255, 0,   255, 0,   255,
            0,   0, 255, 255, 255, 255, 255, 255,
        }, img.pixels);
    }

    // 2x2 top-down 32 bpp BI_BITFIELDS (BGRA masks in the 40-byte header
    // form would carry no alpha, so use the V4 header with an alpha mask).
    {
        var dib: [v4_header_size + 16]u8 = undefined;
        @memset(&dib, 0);
        wr32(&dib, 0, v4_header_size);
        std.mem.writeInt(i32, dib[4..8], 2, .little);
        std.mem.writeInt(i32, dib[8..12], -2, .little);
        wr16(&dib, 12, 1);
        wr16(&dib, 14, 32);
        wr32(&dib, 16, bi_bitfields);
        wr32(&dib, 40, 0x00FF0000);
        wr32(&dib, 44, 0x0000FF00);
        wr32(&dib, 48, 0x000000FF);
        wr32(&dib, 52, 0xFF000000);
        const px = [_]u8{
            10, 20, 30, 40,  50, 60, 70, 0, // (30,20,10,40) (70,60,50,0)
            1,  2,  3,  255, 0,  0,  0,  128,
        };
        @memcpy(dib[v4_header_size..], &px);
        var img = try fromDib(alloc, &dib);
        defer img.deinit(alloc);
        try std.testing.expectEqualSlices(u8, &.{
            30, 20, 10, 40,  70, 60, 50, 0,
            3,  2,  1,  255, 0,  0,  0,  128,
        }, img.pixels);
    }

    // The 40-byte header with three mask DWORDs (RGB565-free 8-8-8 here):
    // alpha is absent, so opaque.
    {
        const px = [_]u8{ 9, 8, 7, 0 };
        const dib = try testDib(alloc, 1, 1, 32, bi_bitfields, .{ 0x00FF0000, 0x0000FF00, 0x000000FF }, &px);
        defer alloc.free(dib);
        var img = try fromDib(alloc, dib);
        defer img.deinit(alloc);
        try std.testing.expectEqualSlices(u8, &.{ 7, 8, 9, 255 }, img.pixels);
    }

    // BI_RGB 32 bpp, all alpha bytes zero: opaque. One non-zero alpha
    // byte keeps the alpha as stored.
    {
        const zero = [_]u8{ 1, 2, 3, 0, 4, 5, 6, 0 };
        const dib = try testDib(alloc, 2, 1, 32, bi_rgb, null, &zero);
        defer alloc.free(dib);
        var img = try fromDib(alloc, dib);
        defer img.deinit(alloc);
        try std.testing.expectEqualSlices(u8, &.{ 3, 2, 1, 255, 6, 5, 4, 255 }, img.pixels);

        const some = [_]u8{ 1, 2, 3, 0, 4, 5, 6, 77 };
        const dib2 = try testDib(alloc, 2, 1, 32, bi_rgb, null, &some);
        defer alloc.free(dib2);
        var img2 = try fromDib(alloc, dib2);
        defer img2.deinit(alloc);
        try std.testing.expectEqualSlices(u8, &.{ 3, 2, 1, 0, 6, 5, 4, 77 }, img2.pixels);
    }

    // A colour table (clr_used) before the pixels is skipped.
    {
        var px: [8 + 4]u8 = undefined;
        @memset(px[0..8], 0xEE); // two table entries
        @memcpy(px[8..], &[_]u8{ 1, 2, 3, 255 });
        const dib = try testDib(alloc, 1, 1, 32, bi_rgb, null, &px);
        defer alloc.free(dib);
        wr32(dib, 32, 2);
        var img = try fromDib(alloc, dib);
        defer img.deinit(alloc);
        try std.testing.expectEqualSlices(u8, &.{ 3, 2, 1, 255 }, img.pixels);
    }

    // 5-6-5 style narrow masks scale to the full range.
    {
        var dib: [info_header_size + 12 + 4]u8 = undefined;
        @memset(&dib, 0);
        wr32(&dib, 0, info_header_size);
        std.mem.writeInt(i32, dib[4..8], 1, .little);
        std.mem.writeInt(i32, dib[8..12], 1, .little);
        wr16(&dib, 12, 1);
        wr16(&dib, 14, 32);
        wr32(&dib, 16, bi_bitfields);
        wr32(&dib, 40, 0xF800);
        wr32(&dib, 44, 0x07E0);
        wr32(&dib, 48, 0x001F);
        wr32(&dib, 52, 0xFFFF); // r = 31, g = 63, b = 31
        var img = try fromDib(alloc, &dib);
        defer img.deinit(alloc);
        try std.testing.expectEqualSlices(u8, &.{ 255, 255, 255, 255 }, img.pixels);
    }
}

test "win32 clipboard image: dib rejects lies" {
    const alloc = std.testing.allocator;
    const px = [_]u8{ 1, 2, 3, 255 };

    // Claims 100x100 but carries one pixel.
    {
        const dib = try testDib(alloc, 100, 100, 32, bi_rgb, null, &px);
        defer alloc.free(dib);
        try std.testing.expectError(error.Invalid, fromDib(alloc, dib));
    }
    // Stride arithmetic that would overflow 32 bits.
    {
        const dib = try testDib(alloc, 16384, 16384, 32, bi_rgb, null, &px);
        defer alloc.free(dib);
        try std.testing.expectError(error.TooLarge, fromDib(alloc, dib));
    }
    // Over the 128 Mpixel... 256 MiB RGBA budget with a legal side.
    {
        const dib = try testDib(alloc, 16000, 5000, 32, bi_rgb, null, &px);
        defer alloc.free(dib);
        try std.testing.expectError(error.TooLarge, fromDib(alloc, dib));
    }
    // Sides over the limit.
    {
        const dib = try testDib(alloc, 16385, 1, 32, bi_rgb, null, &px);
        defer alloc.free(dib);
        try std.testing.expectError(error.TooLarge, fromDib(alloc, dib));
        const dib2 = try testDib(alloc, std.math.maxInt(i32), 1, 32, bi_rgb, null, &px);
        defer alloc.free(dib2);
        try std.testing.expectError(error.TooLarge, fromDib(alloc, dib2));
    }
    // Unsupported depths.
    inline for (.{ 1, 4, 8, 16 }) |bpp| {
        const dib = try testDib(alloc, 1, 1, bpp, bi_rgb, null, &px);
        defer alloc.free(dib);
        try std.testing.expectError(error.Unsupported, fromDib(alloc, dib));
    }
    // Zero or negative width, zero height.
    {
        const dib = try testDib(alloc, 0, 1, 32, bi_rgb, null, &px);
        defer alloc.free(dib);
        try std.testing.expectError(error.Invalid, fromDib(alloc, dib));
        const dib2 = try testDib(alloc, -3, 1, 32, bi_rgb, null, &px);
        defer alloc.free(dib2);
        try std.testing.expectError(error.Invalid, fromDib(alloc, dib2));
        const dib3 = try testDib(alloc, 1, 0, 32, bi_rgb, null, &px);
        defer alloc.free(dib3);
        try std.testing.expectError(error.Invalid, fromDib(alloc, dib3));
    }
    // minInt(i32) height must not trap on negation.
    {
        const dib = try testDib(alloc, 1, std.math.minInt(i32), 32, bi_rgb, null, &px);
        defer alloc.free(dib);
        try std.testing.expectError(error.TooLarge, fromDib(alloc, dib));
    }
    // A colour table that points past the block.
    {
        const dib = try testDib(alloc, 1, 1, 32, bi_rgb, null, &px);
        defer alloc.free(dib);
        wr32(dib, 32, std.math.maxInt(u32));
        try std.testing.expectError(error.Invalid, fromDib(alloc, dib));
    }
    // Bad masks: zero, overlapping, with a hole.
    {
        const bad = [_][3]u32{
            .{ 0, 0x0000FF00, 0x000000FF },
            .{ 0x00FF0000, 0x00FF0000, 0x000000FF },
            .{ 0x00FF00FF, 0x0000FF00, 0x00000001 },
        };
        for (bad) |m| {
            const dib = try testDib(alloc, 1, 1, 32, bi_bitfields, m, &px);
            defer alloc.free(dib);
            try std.testing.expectError(error.Invalid, fromDib(alloc, dib));
        }
    }
    // Truncated and unknown headers.
    {
        try std.testing.expectError(error.Invalid, fromDib(alloc, ""));
        try std.testing.expectError(error.Invalid, fromDib(alloc, &@as([39]u8, @splat(0))));
        var h: [40]u8 = @splat(0);
        wr32(&h, 0, 12);
        try std.testing.expectError(error.Unsupported, fromDib(alloc, &h));
        wr32(&h, 0, 124); // claims a V5 header in a 40 byte block
        try std.testing.expectError(error.Invalid, fromDib(alloc, &h));
        wr32(&h, 0, 0xFFFFFFFF);
        try std.testing.expectError(error.Unsupported, fromDib(alloc, &h));
    }
    // Compressed or otherwise exotic compression.
    {
        const dib = try testDib(alloc, 1, 1, 32, 1, null, &px); // BI_RLE8
        defer alloc.free(dib);
        try std.testing.expectError(error.Unsupported, fromDib(alloc, dib));
        const dib2 = try testDib(alloc, 1, 1, 24, bi_bitfields, null, &px);
        defer alloc.free(dib2);
        try std.testing.expectError(error.Unsupported, fromDib(alloc, dib2));
    }
    // The 40-byte header says BI_BITFIELDS but the masks are cut off.
    {
        var dib: [info_header_size + 8]u8 = @splat(0);
        wr32(&dib, 0, info_header_size);
        wr32(&dib, 4, 1);
        wr32(&dib, 8, 1);
        wr16(&dib, 14, 32);
        wr32(&dib, 16, bi_bitfields);
        try std.testing.expectError(error.Invalid, fromDib(alloc, &dib));
    }
}

fn testImage(alloc: Allocator, w: u32, h: u32) !Rgba {
    const px = try alloc.alloc(u8, @as(usize, w) * h * 4);
    var seed: u32 = 12345;
    for (px, 0..) |*b, i| {
        seed = seed *% 1664525 +% 1013904223;
        b.* = if (i % 7 == 0) 0 else @truncate(seed >> 24);
    }
    return .{ .width = w, .height = h, .pixels = px };
}

test "win32 clipboard image: dibv5 roundtrip" {
    const alloc = std.testing.allocator;
    for ([_][2]u32{ .{ 1, 1 }, .{ 3, 2 }, .{ 5, 7 }, .{ 64, 3 } }) |dim| {
        var img = try testImage(alloc, dim[0], dim[1]);
        defer img.deinit(alloc);
        // Make sure a fully transparent pixel survives.
        @memset(img.pixels[0..4], 0);

        const dib = try toDibV5(alloc, img);
        defer alloc.free(dib);
        try std.testing.expectEqual(@as(usize, v5_header_size) + img.pixels.len, dib.len);
        try std.testing.expectEqual(@as(u32, v5_header_size), rd32(dib, 0));
        try std.testing.expectEqual(@as(u32, bi_bitfields), rd32(dib, 16));
        try std.testing.expectEqual(@as(u32, 0x73524742), rd32(dib, 56));

        var back = try fromDib(alloc, dib);
        defer back.deinit(alloc);
        try std.testing.expect(img.eql(back));
    }

    // Bottom-up: the first stored row is the last image row.
    {
        var img = try testImage(alloc, 1, 2);
        defer img.deinit(alloc);
        const dib = try toDibV5(alloc, img);
        defer alloc.free(dib);
        try std.testing.expectEqual(img.pixels[4 + 2], dib[v5_header_size]); // B of row 1
        try std.testing.expectEqual(img.pixels[4 + 0], dib[v5_header_size + 2]); // R of row 1
    }

    // A pixel buffer of the wrong length is refused.
    {
        var bad: Rgba = .{ .width = 2, .height = 2, .pixels = try alloc.alloc(u8, 15) };
        defer bad.deinit(alloc);
        try std.testing.expectError(error.Invalid, toDibV5(alloc, bad));
        try std.testing.expectError(error.Invalid, encodePng(alloc, bad));
    }
}

test "win32 clipboard image: png encode decodes with wuffs" {
    const alloc = std.testing.allocator;
    for ([_][2]u32{ .{ 1, 1 }, .{ 3, 2 }, .{ 257, 3 }, .{ 300, 300 } }) |dim| {
        var img = try testImage(alloc, dim[0], dim[1]);
        defer img.deinit(alloc);

        const png = try encodePng(alloc, img);
        defer alloc.free(png);
        try std.testing.expectEqualSlices(u8, "\x89PNG\r\n\x1a\n", png[0..8]);
        try std.testing.expectEqualSlices(u8, "IEND", png[png.len - 8 .. png.len - 4]);

        const dec = try wuffs.png.decode(alloc, png);
        defer alloc.free(dec.data);
        try std.testing.expectEqual(dim[0], dec.width);
        try std.testing.expectEqual(dim[1], dec.height);
        try std.testing.expectEqualSlices(u8, img.pixels, dec.data);

        // And through our own decode().
        var back = try decode(alloc, "image/png", png);
        defer back.deinit(alloc);
        try std.testing.expect(img.eql(back));
    }
}

test "win32 clipboard image: decode limits" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.Unsupported, decode(alloc, "image/gif", "GIF89a"));
    try std.testing.expectError(error.Unsupported, decode(alloc, "text/plain", ""));
    try std.testing.expectError(error.Invalid, decode(alloc, "image/png", "not a png"));
    try std.testing.expectError(error.Invalid, decode(alloc, "image/jpeg", "not a jpeg"));
    try std.testing.expectError(error.Invalid, decode(alloc, "IMAGE/PNG; q=1", ""));

    // A header announcing a huge image is refused before decoding.
    var hdr: [33]u8 = undefined;
    @memset(&hdr, 0);
    @memcpy(hdr[0..8], "\x89PNG\r\n\x1a\n");
    std.mem.writeInt(u32, hdr[8..12], 13, .big);
    @memcpy(hdr[12..16], "IHDR");
    std.mem.writeInt(u32, hdr[16..20], 40000, .big);
    std.mem.writeInt(u32, hdr[20..24], 40000, .big);
    hdr[24] = 8;
    hdr[25] = 6;
    try std.testing.expectError(error.TooLarge, decode(alloc, "image/png", &hdr));
}

test "win32 clipboard image: preview fits and premultiplies" {
    const alloc = std.testing.allocator;

    // 800x6000 into 200x100: height-limited, aspect kept.
    {
        const w = 800;
        const h = 6000;
        const px = try alloc.alloc(u8, w * h * 4);
        defer alloc.free(px);
        @memset(px, 255);
        const img: Rgba = .{ .width = w, .height = h, .pixels = px };
        var p = try preview(alloc, img, 200, 100);
        defer p.deinit(alloc);
        try std.testing.expect(p.width <= 200 and p.height <= 100);
        try std.testing.expectEqual(@as(u32, 100), p.height);
        try std.testing.expectEqual(@as(u32, 13), p.width); // 800 * 100 / 6000
        try std.testing.expectEqual(@as(usize, p.width) * p.height * 4, p.pixels.len);
        for (p.pixels) |b| try std.testing.expectEqual(@as(u8, 255), b);
    }

    // Wide image: width-limited.
    {
        const px = try alloc.alloc(u8, 400 * 100 * 4);
        defer alloc.free(px);
        @memset(px, 10);
        var p = try preview(alloc, .{ .width = 400, .height = 100, .pixels = px }, 200, 200);
        defer p.deinit(alloc);
        try std.testing.expectEqual(@as(u32, 200), p.width);
        try std.testing.expectEqual(@as(u32, 50), p.height);
    }

    // Small images are not enlarged.
    {
        var px = [_]u8{ 1, 2, 3, 255 };
        var p = try preview(alloc, .{ .width = 1, .height = 1, .pixels = &px }, 64, 64);
        defer p.deinit(alloc);
        try std.testing.expectEqual(@as(u32, 1), p.width);
        try std.testing.expectEqual(@as(u32, 1), p.height);
        try std.testing.expectEqualSlices(u8, &.{ 3, 2, 1, 255 }, p.pixels);
    }

    // 50% alpha red -> premultiplied BGRA.
    {
        var px = [_]u8{ 255, 0, 0, 128 };
        var p = try preview(alloc, .{ .width = 1, .height = 1, .pixels = &px }, 8, 8);
        defer p.deinit(alloc);
        try std.testing.expectEqualSlices(u8, &.{ 0, 0, 128, 128 }, p.pixels);
    }

    // Box filter: 2x1 of opaque white and transparent black -> half-alpha
    // premultiplied white.
    {
        var px = [_]u8{ 255, 255, 255, 255, 0, 0, 0, 0 };
        var p = try preview(alloc, .{ .width = 2, .height = 1, .pixels = &px }, 1, 1);
        defer p.deinit(alloc);
        try std.testing.expectEqual(@as(u32, 1), p.width);
        try std.testing.expectEqualSlices(u8, &.{ 128, 128, 128, 128 }, p.pixels);
    }

    // Bad arguments.
    {
        var px = [_]u8{ 0, 0, 0, 0 };
        const img: Rgba = .{ .width = 1, .height = 1, .pixels = &px };
        try std.testing.expectError(error.Invalid, preview(alloc, img, 0, 10));
        try std.testing.expectError(error.Invalid, preview(alloc, .{ .width = 2, .height = 1, .pixels = &px }, 10, 10));
    }
}

/// A JPEG prefix with an APP0 segment and a baseline frame header.
fn testJpegHead(buf: []u8, width: u16, height: u16) []u8 {
    const head = [_]u8{
        0xFF, 0xD8, // SOI
        0xFF, 0xE0, 0x00, 0x06, 'J', 'F', 'I', 'F', // APP0, length 6
        0xFF, 0xFF, // fill bytes before the next marker
        0xFF, 0xC0, 0x00, 0x11, 8, // SOF0, length 17, precision 8
    };
    @memcpy(buf[0..head.len], &head);
    var n: usize = head.len;
    std.mem.writeInt(u16, buf[n..][0..2], height, .big);
    std.mem.writeInt(u16, buf[n + 2 ..][0..2], width, .big);
    n += 4;
    @memset(buf[n..][0..12], 0);
    return buf[0 .. n + 12];
}

test "win32 clipboard image: jpeg header is checked before decoding" {
    const alloc = std.testing.allocator;
    var buf: [64]u8 = undefined;

    // A few dozen bytes announcing 32000x32000 never reach wuffs.
    const huge = testJpegHead(&buf, 32000, 32000);
    try std.testing.expectError(error.TooLarge, decode(alloc, "image/jpeg", huge));
    try std.testing.expectError(error.TooLarge, decode(alloc, "image/jpeg; q=1", huge));

    // The size is read through the APP0 segment and the fill bytes.
    const dims = try jpegDimensions(testJpegHead(&buf, 123, 45));
    try std.testing.expectEqual(@as(u32, 123), dims.width);
    try std.testing.expectEqual(@as(u32, 45), dims.height);

    // Just under the cap is not refused by the pre-check (5792 * 5792 * 4
    // = 134.2 MB is over 128 MiB; 5700 * 5700 * 4 = 129.9 MB is under).
    const edge = try jpegDimensions(testJpegHead(&buf, 5700, 5700));
    try std.testing.expect(@as(u64, edge.width) * edge.height * 4 <= max_decoded_bytes);
    const over = try jpegDimensions(testJpegHead(&buf, 5800, 5800));
    try std.testing.expect(@as(u64, over.width) * over.height * 4 > max_decoded_bytes);

    // Other SOFn markers are found too; DHT (C4) is not a frame header.
    {
        const progressive = [_]u8{ 0xFF, 0xD8, 0xFF, 0xC4, 0x00, 0x02, 0xFF, 0xC2, 0x00, 0x0B, 8, 0, 9, 0, 7, 1, 1, 0x11, 0 };
        const d = try jpegDimensions(&progressive);
        try std.testing.expectEqual(@as(u32, 7), d.width);
        try std.testing.expectEqual(@as(u32, 9), d.height);
    }

    // Garbage and truncation: errors, never out of bounds.
    const bad = [_][]const u8{
        "",
        "\xFF",
        "\xFF\xD8",
        "\xFF\xD8\xFF",
        "\xFF\xD8\xFF\xC0",
        "\xFF\xD8\xFF\xC0\x00",
        "\xFF\xD8\xFF\xC0\x00\x11\x08\x00",
        "\xFF\xD8\xFF\xC0\x00\x07\x08\x00\x01\x00\x01", // SOF shorter than 8
        "\xFF\xD8\xFF\xE0\x00\x01", // segment length below 2
        "\xFF\xD8\xFF\xE0\xFF\xFF\x00", // segment longer than the data
        "\xFF\xD8\x12\x34\x56", // no marker where one must be
        "\xFF\xD8\xFF\xDA\x00\x02", // scan before any frame
        "\xFF\xD8\xFF\xD9", // EOI before any frame
        "\xFF\xD8\xFF\x00\xFF\x00\xFF\x01\xFF\xD0\xFF\xD7", // only standalone markers
    };
    for (bad) |b| {
        try std.testing.expectError(error.Invalid, jpegDimensions(b));
        try std.testing.expectError(error.Invalid, decode(alloc, "image/jpeg", b));
    }

    // Fill bytes forever.
    {
        var fill: [42]u8 = @splat(0xFF);
        fill[0] = 0xFF;
        fill[1] = 0xD8;
        try std.testing.expectError(error.Invalid, jpegDimensions(&fill));
    }

    // A long chain of empty segments stops at the walk limit.
    var chain: [2 + 4 * 2000]u8 = undefined;
    chain[0] = 0xFF;
    chain[1] = 0xD8;
    var i: usize = 2;
    while (i < chain.len) : (i += 4) @memcpy(chain[i..][0..4], "\xFF\xE1\x00\x02");
    try std.testing.expectError(error.Invalid, jpegDimensions(&chain));
}

test "win32 clipboard image: hostile dib sweep" {
    const alloc = std.testing.allocator;

    // Valid seeds: 24 bpp, 32 bpp BI_RGB, V5 bitfields.
    var img = try testImage(alloc, 3, 3);
    defer img.deinit(alloc);
    const v5 = try toDibV5(alloc, img);
    defer alloc.free(v5);
    const px24 = [_]u8{ 255, 0, 0, 255, 255, 255, 0, 0, 0, 0, 255, 0, 255, 0, 0, 0 };
    const d24 = try testDib(alloc, 2, 2, 24, bi_rgb, null, &px24);
    defer alloc.free(d24);
    const px32 = [_]u8{ 1, 2, 3, 0, 4, 5, 6, 0 };
    const d32 = try testDib(alloc, 2, 1, 32, bi_rgb, null, &px32);
    defer alloc.free(d32);
    const dbf = try testDib(alloc, 1, 1, 32, bi_bitfields, .{ 0x00FF0000, 0x0000FF00, 0x000000FF }, "\x01\x02\x03\x04");
    defer alloc.free(dbf);

    var prng = std.Random.DefaultPrng.init(0xd1b);
    const rand = prng.random();
    var scratch: [512]u8 = undefined;
    for ([_][]const u8{ v5, d24, d32, dbf }) |seed| {
        // Every truncation.
        var cut: usize = 0;
        while (cut <= seed.len) : (cut += 1) {
            if (fromDib(alloc, seed[0..cut])) |ok| {
                var o = ok;
                o.deinit(alloc);
            } else |_| {}
        }
        // Random byte edits, biased towards the header.
        const len = @min(seed.len, scratch.len);
        for (0..400) |_| {
            @memcpy(scratch[0..len], seed[0..len]);
            for (0..rand.intRangeAtMost(usize, 1, 4)) |_| {
                const at = if (rand.boolean()) rand.uintLessThan(usize, @min(len, 130)) else rand.uintLessThan(usize, len);
                scratch[at] = rand.int(u8);
            }
            if (fromDib(alloc, scratch[0..len])) |ok| {
                var o = ok;
                o.deinit(alloc);
            } else |_| {}
        }
    }
}
