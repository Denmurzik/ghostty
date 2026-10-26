//! Wrapper for handling frames.
//!
//! A frame draws into a `Target` between `begin` and `complete`, all under
//! the device context lock (`drawFrameStart`/`drawFrameEnd`). Completing it
//! copies the target into the swap chain and presents it (when the API has a
//! present target) and, with `GHOSTTY_D3D11_DUMP` set, dumps the target: the
//! pixels are read back under the lock, the file is written after it.
const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const win32 = @import("win32");
const global = @import("../../global.zig");
const Health = @import("../../renderer.zig").Health;
const Renderer = @import("../generic.zig").Renderer(D3D11);
const D3D11 = @import("../D3D11.zig");
const Device = @import("Device.zig");
const Target = @import("Target.zig");
const RenderPass = @import("RenderPass.zig");
const SwapChain = @import("SwapChain.zig");

const log = std.log.scoped(.d3d11);

/// Options for beginning a frame.
pub const Options = struct {
    api: *D3D11,
};

/// Where a finished frame reports its health. The generic renderer's
/// `frameCompleted` in production, a recorder in tests.
pub const Sink = struct {
    ptr: *anyopaque,
    completed: *const fn (*anyopaque, Health) void,

    fn forRenderer(renderer: *Renderer) Sink {
        return .{ .ptr = renderer, .completed = rendererCompleted };
    }

    fn rendererCompleted(ptr: *anyopaque, health: Health) void {
        const renderer: *Renderer = @ptrCast(@alignCast(ptr));
        renderer.frameCompleted(health);
    }
};

api: *D3D11,
sink: Sink,
target: *Target,

/// Begin encoding a frame.
pub fn begin(
    opts: Options,
    /// Once the frame has been completed, the `frameCompleted` method
    /// on the renderer is called with the health status of the frame.
    renderer: *Renderer,
    /// The target is presented via the provided renderer's API when completed.
    target: *Target,
) !Self {
    return beginWithSink(opts, .forRenderer(renderer), target);
}

/// `begin` with an explicit health sink, for tests without a renderer.
pub fn beginWithSink(opts: Options, sink: Sink, target: *Target) !Self {
    opts.api.device.assertContextLocked();
    return .{ .api = opts.api, .sink = sink, .target = target };
}

/// Add a render pass to this frame with the provided attachments.
/// Returns a RenderPass which allows render steps to be added.
pub inline fn renderPass(
    self: *const Self,
    attachments: []const RenderPass.Options.Attachment,
) RenderPass {
    _ = self;
    return RenderPass.begin(.{ .attachments = attachments });
}

/// Complete this frame and present the target.
///
/// `sync` frames (UI thread) present like any other: the present call
/// returns once the frame is queued, which is as presented as D3D11 lets
/// us observe.
pub fn complete(self: *const Self, sync: bool) void {
    _ = sync;

    const api = self.api;
    api.device.assertContextLocked();

    var health: Health = .healthy;
    self.submit() catch |err| switch (err) {
        error.DeviceLost => {
            health = .unhealthy;
            if (!api.device_lost_logged) {
                api.device_lost_logged = true;
                log.err("d3d11 device lost, the surface will not draw", .{});
            }
        },
    };

    Device.logFirstFramePrivateUsage();
    api.logPacing();
    self.sink.completed(self.sink.ptr, health);
}

/// Presents the target, submits the queued commands, then dumps the target
/// if requested.
fn submit(self: *const Self) error{DeviceLost}!void {
    const api = self.api;

    if (api.present_target != null) self.present() catch |err| switch (err) {
        error.DeviceLost => return error.DeviceLost,
        // The frame itself was drawn; a swap chain that cannot show it
        // is not a lost device. Logged once, retried by the next frame.
        else => api.logSwapChainFailure("present", err),
    };

    api.device.context.flush();
    // Any failing reason code means the device is gone.
    api.device.device.checkDeviceRemoved() catch return error.DeviceLost;

    if (api.dump) |*dump| {
        // The surface id names the file once the apprt provides one.
        const file_index: usize = if (api.present_target) |pt| pt.id else dump.index;
        try dump.capture(api.alloc, self.target, file_index);
    }
}

/// Copies the target into the swap chain's back buffer and presents it.
fn present(self: *const Self) !void {
    const api = self.api;
    const sc = try api.swapChain(
        @intCast(self.target.width),
        @intCast(self.target.height),
    );
    // Read before the present: a bump during it must stay unaccepted.
    const seen = api.presentGeneration();
    const first = presentTo(sc, self.target, api.vsync);
    first catch |err| {
        // A window that changed parents may have broken the chain: build a
        // new one and present the same frame once more.
        if (!api.recreateOnPresentFailure(err)) return err;
        const fresh = try api.swapChain(
            @intCast(self.target.width),
            @intCast(self.target.height),
        );
        // `fresh` took the generation at its creation.
        return presentTo(fresh, self.target, api.vsync);
    };
    api.presentSucceeded(seen);
}

fn presentTo(sc: *SwapChain, target: *const Target, vsync: bool) !void {
    try sc.copyToBackbuffer(sc.device.context, target);
    try sc.present(vsync);
}

/// The frame dump hook: with env `GHOSTTY_D3D11_DUMP=<dir>` every renderer
/// writes the target of a finished frame to `<dir>\surface-<n>.bmp`, `n`
/// being its per-process renderer index (creation order, from 0). The file
/// is replaced atomically, so a reader sees a whole frame, and at most
/// every `interval_ms` — a frame inside the interval is skipped, not
/// deferred. The BMP is a 32-bit BI_RGB top-down bitmap (54 byte header,
/// `width * height * 4` bytes of BGRA) holding the target's stored bytes:
/// sRGB encoded for `window-colorspace`/linear blending targets, with
/// premultiplied alpha.
///
/// Limitation: a frame of the same size inside `interval_ms` of the last dump
/// is skipped, and an idle terminal draws no further frame, so the file may
/// lack the last frame of a burst. A frame of a new size is always dumped.
/// Scenarios that need a final frame wait at least `interval_ms` and trigger
/// a repaint.
///
/// The read back (`capture`) happens under the device context lock; the
/// file I/O (`flush`) runs after `drawFrameEnd` released it, so a slow disk
/// never holds up the other surfaces.
pub const Dump = struct {
    /// Owned by `deinit`.
    dir: []const u8,
    index: usize,
    interval_ms: i64 = 250,
    last: ?std.Io.Timestamp = null,
    last_width: usize = 0,
    last_height: usize = 0,
    failed_logged: bool = false,

    /// The captured frame waiting for `flush`.
    pending: ?Pending = null,

    /// Test hook: runs in `flush` right before the file is written.
    before_write: ?struct {
        ctx: *anyopaque,
        run: *const fn (*anyopaque) void,
    } = null,

    const Pending = struct {
        /// Tightly packed BGRA, owned by the dump.
        pixels: []u8,
        width: usize,
        height: usize,
        file_index: usize,
    };

    /// Null unless `GHOSTTY_D3D11_DUMP` is set to a non-empty value.
    pub fn initFromEnv(alloc: Allocator, index: usize) ?Dump {
        const dir = global.environ().getAlloc(alloc, "GHOSTTY_D3D11_DUMP") catch return null;
        if (dir.len == 0) {
            alloc.free(dir);
            return null;
        }

        log.info("d3d11 frame dump dir={s} file=surface-{d}.bmp", .{ dir, index });
        return .{ .dir = dir, .index = index };
    }

    pub fn deinit(self: *Dump, alloc: Allocator) void {
        if (self.pending) |p| alloc.free(p.pixels);
        alloc.free(self.dir);
        self.* = undefined;
    }

    /// Reads the target back unless the last dump is too recent; `flush`
    /// writes it. Only a lost device is an error; other failures are logged
    /// once.
    ///
    /// Reads the target with the immediate context: the caller holds the
    /// device context lock.
    pub fn capture(
        self: *Dump,
        alloc: Allocator,
        target: *const Target,
        file_index: usize,
    ) error{DeviceLost}!void {
        const now = std.Io.Timestamp.now(global.io(), .awake);
        // A new size always dumps: an idle terminal draws no further frame,
        // so a throttled resize frame would leave the old size on disk.
        const resized = target.width != self.last_width or target.height != self.last_height;
        if (self.last) |last| {
            if (!resized and last.durationTo(now).toMilliseconds() < self.interval_ms) return;
        }
        self.last_width = target.width;
        self.last_height = target.height;
        // Also set on failure, so a broken dump dir is not retried per frame.
        self.last = now;

        const pixels = target.readPixelsAlloc(alloc) catch |err| {
            if (err == error.DeviceLost) return error.DeviceLost;
            self.logFailure(err);
            return;
        };
        if (self.pending) |p| alloc.free(p.pixels);
        self.pending = .{
            .pixels = pixels,
            .width = target.width,
            .height = target.height,
            .file_index = file_index,
        };
    }

    /// Writes the captured frame, if any. Takes no device state, so it runs
    /// without the context lock.
    pub fn flush(self: *Dump, alloc: Allocator) void {
        const p = self.pending orelse return;
        self.pending = null;
        defer alloc.free(p.pixels);

        if (self.before_write) |hook| hook.run(hook.ctx);
        self.write(p) catch |err| self.logFailure(err);
    }

    fn logFailure(self: *Dump, err: anyerror) void {
        if (self.failed_logged) return;
        self.failed_logged = true;
        log.warn("d3d11 frame dump failed dir={s} err={}", .{ self.dir, err });
    }

    fn write(self: *const Dump, p: Pending) !void {
        const io = global.io();

        try std.Io.Dir.cwd().createDirPath(io, self.dir);
        var dir = try std.Io.Dir.cwd().openDir(io, self.dir, .{});
        defer dir.close(io);

        var name_buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "surface-{d}.bmp", .{p.file_index});

        var atomic = try dir.createFileAtomic(io, name, .{ .replace = true });
        defer atomic.deinit(io);

        var buf: [4096]u8 = undefined;
        var file_writer = atomic.file.writer(io, &buf);
        try writeBmp(&file_writer.interface, p.width, p.height, p.pixels);
        try file_writer.flush();
        try atomic.replace(io);
    }
};

/// Size of the BITMAPFILEHEADER and BITMAPINFOHEADER.
pub const bmp_header_len = 54;

/// Writes tightly packed BGRA rows as a top-down 32-bit BMP.
pub fn writeBmp(
    writer: *std.Io.Writer,
    width: usize,
    height: usize,
    bgra: []const u8,
) !void {
    std.debug.assert(bgra.len == width * height * 4);

    const image_size: u32 = @intCast(bgra.len);
    var header: [bmp_header_len]u8 = @splat(0);

    // BITMAPFILEHEADER.
    header[0] = 'B';
    header[1] = 'M';
    std.mem.writeInt(u32, header[2..6], bmp_header_len + image_size, .little);
    std.mem.writeInt(u32, header[10..14], bmp_header_len, .little);

    // BITMAPINFOHEADER; a negative height makes the rows top-down.
    std.mem.writeInt(u32, header[14..18], 40, .little);
    std.mem.writeInt(i32, header[18..22], @intCast(width), .little);
    std.mem.writeInt(i32, header[22..26], -@as(i32, @intCast(height)), .little);
    std.mem.writeInt(u16, header[26..28], 1, .little);
    std.mem.writeInt(u16, header[28..30], 32, .little);
    // header[30..34] compression: BI_RGB = 0.
    std.mem.writeInt(u32, header[34..38], image_size, .little);
    std.mem.writeInt(u32, header[38..42], 2835, .little);
    std.mem.writeInt(u32, header[42..46], 2835, .little);

    try writer.writeAll(&header);
    try writer.writeAll(bgra);
}

// Test support ---------------------------------------------------------

const testing = std.testing;
const font = @import("../../font/main.zig");
const math = @import("../../math.zig");
const bufferpkg = @import("buffer.zig");
const shaderspkg = @import("shaders.zig");
const Texture = @import("Texture.zig");

/// Records the health a frame reported.
const Recorder = struct {
    health: ?Health = null,
    count: usize = 0,

    fn sink(self: *Recorder) Sink {
        return .{ .ptr = self, .completed = completed };
    }

    fn completed(ptr: *anyopaque, health: Health) void {
        const self: *Recorder = @ptrCast(@alignCast(ptr));
        self.health = health;
        self.count += 1;
    }
};

/// Ends the frame (the dump is written) and begins the next one.
fn cycleLock(api: *D3D11) void {
    api.drawFrameEnd();
    api.drawFrameStart();
}

/// A headless API, its shaders and a target on a WARP device.
const Fixture = struct {
    device: *Device,
    api: D3D11,
    shaders: shaderspkg.Shaders,
    target: Target,
    recorder: Recorder = .{},

    fn init(
        blending: @FieldType(D3D11, "blending"),
        width: usize,
        height: usize,
    ) !Fixture {
        const device = try Device.init(testing.allocator, .{ .driver = .warp });
        errdefer device.deinit(testing.allocator);

        const api: D3D11 = .{
            .alloc = testing.allocator,
            .blending = blending,
            .device = device,
        };
        var shaders = try api.initShaders(testing.allocator, &.{});
        errdefer shaders.deinit(testing.allocator);
        const target = try api.initTarget(width, height);

        return .{
            .device = device,
            .api = api,
            .shaders = shaders,
            .target = target,
        };
    }

    fn deinit(self: *Fixture) void {
        self.target.deinit();
        self.shaders.deinit(testing.allocator);
        self.device.deinit(testing.allocator);
    }

    /// Uniforms for a grid of `cols` x `rows` cells that exactly fills the
    /// target, as the generic renderer would set them up.
    fn uniforms(self: *const Fixture, cell_w: u32, cell_h: u32, cols: u16, rows: u16) shaderspkg.Uniforms {
        const w: f32 = @floatFromInt(self.target.width);
        const h: f32 = @floatFromInt(self.target.height);
        var u = std.mem.zeroes(shaderspkg.Uniforms);
        u.projection_matrix = @bitCast(math.ortho2d(0, w, h, 0));
        u.screen_size = .{ w, h };
        u.cell_size = .{ @floatFromInt(cell_w), @floatFromInt(cell_h) };
        u.grid_size = .{ cols, rows };
        // Off the grid, so no cell takes the cursor colour.
        u.cursor_pos = .{ 0xffff, 0xffff };
        u.bools = .{
            .cursor_wide = false,
            // The default config (`window-colorspace = srgb`). The D3D11
            // shaders do no colour space conversion either way.
            .use_display_p3 = false,
            .use_linear_blending = self.api.blending.isLinear(),
        };
        return u;
    }

    fn pixels(self: *Fixture) ![]u8 {
        return try self.target.readPixelsAlloc(testing.allocator);
    }
};

fn pixelAt(pixels: []const u8, width: usize, x: usize, y: usize) [4]u8 {
    return pixels[(y * width + x) * 4 ..][0..4].*;
}

fn expectPixel(want: [4]u8, got: [4]u8, tolerance: u8) !void {
    for (want, got) |w, g| {
        const d = if (w > g) w - g else g - w;
        if (d > tolerance) {
            std.debug.print("pixel mismatch want={any} got={any}\n", .{ want, got });
            return error.TestExpectedEqual;
        }
    }
}

test "d3d11 frame: cell_bg draws a per-cell colour" {
    var fx: Fixture = try .init(.native, 16, 16);
    defer fx.deinit();

    var uniforms = try bufferpkg.Buffer(shaderspkg.Uniforms).init(fx.api.uniformBufferOptions(), 1);
    defer uniforms.deinit();
    var bg_cells = try bufferpkg.Buffer(shaderspkg.CellBg).initFill(
        fx.api.bgBufferOptions(),
        &.{ .{ 255, 0, 0, 255 }, .{ 0, 255, 0, 255 } },
    );
    defer bg_cells.deinit();

    fx.api.drawFrameStart();
    defer fx.api.drawFrameEnd();

    try uniforms.sync(&.{fx.uniforms(8, 16, 2, 1)});

    var frame = try beginWithSink(.{ .api = &fx.api }, fx.recorder.sink(), &fx.target);
    {
        var pass = frame.renderPass(&.{.{
            .target = .{ .target = fx.target },
            .clear_color = .{ 0, 0, 0, 0 },
        }});
        defer pass.complete();

        pass.step(.{
            .pipeline = fx.shaders.pipelines.cell_bg,
            .uniforms = uniforms.buffer,
            .buffers = &.{ null, bg_cells.buffer },
            .draw = .{ .type = .triangle, .vertex_count = 3 },
        });
    }
    frame.complete(false);

    const pixels = try fx.pixels();
    defer testing.allocator.free(pixels);
    // BGRA.
    try expectPixel(.{ 0, 0, 255, 255 }, pixelAt(pixels, 16, 4, 8), 0);
    try expectPixel(.{ 0, 255, 0, 255 }, pixelAt(pixels, 16, 12, 8), 0);
    try testing.expectEqual(@as(?Health, .healthy), fx.recorder.health);
    try testing.expectEqual(@as(usize, 1), fx.recorder.count);
}

test "d3d11 frame: cell_text samples the grayscale atlas" {
    var fx: Fixture = try .init(.native, 16, 16);
    defer fx.deinit();

    var uniforms = try bufferpkg.Buffer(shaderspkg.Uniforms).init(fx.api.uniformBufferOptions(), 1);
    defer uniforms.deinit();
    var bg_cells = try bufferpkg.Buffer(shaderspkg.CellBg).initFill(
        fx.api.bgBufferOptions(),
        &.{.{ 0, 0, 0, 0 }},
    );
    defer bg_cells.deinit();
    var cells = try bufferpkg.Buffer(shaderspkg.CellText).initFill(
        fx.api.fgBufferOptions(),
        // A 4x4 glyph at (2, 2) of the atlas, drawn 2 px right of and 4 px
        // below the cell's top-left corner (`cell_h - bearing_y`).
        &.{.{
            .glyph_pos = .{ 2, 2 },
            .glyph_size = .{ 4, 4 },
            .bearings = .{ 2, 12 },
            .grid_pos = .{ 0, 0 },
            .color = .{ 255, 255, 255, 255 },
            .atlas = .grayscale,
        }},
    );
    defer cells.deinit();

    var gray: font.Atlas = try .init(testing.allocator, 8, .grayscale);
    defer gray.deinit(testing.allocator);
    for (2..6) |y| @memset(gray.data[y * 8 + 2 ..][0..4], 255);
    var color: font.Atlas = try .init(testing.allocator, 8, .bgra);
    defer color.deinit(testing.allocator);

    fx.api.drawFrameStart();
    defer fx.api.drawFrameEnd();

    const gray_tex = try fx.api.initAtlasTexture(&gray);
    defer gray_tex.deinit();
    try gray_tex.replaceRegion(0, 0, 8, 8, gray.data);
    const color_tex = try fx.api.initAtlasTexture(&color);
    defer color_tex.deinit();
    try color_tex.replaceRegion(0, 0, 8, 8, color.data);

    // A background that differs from both the clear colour and the glyph.
    var bg_uniforms = fx.uniforms(8, 16, 1, 1);
    bg_uniforms.bg_color = .{ 10, 20, 30, 255 };
    try uniforms.sync(&.{bg_uniforms});

    var frame = try beginWithSink(.{ .api = &fx.api }, fx.recorder.sink(), &fx.target);
    {
        var pass = frame.renderPass(&.{.{
            .target = .{ .target = fx.target },
            .clear_color = .{ 0, 0, 0, 0 },
        }});
        defer pass.complete();

        pass.step(.{
            .pipeline = fx.shaders.pipelines.bg_color,
            .uniforms = uniforms.buffer,
            .draw = .{ .type = .triangle, .vertex_count = 3 },
        });
        pass.step(.{
            .pipeline = fx.shaders.pipelines.cell_text,
            .uniforms = uniforms.buffer,
            .buffers = &.{ cells.buffer, bg_cells.buffer },
            .textures = &.{ gray_tex, color_tex },
            .draw = .{ .type = .triangle_strip, .vertex_count = 4, .instance_count = 1 },
        });
    }
    frame.complete(false);

    const pixels = try fx.pixels();
    defer testing.allocator.free(pixels);
    // Inside the quad [2, 6) x [4, 8).
    for ([_][2]usize{ .{ 2, 4 }, .{ 5, 7 }, .{ 3, 5 } }) |p| {
        const px = pixelAt(pixels, 16, p[0], p[1]);
        try testing.expect(px[0] >= 250 and px[1] >= 250 and px[2] >= 250);
    }
    // Around it, the background (BGRA).
    for ([_][2]usize{ .{ 1, 4 }, .{ 6, 5 }, .{ 3, 3 }, .{ 4, 8 }, .{ 12, 12 }, .{ 0, 0 } }) |p| {
        try expectPixel(.{ 30, 20, 10, 255 }, pixelAt(pixels, 16, p[0], p[1]), 0);
    }
}

test "d3d11 frame: colour atlas glyph next to a non-default bg cell" {
    var fx: Fixture = try .init(.native, 16, 16);
    defer fx.deinit();

    var uniforms = try bufferpkg.Buffer(shaderspkg.Uniforms).init(fx.api.uniformBufferOptions(), 1);
    defer uniforms.deinit();
    var bg_cells = try bufferpkg.Buffer(shaderspkg.CellBg).initFill(
        fx.api.bgBufferOptions(),
        &.{ .{ 0, 0, 0, 0 }, .{ 0, 255, 0, 255 } },
    );
    defer bg_cells.deinit();
    var cells = try bufferpkg.Buffer(shaderspkg.CellText).initFill(
        fx.api.fgBufferOptions(),
        // A whole-cell glyph in cell 0.
        &.{.{
            .glyph_pos = .{ 0, 0 },
            .glyph_size = .{ 8, 16 },
            .bearings = .{ 0, 16 },
            .grid_pos = .{ 0, 0 },
            .color = .{ 255, 255, 255, 255 },
            .atlas = .color,
        }},
    );
    defer cells.deinit();

    var gray: font.Atlas = try .init(testing.allocator, 16, .grayscale);
    defer gray.deinit(testing.allocator);
    var color: font.Atlas = try .init(testing.allocator, 16, .bgra);
    defer color.deinit(testing.allocator);
    // Opaque pure blue, BGRA.
    for (0..16 * 16) |i| color.data[i * 4 ..][0..4].* = .{ 255, 0, 0, 255 };

    fx.api.drawFrameStart();
    defer fx.api.drawFrameEnd();

    const gray_tex = try fx.api.initAtlasTexture(&gray);
    defer gray_tex.deinit();
    try gray_tex.replaceRegion(0, 0, 16, 16, gray.data);
    const color_tex = try fx.api.initAtlasTexture(&color);
    defer color_tex.deinit();
    try color_tex.replaceRegion(0, 0, 16, 16, color.data);

    try uniforms.sync(&.{fx.uniforms(8, 16, 2, 1)});

    var frame = try beginWithSink(.{ .api = &fx.api }, fx.recorder.sink(), &fx.target);
    {
        var pass = frame.renderPass(&.{.{
            .target = .{ .target = fx.target },
            .clear_color = .{ 0, 0, 0, 0 },
        }});
        defer pass.complete();

        pass.step(.{
            .pipeline = fx.shaders.pipelines.cell_bg,
            .uniforms = uniforms.buffer,
            .buffers = &.{ null, bg_cells.buffer },
            .draw = .{ .type = .triangle, .vertex_count = 3 },
        });
        pass.step(.{
            .pipeline = fx.shaders.pipelines.cell_text,
            .uniforms = uniforms.buffer,
            .buffers = &.{ cells.buffer, bg_cells.buffer },
            .textures = &.{ gray_tex, color_tex },
            .draw = .{ .type = .triangle_strip, .vertex_count = 4, .instance_count = 1 },
        });
    }
    frame.complete(false);

    const pixels = try fx.pixels();
    defer testing.allocator.free(pixels);
    // BGRA: blue glyph in cell 0, green background in cell 1.
    try expectPixel(.{ 255, 0, 0, 255 }, pixelAt(pixels, 16, 1, 1), 0);
    try expectPixel(.{ 255, 0, 0, 255 }, pixelAt(pixels, 16, 6, 14), 0);
    try expectPixel(.{ 0, 255, 0, 255 }, pixelAt(pixels, 16, 9, 1), 0);
    try expectPixel(.{ 0, 255, 0, 255 }, pixelAt(pixels, 16, 14, 14), 0);
}

test "d3d11 frame: linear blending encodes through the srgb view" {
    var fx: Fixture = try .init(.linear, 8, 4);
    defer fx.deinit();
    try testing.expectEqual(win32.dxgi.Format.B8G8R8A8_TYPELESS, fx.target.texture.format);

    var uniforms = try bufferpkg.Buffer(shaderspkg.Uniforms).init(fx.api.uniformBufferOptions(), 1);
    defer uniforms.deinit();

    fx.api.drawFrameStart();
    defer fx.api.drawFrameEnd();

    var u = fx.uniforms(8, 4, 1, 1);
    u.bg_color = .{ 200, 64, 128, 255 };
    try uniforms.sync(&.{u});

    var frame = try beginWithSink(.{ .api = &fx.api }, fx.recorder.sink(), &fx.target);
    {
        var pass = frame.renderPass(&.{.{
            .target = .{ .target = fx.target },
            .clear_color = .{ 1, 1, 1, 1 },
        }});
        defer pass.complete();

        // The shader writes linear values; the view re-encodes them, so
        // an sRGB colour round-trips unchanged with the default config
        // (no sRGB -> Display P3 conversion on D3D11).
        pass.step(.{
            .pipeline = fx.shaders.pipelines.bg_color,
            .uniforms = uniforms.buffer,
            .draw = .{ .type = .triangle, .vertex_count = 3 },
        });
    }
    frame.complete(false);

    const pixels = try fx.pixels();
    defer testing.allocator.free(pixels);
    // BGRA.
    try expectPixel(.{ 128, 64, 200, 255 }, pixelAt(pixels, 8, 0, 0), 1);
    try expectPixel(.{ 128, 64, 200, 255 }, pixelAt(pixels, 8, 7, 3), 1);
}

test "d3d11 frame: dump hook writes a BMP" {
    var fx: Fixture = try .init(.native, 5, 3);
    defer fx.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = path_buf[0..try tmp.dir.realPath(testing.io, &path_buf)];

    // A directory that does not exist yet is created.
    const dir = try std.fs.path.join(testing.allocator, &.{ tmp_path, "dumps" });
    defer testing.allocator.free(dir);
    fx.api.dump = .{ .dir = dir, .index = 0, .interval_ms = 1000 * 60 * 60 };

    fx.api.drawFrameStart();
    defer fx.api.drawFrameEnd();

    for ([_][4]f32{ .{ 1, 0, 0, 1 }, .{ 0, 1, 0, 1 } }) |clear| {
        var frame = try beginWithSink(.{ .api = &fx.api }, fx.recorder.sink(), &fx.target);
        var pass = frame.renderPass(&.{.{
            .target = .{ .target = fx.target },
            .clear_color = clear,
        }});
        pass.complete();
        frame.complete(false);
        cycleLock(&fx.api);

        const bytes = try tmp.dir.readFileAlloc(testing.io, "dumps/surface-0.bmp", testing.allocator, .limited(1 << 20));
        defer testing.allocator.free(bytes);

        try testing.expectEqual(@as(usize, bmp_header_len + 5 * 3 * 4), bytes.len);
        try testing.expectEqualStrings("BM", bytes[0..2]);
        try testing.expectEqual(@as(u32, 5), std.mem.readInt(u32, bytes[18..22], .little));
        try testing.expectEqual(@as(i32, -3), std.mem.readInt(i32, bytes[22..26], .little));
        try testing.expectEqual(@as(u16, 32), std.mem.readInt(u16, bytes[28..30], .little));
        // The second frame is inside the interval: the file still holds
        // the first one (BGRA red).
        try testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, bytes[bmp_header_len..][0..4]);
    }
    try testing.expectEqual(@as(usize, 2), fx.recorder.count);
    try testing.expectEqual(@as(?Health, .healthy), fx.recorder.health);

    // Once the interval has passed the next frame replaces the file.
    fx.api.dump.?.interval_ms = 0;
    var frame = try beginWithSink(.{ .api = &fx.api }, fx.recorder.sink(), &fx.target);
    frame.complete(false);
    cycleLock(&fx.api);
    const bytes = try tmp.dir.readFileAlloc(testing.io, "dumps/surface-0.bmp", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);
    try testing.expectEqualSlices(u8, &.{ 0, 255, 0, 255 }, bytes[bmp_header_len..][0..4]);
}

test "d3d11 frame: a dump of a new size is not throttled" {
    var fx: Fixture = try .init(.native, 5, 3);
    defer fx.deinit();
    var other = try fx.api.initTarget(8, 2);
    defer other.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = path_buf[0..try tmp.dir.realPath(testing.io, &path_buf)];
    const dir = try std.fs.path.join(testing.allocator, &.{ tmp_path, "dumps" });
    defer testing.allocator.free(dir);
    fx.api.dump = .{ .dir = dir, .index = 0, .interval_ms = 1000 * 60 * 60 };

    fx.api.drawFrameStart();
    defer fx.api.drawFrameEnd();

    var frame = try beginWithSink(.{ .api = &fx.api }, fx.recorder.sink(), &fx.target);
    frame.complete(false);
    cycleLock(&fx.api);
    // Same size inside the interval: skipped.
    frame.complete(false);
    cycleLock(&fx.api);
    var bytes = try tmp.dir.readFileAlloc(testing.io, "dumps/surface-0.bmp", testing.allocator, .limited(1 << 20));
    try testing.expectEqual(@as(u32, 5), std.mem.readInt(u32, bytes[18..22], .little));
    testing.allocator.free(bytes);

    // Another size inside the interval: dumped.
    var resized = try beginWithSink(.{ .api = &fx.api }, fx.recorder.sink(), &other);
    resized.complete(false);
    cycleLock(&fx.api);
    bytes = try tmp.dir.readFileAlloc(testing.io, "dumps/surface-0.bmp", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);
    try testing.expectEqual(@as(u32, 8), std.mem.readInt(u32, bytes[18..22], .little));
}

test "d3d11 frame: a failing dump does not fail the frame" {
    var fx: Fixture = try .init(.native, 4, 4);
    defer fx.deinit();

    // A file where the directory should be.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "file", .data = "x" });
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = path_buf[0..try tmp.dir.realPath(testing.io, &path_buf)];
    const dir = try std.fs.path.join(testing.allocator, &.{ tmp_path, "file" });
    defer testing.allocator.free(dir);
    fx.api.dump = .{ .dir = dir, .index = 3 };

    fx.api.drawFrameStart();
    defer fx.api.drawFrameEnd();

    var frame = try beginWithSink(.{ .api = &fx.api }, fx.recorder.sink(), &fx.target);
    frame.complete(false);
    cycleLock(&fx.api);
    try testing.expectEqual(@as(?Health, .healthy), fx.recorder.health);
    try testing.expect(fx.api.dump.?.failed_logged);
}

/// A second thread that waits for the context lock, as a render thread of
/// another surface does.
const LockWaiter = struct {
    device: *Device,
    dir: std.Io.Dir,
    path: []const u8,
    acquired: std.atomic.Value(bool) = .init(false),
    checked: std.atomic.Value(bool) = .init(false),
    file_existed: bool = true,

    fn run(self: *LockWaiter) void {
        self.device.lockContext();
        defer self.device.unlockContext();
        self.acquired.store(true, .release);
        self.file_existed = if (self.dir.access(testing.io, self.path, .{})) true else |_| false;
        self.checked.store(true, .release);
    }

    /// The dump's `before_write` hook: runs after the frame unlocked and
    /// before the file is written. Gives the waiter time to get the lock.
    fn waitForCheck(ptr: *anyopaque) void {
        const self: *LockWaiter = @ptrCast(@alignCast(ptr));
        const start = std.Io.Timestamp.now(testing.io, .awake);
        while (!self.checked.load(.acquire)) {
            const waited = start.durationTo(std.Io.Timestamp.now(testing.io, .awake));
            if (waited.toMilliseconds() > 5000) return;
            std.Thread.yield() catch {};
        }
    }
};

test "d3d11 frame: dump is written after the context lock is released" {
    var fx: Fixture = try .init(.native, 16, 8);
    defer fx.deinit();
    var window: SwapChain.TestWindow = try .init();
    defer window.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = path_buf[0..try tmp.dir.realPath(testing.io, &path_buf)];
    const dir = try std.fs.path.join(testing.allocator, &.{ tmp_path, "dumps" });
    defer testing.allocator.free(dir);
    // The index of a headless renderer is overridden by the surface id.
    fx.api.dump = .{ .dir = dir, .index = 0 };

    var packed_size: std.atomic.Value(u64) = .init(D3D11.packSize(16, 8));
    fx.api.present_target = .{ .hwnd = window.hwnd, .size = &packed_size, .id = 7 };
    defer fx.api.threadExit();

    var waiter: LockWaiter = .{
        .device = fx.device,
        .dir = tmp.dir,
        .path = "dumps/surface-7.bmp",
    };
    fx.api.dump.?.before_write = .{ .ctx = &waiter, .run = LockWaiter.waitForCheck };

    fx.api.drawFrameStart();
    const thread = try std.Thread.spawn(.{}, LockWaiter.run, .{&waiter});
    {
        var frame = try beginWithSink(.{ .api = &fx.api }, fx.recorder.sink(), &fx.target);
        var pass = frame.renderPass(&.{.{
            .target = .{ .target = fx.target },
            .clear_color = .{ 1, 0, 0, 1 },
        }});
        pass.complete();
        frame.complete(false);
    }
    // Unlocks, then writes: the waiter gets the lock before the file exists.
    fx.api.drawFrameEnd();
    thread.join();

    try testing.expect(waiter.acquired.load(.acquire));
    try testing.expect(!waiter.file_existed);
    const bytes = try tmp.dir.readFileAlloc(testing.io, "dumps/surface-7.bmp", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);
    try testing.expectEqual(@as(usize, bmp_header_len + 16 * 8 * 4), bytes.len);
    try testing.expectEqual(@as(?Health, .healthy), fx.recorder.health);
}

test "d3d11 frame: complete presents into a lazily created swap chain" {
    var fx: Fixture = try .init(.native, 16, 8);
    defer fx.deinit();
    var window: SwapChain.TestWindow = try .init();
    defer window.deinit();

    var packed_size: std.atomic.Value(u64) = .init(D3D11.packSize(16, 8));
    fx.api.present_target = .{ .hwnd = window.hwnd, .size = &packed_size };
    defer fx.api.threadExit();

    fx.api.drawFrameStart();
    defer fx.api.drawFrameEnd();
    try testing.expect(fx.api.swap_chain == null);

    var frame = try beginWithSink(.{ .api = &fx.api }, fx.recorder.sink(), &fx.target);
    {
        var pass = frame.renderPass(&.{.{
            .target = .{ .target = fx.target },
            .clear_color = .{ 1, 0, 0, 1 },
        }});
        pass.complete();
    }
    frame.complete(false);

    const sc = fx.api.swap_chain orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u32, 16), sc.width);
    try testing.expectEqual(@as(u32, 8), sc.height);
    try testing.expectEqual(@as(?Health, .healthy), fx.recorder.health);
    try testing.expectEqual(@as(usize, 1), fx.recorder.count);
}

test "d3d11 frame: bmp header" {
    var out: [bmp_header_len + 8]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&out);
    try writeBmp(&writer, 2, 1, &.{ 1, 2, 3, 4, 5, 6, 7, 8 });

    try testing.expectEqual(@as(u32, bmp_header_len + 8), std.mem.readInt(u32, out[2..6], .little));
    try testing.expectEqual(@as(u32, bmp_header_len), std.mem.readInt(u32, out[10..14], .little));
    try testing.expectEqual(@as(u32, 8), std.mem.readInt(u32, out[34..38], .little));
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6, 7, 8 }, out[bmp_header_len..]);
}
