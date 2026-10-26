//! Chrome spike (risk R9). A standalone GUI exe, not Ghostty: a top-level
//! window with its caption removed (`WM_NCCALCSIZE`), the top 40 px extended
//! into the client area with a Mica backdrop, a Direct2D tab strip painted
//! into a `BeginBufferedPaint` DC, and a child HWND below the strip that owns a
//! flip-model swap chain presented at vsync. `--reparent` moves that presenting
//! child into a second top-level with `SetParent`, without recreating the swap
//! chain. run.ps1 drives it and decides: painter backend and re-parent result.
//!
//! Flags: --variant=none|dc  --no-buttons  --reparent [--destroy-a] [--resize]  --seconds=N  --log=PATH
//! The log (key=value lines) is what run.ps1 reads; see `logf` call sites.
const std = @import("std");
const win32 = @import("win32");
const user32 = win32.user32;
const gdi32 = win32.gdi32;
const dwmapi = win32.dwmapi;
const kernel32 = win32.kernel32;
const d3d11 = win32.d3d11;
const dxgi = win32.dxgi;
const d2d1 = win32.d2d1;
const dwrite = win32.dwrite;
const com = win32.com;
const foundation = win32.foundation;
const HWND = foundation.HWND;
const HRESULT = foundation.HRESULT;
const RECT = foundation.RECT;
const HDC = user32.HDC;

const L = std.unicode.utf8ToUtf16LeStringLiteral;

// Declared here, not in pkg/win32: Task 18 binds buffered paint properly.
const HPAINTBUFFER = *opaque {};
const BP_PAINTPARAMS = extern struct {
    cbSize: u32 = @sizeOf(BP_PAINTPARAMS),
    dwFlags: u32 = 0,
    prcExclude: ?*const RECT = null,
    pBlendFunction: ?*const user32.BLENDFUNCTION = null,
};
const BPBF_TOPDOWNDIB = 2;
const BPPF_ERASE = 1;
extern "uxtheme" fn BufferedPaintInit() callconv(.winapi) HRESULT;
extern "uxtheme" fn BufferedPaintUnInit() callconv(.winapi) HRESULT;
extern "uxtheme" fn BeginBufferedPaint(HDC, *const RECT, format: u32, ?*const BP_PAINTPARAMS, *?HDC) callconv(.winapi) ?HPAINTBUFFER;
extern "uxtheme" fn EndBufferedPaint(HPAINTBUFFER, update_target: foundation.BOOL) callconv(.winapi) HRESULT;

extern "kernel32" fn Sleep(ms: u32) callconv(.winapi) void;
extern "kernel32" fn ExitProcess(code: u32) callconv(.winapi) noreturn;
extern "kernel32" fn GetCommandLineW() callconv(.winapi) [*:0]const u16;
extern "user32" fn SetProcessDpiAwarenessContext(ctx: isize) callconv(.winapi) foundation.BOOL;

const DPI_PER_MONITOR_V2: isize = -4;
const sc_keymenu = 0xF100;
const CREATE_ALWAYS = 2;
const FILE_SHARE_RW = 3;
const STATUS_OCCLUDED: HRESULT = dxgi.STATUS_OCCLUDED;

const strip_dip = 40;
const button_dip = 46;
const child_color = [4]f32{ 16.0 / 255.0, 32.0 / 255.0, 48.0 / 255.0, 1 }; // #102030
const moved_color = [4]f32{ 32.0 / 255.0, 48.0 / 255.0, 16.0 / 255.0, 1 }; // #203010

const Variant = enum { none, dc };
/// Window style bit dropped to see whether DWM stops drawing its own caption
/// buttons under the custom strip.
const StyleOff = enum { none, sysmenu, caption };

const Cfg = struct {
    variant: Variant = .none,
    no_buttons: bool = false,
    reparent: bool = false,
    /// With --reparent: destroy window A after the move, then resize B.
    destroy_a: bool = false,
    resize: bool = false,
    /// No Mica, no extended frame, standard caption: the frame-rate control.
    plain: bool = false,
    /// `Present` sync interval (1 = vsync).
    sync: u32 = 1,
    style_off: StyleOff = .none,
    seconds: u32 = 8,
};

var cfg: Cfg = .{};
var arg_buf: [4096]u8 = undefined;
var log_path_w: [520:0]u16 = @splat(0);
var log_file: ?foundation.HANDLE = null;
var start_ms: u64 = 0;

var hinst: ?foundation.HINSTANCE = null;
var top_a: ?HWND = null;
var top_b: ?HWND = null;
var child: ?HWND = null;
var gfx: ?Gfx = null;
var painter: ?Painter = null;
var moved: bool = false;
var destroyed: bool = false;
var resized: bool = false;
var quit: bool = false;
var hover_max: bool = false;
var tracking: bool = false;

/// Where the UI thread is, for the watchdog: a window message id (child
/// messages or'ed with 0x10000000), or one of the `stage_*` markers.
var stage = std.atomic.Value(u32).init(0);
var heartbeat = std.atomic.Value(u64).init(0);
const stage_present: u32 = 0xF0000001;
const stage_peek: u32 = 0xF0000002;
const stage_idle: u32 = 0xF0000003;

fn watchdog() void {
    var last = heartbeat.load(.monotonic);
    while (true) {
        Sleep(1000);
        const now = heartbeat.load(.monotonic);
        if (now == last) logf("hang stage=0x{x}", .{stage.load(.monotonic)});
        last = now;
    }
}

var frames: u64 = 0;
var occluded: u64 = 0;
var errors: u64 = 0;
var first_error: HRESULT = 0;

fn logf(comptime fmt: []const u8, args: anytype) void {
    const file = log_file orelse return;
    var buf: [640]u8 = undefined;
    const head = std.fmt.bufPrint(&buf, "[{d:>6}] ", .{kernel32.GetTickCount64() - start_ms}) catch return;
    const body = std.fmt.bufPrint(buf[head.len..], fmt ++ "\n", args) catch return;
    var written: u32 = 0;
    _ = kernel32.WriteFile(file, &buf, @intCast(head.len + body.len), &written, null);
}

fn fatal(what: []const u8, err: anyerror) noreturn {
    logf("fatal what={s} err={s}", .{ what, @errorName(err) });
    ExitProcess(2);
}

fn parseArgs() void {
    const cmd = std.mem.span(GetCommandLineW());
    const n = std.unicode.utf16LeToUtf8(&arg_buf, cmd) catch return;
    var it = std.mem.tokenizeScalar(u8, arg_buf[0..n], ' ');
    _ = it.next(); // exe path
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--variant=dc")) {
            cfg.variant = .dc;
        } else if (std.mem.eql(u8, arg, "--variant=none")) {
            cfg.variant = .none;
        } else if (std.mem.eql(u8, arg, "--no-buttons")) {
            cfg.no_buttons = true;
        } else if (std.mem.eql(u8, arg, "--destroy-a")) {
            cfg.destroy_a = true;
        } else if (std.mem.eql(u8, arg, "--resize")) {
            cfg.resize = true;
        } else if (std.mem.eql(u8, arg, "--reparent")) {
            cfg.reparent = true;
        } else if (std.mem.eql(u8, arg, "--style-off=sysmenu")) {
            cfg.style_off = .sysmenu;
        } else if (std.mem.eql(u8, arg, "--style-off=caption")) {
            cfg.style_off = .caption;
        } else if (std.mem.startsWith(u8, arg, "--sync=")) {
            cfg.sync = std.fmt.parseInt(u32, arg["--sync=".len..], 10) catch 1;
        } else if (std.mem.eql(u8, arg, "--plain")) {
            cfg.plain = true;
        } else if (std.mem.startsWith(u8, arg, "--seconds=")) {
            cfg.seconds = std.fmt.parseInt(u32, arg["--seconds=".len..], 10) catch 8;
        } else if (std.mem.startsWith(u8, arg, "--log=")) {
            const len = std.unicode.utf8ToUtf16Le(&log_path_w, arg["--log=".len..]) catch 0;
            log_path_w[len] = 0;
        }
    }
}

fn openLog() void {
    if (log_path_w[0] == 0) return;
    const h = kernel32.CreateFileW(&log_path_w, kernel32.GENERIC_WRITE, FILE_SHARE_RW, null, CREATE_ALWAYS, 0, null);
    if (h != kernel32.INVALID_HANDLE_VALUE) log_file = h;
}

// -- Layout --------------------------------------------------------------------

const Layout = struct {
    scale: f32,
    client_w: i32,
    client_h: i32,
    strip_h: i32,
    button_w: i32,
    tab: RECT,
    min: RECT,
    max: RECT,
    close: RECT,
    /// Width of the invisible resize band along the top edge.
    top_band: i32,
};

fn px(dip: i32, scale: f32) i32 {
    return @intFromFloat(@round(@as(f32, @floatFromInt(dip)) * scale));
}

fn layoutFor(hwnd: HWND) Layout {
    const scale = @as(f32, @floatFromInt(user32.GetDpiForWindow(hwnd))) / 96.0;
    var rc: RECT = undefined;
    _ = user32.GetClientRect(hwnd, &rc);
    const strip_h = px(strip_dip, scale);
    const bw = px(button_dip, scale);
    const w = rc.right;
    return .{
        .scale = scale,
        .client_w = w,
        .client_h = rc.bottom,
        .strip_h = strip_h,
        .button_w = bw,
        .tab = .{ .left = px(8, scale), .top = px(6, scale), .right = px(168, scale), .bottom = strip_h },
        .min = .{ .left = w - 3 * bw, .top = 0, .right = w - 2 * bw, .bottom = strip_h },
        .max = .{ .left = w - 2 * bw, .top = 0, .right = w - bw, .bottom = strip_h },
        .close = .{ .left = w - bw, .top = 0, .right = w, .bottom = strip_h },
        .top_band = px(4, scale),
    };
}

fn inRect(r: RECT, x: i32, y: i32) bool {
    return x >= r.left and x < r.right and y >= r.top and y < r.bottom;
}

/// Size of the sizing frame the maximized window overhangs the monitor by.
fn frameInset(dpi: u32) i32 {
    return user32.GetSystemMetricsForDpi(user32.SM_CYFRAME, dpi) +
        user32.GetSystemMetricsForDpi(user32.SM_CXPADDEDBORDER, dpi);
}

// -- Direct3D: the child's flip-model swap chain -------------------------------

const Gfx = struct {
    device: *d3d11.ID3D11Device,
    context: *d3d11.ID3D11DeviceContext,
    swap: *dxgi.IDXGISwapChain1,
    rtv: ?*d3d11.ID3D11RenderTargetView = null,

    fn init(hwnd: HWND, w: u32, h: u32) !Gfx {
        const created = try d3d11.createDevice(.hardware, .{ .bgra_support = true });
        const factory = try dxgi.createFactory(false);
        defer com.release(factory);
        const desc: dxgi.SWAP_CHAIN_DESC1 = .{
            .Width = w,
            .Height = h,
            .Format = .B8G8R8A8_UNORM,
            .BufferUsage = dxgi.USAGE_RENDER_TARGET_OUTPUT,
            .BufferCount = 2,
            .Scaling = .STRETCH,
            .SwapEffect = .FLIP_DISCARD,
            .AlphaMode = .IGNORE,
            .Flags = 0,
        };
        const swap = try factory.createSwapChainForHwnd(created.device, hwnd, &desc);
        var g: Gfx = .{ .device = created.device, .context = created.context, .swap = swap };
        try g.createRtv();
        return g;
    }

    fn createRtv(self: *Gfx) !void {
        const tex = try self.swap.asSwapChain().getBuffer(0, d3d11.ID3D11Texture2D);
        defer com.release(tex);
        self.rtv = try self.device.createRenderTargetView(tex.asResource(), null);
    }

    fn resize(self: *Gfx, w: u32, h: u32) !void {
        self.context.omSetRenderTargets(&[_]?*d3d11.ID3D11RenderTargetView{null});
        com.release(self.rtv);
        self.rtv = null;
        try self.swap.asSwapChain().resizeBuffers(0, w, h, .UNKNOWN, 0);
        try self.createRtv();
    }

    /// Clears and presents one frame; returns the raw `Present` HRESULT.
    fn frame(self: *Gfx, color: [4]f32, sync: u32) HRESULT {
        const rtv = self.rtv orelse return foundation.E_FAIL;
        self.context.omSetRenderTargets(&[_]?*d3d11.ID3D11RenderTargetView{rtv});
        self.context.clearRenderTargetView(rtv, color);
        const sc = self.swap.asSwapChain();
        return sc.vtable.Present(sc, sync, 0);
    }
};

// -- Direct2D strip painter ('dc' backend) ---------------------------------------

const Painter = struct {
    factory: *d2d1.ID2D1Factory,
    dw: *dwrite.IDWriteFactory,
    target: *d2d1.ID2D1DCRenderTarget,
    ui_format: *dwrite.IDWriteTextFormat,
    icon_format: *dwrite.IDWriteTextFormat,

    fn init(scale: f32) !Painter {
        const factory = try d2d1.createFactory();
        const dw = try dwrite.createFactory();
        const target = try factory.createDCRenderTarget(.{
            .type = .SOFTWARE,
            .pixelFormat = .{ .format = .B8G8R8A8_UNORM, .alphaMode = .PREMULTIPLIED },
            .dpiX = 96,
            .dpiY = 96,
        });
        const ui = try dw.createTextFormat(L("Segoe UI"), .NORMAL, .NORMAL, .NORMAL, 14 * scale, L("en-us"));
        try ui.setWordWrapping(.NO_WRAP);
        try ui.setTextAlignment(.LEADING);
        try ui.setParagraphAlignment(.CENTER);
        const icon = try dw.createTextFormat(L("Segoe Fluent Icons"), .NORMAL, .NORMAL, .NORMAL, 10 * scale, L("en-us"));
        try icon.setWordWrapping(.NO_WRAP);
        try icon.setTextAlignment(.CENTER);
        try icon.setParagraphAlignment(.CENTER);
        return .{ .factory = factory, .dw = dw, .target = target, .ui_format = ui, .icon_format = icon };
    }

    fn text(self: *Painter, rt: *d2d1.ID2D1RenderTarget, comptime utf8: []const u8, format: *dwrite.IDWriteTextFormat, r: RECT, brush: *d2d1.ID2D1Brush) !void {
        const s = L(utf8);
        const w: f32 = @floatFromInt(r.right - r.left);
        const h: f32 = @floatFromInt(r.bottom - r.top);
        const layout = try self.dw.createTextLayout(s, format, w, h);
        defer com.release(layout);
        rt.drawTextLayout(.{ .x = @floatFromInt(r.left), .y = @floatFromInt(r.top) }, layout, brush, d2d1.DRAW_TEXT_OPTIONS_NONE);
    }

    fn paint(self: *Painter, hdc: HDC, lay: Layout) !void {
        try self.target.bindDC(hdc, .{ .left = 0, .top = 0, .right = lay.client_w, .bottom = lay.strip_h });
        const rt = self.target.asRenderTarget();
        const tab_brush = try rt.createSolidColorBrush(.{ .r = 16.0 / 255.0, .g = 32.0 / 255.0, .b = 48.0 / 255.0, .a = 1 });
        defer com.release(tab_brush);
        const ink = try rt.createSolidColorBrush(.{ .r = 0.92, .g = 0.92, .b = 0.92, .a = 1 });
        defer com.release(ink);
        const hover = try rt.createSolidColorBrush(.{ .r = 1, .g = 1, .b = 1, .a = 0.12 });
        defer com.release(hover);

        rt.beginDraw();
        rt.setTextAntialiasMode(.GRAYSCALE);
        rt.clear(.{ .r = 0, .g = 0, .b = 0, .a = 0 });
        const radius: f32 = 6 * lay.scale;
        rt.fillRoundedRectangle(.{
            .rect = .{
                .left = @floatFromInt(lay.tab.left),
                .top = @floatFromInt(lay.tab.top),
                .right = @floatFromInt(lay.tab.right),
                // Past the strip so only the top corners show as rounded.
                .bottom = @as(f32, @floatFromInt(lay.strip_h)) + radius,
            },
            .radiusX = radius,
            .radiusY = radius,
        }, tab_brush.asBrush());
        const pad = px(12, lay.scale);
        try self.text(rt, "Spike Tab", self.ui_format, .{
            .left = lay.tab.left + pad,
            .top = lay.tab.top,
            .right = lay.tab.right - pad,
            .bottom = lay.tab.bottom,
        }, ink.asBrush());
        if (!cfg.no_buttons) {
            if (hover_max) rt.fillRectangle(.{
                .left = @floatFromInt(lay.max.left),
                .top = @floatFromInt(lay.max.top),
                .right = @floatFromInt(lay.max.right),
                .bottom = @floatFromInt(lay.max.bottom),
            }, hover.asBrush());
            try self.text(rt, "\u{E921}", self.icon_format, lay.min, ink.asBrush());
            try self.text(rt, "\u{E922}", self.icon_format, lay.max, ink.asBrush());
            try self.text(rt, "\u{E8BB}", self.icon_format, lay.close, ink.asBrush());
        }
        try rt.endDraw();
    }
};

fn paintStrip(hwnd: HWND) void {
    var ps: user32.PAINTSTRUCT = undefined;
    const hdc = user32.BeginPaint(hwnd, &ps) orelse return;
    defer _ = user32.EndPaint(hwnd, &ps);
    if (cfg.variant != .dc) return;

    const lay = layoutFor(hwnd);
    if (painter == null) painter = Painter.init(lay.scale) catch |e| fatal("painter init", e);
    const rc: RECT = .{ .left = 0, .top = 0, .right = lay.client_w, .bottom = lay.strip_h };
    const params: BP_PAINTPARAMS = .{ .dwFlags = BPPF_ERASE };
    var mem: ?HDC = null;
    const hbp = BeginBufferedPaint(hdc, &rc, BPBF_TOPDOWNDIB, &params, &mem) orelse {
        logf("paint BeginBufferedPaint failed", .{});
        return;
    };
    painter.?.paint(mem.?, lay) catch |e| logf("paint failed err={s}", .{@errorName(e)});
    _ = EndBufferedPaint(hbp, 1);
}

fn invalidateStrip(hwnd: HWND) void {
    const lay = layoutFor(hwnd);
    const rc: RECT = .{ .left = 0, .top = 0, .right = lay.client_w, .bottom = lay.strip_h };
    _ = user32.InvalidateRect(hwnd, &rc, 1);
}

// -- Window procedures -----------------------------------------------------------

fn childProc(hwnd: HWND, msg: u32, wp: foundation.WPARAM, lp: foundation.LPARAM) callconv(.winapi) foundation.LRESULT {
    const saved = stage.swap(0x10000000 | msg, .monotonic);
    defer stage.store(saved, .monotonic);
    switch (msg) {
        user32.WM_ERASEBKGND => return 1,
        user32.WM_SIZE => {
            if (gfx) |*g| {
                const w: u32 = @max(1, user32.loWord(@bitCast(lp)));
                const h: u32 = @max(1, user32.hiWord(@bitCast(lp)));
                g.resize(w, h) catch |e| logf("resize failed err={s}", .{@errorName(e)});
            }
            return 0;
        },
        else => return user32.DefWindowProcW(hwnd, msg, wp, lp),
    }
}

fn placeChild(parent: HWND) void {
    const c = child orelse return;
    const lay = layoutFor(parent);
    _ = user32.MoveWindow(c, 0, lay.strip_h, lay.client_w, @max(1, lay.client_h - lay.strip_h), 1);
}

fn topProc(hwnd: HWND, msg: u32, wp: foundation.WPARAM, lp: foundation.LPARAM) callconv(.winapi) foundation.LRESULT {
    const saved = stage.swap(msg, .monotonic);
    defer stage.store(saved, .monotonic);
    switch (msg) {
        user32.WM_NCCALCSIZE => {
            if (wp == 0 or cfg.plain) return user32.DefWindowProcW(hwnd, msg, wp, lp);
            // Keep the standard side and bottom frames, drop the caption: the
            // client keeps the window's original top edge.
            const params: *user32.NCCALCSIZE_PARAMS = @ptrFromInt(@as(usize, @bitCast(lp)));
            const orig_top = params.rgrc[0].top;
            const res = user32.DefWindowProcW(hwnd, msg, wp, lp);
            if (res != 0) return res;
            // A maximized window overhangs the monitor by the sizing frame;
            // the top of the client must stay on screen.
            params.rgrc[0].top = if (user32.IsZoomed(hwnd) != 0)
                orig_top + frameInset(user32.GetDpiForWindow(hwnd))
            else
                orig_top;
            return 0;
        },
        user32.WM_NCHITTEST => {
            const res = user32.DefWindowProcW(hwnd, msg, wp, lp);
            if (res != user32.HTCLIENT or cfg.plain) return res;
            var pt: foundation.POINT = .{ .x = user32.getXLparam(lp), .y = user32.getYLparam(lp) };
            _ = user32.ScreenToClient(hwnd, &pt);
            const lay = layoutFor(hwnd);
            if (user32.IsZoomed(hwnd) == 0 and pt.y < lay.top_band) {
                if (pt.x < lay.top_band * 3) return user32.HTTOPLEFT;
                if (pt.x >= lay.client_w - lay.top_band * 3) return user32.HTTOPRIGHT;
                return user32.HTTOP;
            }
            if (pt.y < lay.strip_h) {
                if (!cfg.no_buttons) {
                    if (inRect(lay.close, pt.x, pt.y)) return user32.HTCLOSE;
                    if (inRect(lay.max, pt.x, pt.y)) return user32.HTMAXBUTTON;
                    if (inRect(lay.min, pt.x, pt.y)) return user32.HTMINBUTTON;
                }
                if (inRect(lay.tab, pt.x, pt.y)) return user32.HTCLIENT;
                return user32.HTCAPTION;
            }
            return user32.HTCLIENT;
        },
        user32.WM_NCMOUSEMOVE => {
            const over: bool = wp == user32.HTMAXBUTTON;
            if (over and !tracking) {
                var tme: user32.TRACKMOUSEEVENT = .{ .dwFlags = user32.TME_LEAVE | user32.TME_NONCLIENT, .hwndTrack = hwnd };
                _ = user32.TrackMouseEvent(&tme);
                tracking = true;
            }
            if (over != hover_max) {
                hover_max = over;
                invalidateStrip(hwnd);
            }
            return user32.DefWindowProcW(hwnd, msg, wp, lp);
        },
        user32.WM_NCMOUSELEAVE => {
            tracking = false;
            if (hover_max) {
                hover_max = false;
                invalidateStrip(hwnd);
            }
            return 0;
        },
        user32.WM_SYSCOMMAND => {
            // A lone Alt tap (the harness's foreground trick) would start the
            // system menu's modal loop and freeze the UI thread: swallow it.
            if ((wp & 0xFFF0) == sc_keymenu and lp == 0) return 0;
            return user32.DefWindowProcW(hwnd, msg, wp, lp);
        },
        user32.WM_NCLBUTTONDOWN => {
            if (wp == user32.HTMAXBUTTON or wp == user32.HTMINBUTTON or wp == user32.HTCLOSE) return 0;
            return user32.DefWindowProcW(hwnd, msg, wp, lp);
        },
        user32.WM_NCLBUTTONUP => {
            switch (wp) {
                user32.HTMAXBUTTON => {
                    _ = user32.ShowWindow(hwnd, if (user32.IsZoomed(hwnd) != 0) user32.SW_RESTORE else user32.SW_MAXIMIZE);
                    return 0;
                },
                user32.HTMINBUTTON => {
                    _ = user32.ShowWindow(hwnd, user32.SW_MINIMIZE);
                    return 0;
                },
                user32.HTCLOSE => {
                    _ = user32.PostMessageW(hwnd, user32.WM_CLOSE, 0, 0);
                    return 0;
                },
                else => return user32.DefWindowProcW(hwnd, msg, wp, lp),
            }
        },
        user32.WM_SIZE => {
            if (wp != user32.SIZE_MINIMIZED) {
                if (child) |c| {
                    if (user32.GetParent(c) == hwnd) placeChild(hwnd);
                }
                invalidateStrip(hwnd);
            }
            return 0;
        },
        user32.WM_PAINT => {
            paintStrip(hwnd);
            return 0;
        },
        user32.WM_CLOSE => {
            quit = true;
            return 0;
        },
        else => return user32.DefWindowProcW(hwnd, msg, wp, lp),
    }
}

fn topStyle() u32 {
    var style: u32 = user32.WS_OVERLAPPEDWINDOW | user32.WS_CLIPCHILDREN;
    switch (cfg.style_off) {
        .none => {},
        .sysmenu => style &= ~@as(u32, user32.WS_SYSMENU),
        .caption => style &= ~@as(u32, user32.WS_CAPTION),
    }
    return style | user32.WS_THICKFRAME;
}

fn createTop(name: []const u8, title: [*:0]const u16, x: i32, y: i32, w: i32, h: i32) HWND {
    const hwnd = user32.CreateWindowExW(
        0,
        L("ChromeSpikeTop"),
        title,
        topStyle(),
        x,
        y,
        w,
        h,
        null,
        null,
        hinst,
        null,
    ) orelse fatal("CreateWindowExW top", error.CreateWindow);

    // Topmost so nothing else on the desktop overlaps the screen captures.
    _ = user32.SetWindowPos(hwnd, user32.HWND_TOPMOST, 0, 0, 0, 0, user32.SWP_NOMOVE | user32.SWP_NOSIZE | user32.SWP_NOACTIVATE);
    if (cfg.plain) {
        logf("window name={s} hwnd=0x{x} plain", .{ name, @intFromPtr(hwnd) });
        return hwnd;
    }
    const dark: u32 = 1;
    _ = dwmapi.DwmSetWindowAttribute(hwnd, dwmapi.DWMWA_USE_IMMERSIVE_DARK_MODE, &dark, @sizeOf(u32));
    const backdrop: u32 = dwmapi.DWMSBT_MAINWINDOW;
    const hr_backdrop = dwmapi.DwmSetWindowAttribute(hwnd, dwmapi.DWMWA_SYSTEMBACKDROP_TYPE, &backdrop, @sizeOf(u32));
    const lay = layoutFor(hwnd);
    const margins: dwmapi.MARGINS = .{ .cxLeftWidth = 0, .cxRightWidth = 0, .cyTopHeight = lay.strip_h, .cyBottomHeight = 0 };
    const hr_extend = dwmapi.DwmExtendFrameIntoClientArea(hwnd, &margins);
    // Re-run WM_NCCALCSIZE now that the handler and the frame are set up.
    _ = user32.SetWindowPos(hwnd, null, 0, 0, 0, 0, user32.SWP_NOMOVE | user32.SWP_NOSIZE | user32.SWP_NOZORDER | user32.SWP_NOACTIVATE | user32.SWP_FRAMECHANGED);
    logf("window name={s} hwnd=0x{x} backdrop_hr=0x{x} extend_hr=0x{x}", .{ name, @intFromPtr(hwnd), @as(u32, @bitCast(hr_backdrop)), @as(u32, @bitCast(hr_extend)) });
    return hwnd;
}

fn logGeometry(name: []const u8, hwnd: HWND) void {
    const lay = layoutFor(hwnd);
    var origin: foundation.POINT = .{ .x = 0, .y = 0 };
    _ = user32.ClientToScreen(hwnd, &origin);
    var wr: RECT = undefined;
    _ = user32.GetWindowRect(hwnd, &wr);
    logf("geometry name={s} dpi={d} client={d},{d},{d},{d} window={d},{d},{d},{d} strip_h={d} button_w={d} tab={d},{d},{d},{d} inset={d}", .{
        name,
        user32.GetDpiForWindow(hwnd),
        origin.x,
        origin.y,
        lay.client_w,
        lay.client_h,
        wr.left,
        wr.top,
        wr.right,
        wr.bottom,
        lay.strip_h,
        lay.button_w,
        lay.tab.left,
        lay.tab.top,
        lay.tab.right,
        lay.tab.bottom,
        frameInset(user32.GetDpiForWindow(hwnd)),
    });
}

fn registerClasses() void {
    const arrow = user32.LoadCursorW(null, user32.IDC_ARROW);
    const black: ?*anyopaque = gdi32.GetStockObject(gdi32.BLACK_BRUSH);
    const top: user32.WNDCLASSEXW = .{
        .style = user32.CS_HREDRAW | user32.CS_VREDRAW,
        .lpfnWndProc = &topProc,
        .hInstance = hinst,
        .hCursor = arrow,
        // Black is the colour DWM shows as glass inside the extended frame.
        .hbrBackground = @ptrCast(black),
        .lpszClassName = L("ChromeSpikeTop"),
    };
    if (user32.RegisterClassExW(&top) == 0) fatal("RegisterClassExW top", error.RegisterClass);
    const kid: user32.WNDCLASSEXW = .{
        .lpfnWndProc = &childProc,
        .hInstance = hinst,
        .hCursor = arrow,
        .lpszClassName = L("ChromeSpikeChild"),
    };
    if (user32.RegisterClassExW(&kid) == 0) fatal("RegisterClassExW child", error.RegisterClass);
}

fn doReparent() void {
    const c = child.?;
    const before = frames;
    const b = createTop("b", L("Chrome Spike B"), 160, 120, 900, 600);
    top_b = b;
    _ = user32.ShowWindow(b, user32.SW_SHOW);
    _ = user32.SetForegroundWindow(b);
    logGeometry("b", b);

    const prev = user32.SetParent(c, b);
    const err = kernel32.GetLastError();
    moved = true;
    placeChild(b);
    _ = user32.ShowWindow(c, user32.SW_SHOW);
    logf("reparent prev=0x{x} last_error={d} frames_before={d} child_parent=0x{x}", .{
        if (prev) |p| @intFromPtr(p) else 0,
        err,
        before,
        if (user32.GetParent(c)) |p| @intFromPtr(p) else 0,
    });
    logGeometry("b", b);
}

pub fn main() u8 {
    start_ms = kernel32.GetTickCount64();
    parseArgs();
    openLog();
    logf("start variant={s} no_buttons={} reparent={} plain={} sync={d} style_off={s} seconds={d}", .{ @tagName(cfg.variant), cfg.no_buttons, cfg.reparent, cfg.plain, cfg.sync, @tagName(cfg.style_off), cfg.seconds });
    _ = SetProcessDpiAwarenessContext(DPI_PER_MONITOR_V2);
    _ = BufferedPaintInit();
    defer _ = BufferedPaintUnInit();
    hinst = kernel32.GetModuleHandleW(null);
    registerClasses();

    const a = createTop("a", L("Chrome Spike A"), 100, 100, 900, 600);
    top_a = a;
    const lay = layoutFor(a);
    child = user32.CreateWindowExW(
        0,
        L("ChromeSpikeChild"),
        L(""),
        user32.WS_CHILD | user32.WS_VISIBLE | user32.WS_CLIPSIBLINGS,
        0,
        lay.strip_h,
        lay.client_w,
        @max(1, lay.client_h - lay.strip_h),
        a,
        null,
        hinst,
        null,
    ) orelse fatal("CreateWindowExW child", error.CreateWindow);
    var kid_rc: RECT = undefined;
    _ = user32.GetClientRect(child.?, &kid_rc);
    gfx = Gfx.init(child.?, @intCast(@max(1, kid_rc.right)), @intCast(@max(1, kid_rc.bottom))) catch |e| fatal("Gfx.init", e);

    _ = user32.ShowWindow(a, user32.SW_SHOW);
    _ = user32.UpdateWindow(a);
    _ = user32.SetForegroundWindow(a);
    logGeometry("a", a);
    logf("ready", .{});
    _ = std.Thread.spawn(.{}, watchdog, .{}) catch |e| fatal("spawn watchdog", e);

    var next_stat: u64 = 1000;
    var msg: user32.MSG = .{};
    while (!quit) {
        _ = heartbeat.fetchAdd(1, .monotonic);
        stage.store(stage_peek, .monotonic);
        while (user32.PeekMessageW(&msg, null, 0, 0, user32.PM_REMOVE) != 0) {
            _ = user32.TranslateMessage(&msg);
            _ = user32.DispatchMessageW(&msg);
        }
        const now = kernel32.GetTickCount64() - start_ms;
        if (now >= @as(u64, cfg.seconds) * 1000) break;
        if (cfg.reparent and !moved and now >= 3000) doReparent();
        if (moved and cfg.destroy_a and !destroyed and now >= 4500) {
            _ = user32.DestroyWindow(top_a.?);
            top_a = null;
            destroyed = true;
            logf("destroyed_a frames={d}", .{frames});
        }
        if (moved and cfg.resize and !resized and now >= 5500) {
            _ = user32.SetWindowPos(top_b.?, null, 0, 0, 1100, 700, user32.SWP_NOMOVE | user32.SWP_NOZORDER | user32.SWP_NOACTIVATE);
            resized = true;
            logf("resized frames={d}", .{frames});
            logGeometry("b", top_b.?);
        }

        const t_present = kernel32.GetTickCount64();
        stage.store(stage_present, .monotonic);
        const hr = gfx.?.frame(if (moved) moved_color else child_color, cfg.sync);
        stage.store(stage_idle, .monotonic);
        const present_ms = kernel32.GetTickCount64() - t_present;
        if (present_ms > 200) logf("slow_present ms={d} frames={d}", .{ present_ms, frames });
        if (hr == STATUS_OCCLUDED) {
            occluded += 1;
            Sleep(10);
        } else if (foundation.succeeded(hr)) {
            frames += 1;
        } else {
            errors += 1;
            if (first_error == 0) first_error = hr;
            if (errors <= 5) logf("present_error hr=0x{x} frames={d}", .{ @as(u32, @bitCast(hr)), frames });
            Sleep(10);
        }
        if (now >= next_stat) {
            logf("stat frames={d} occluded={d} errors={d} moved={}", .{ frames, occluded, errors, moved });
            next_stat += 1000;
        }
    }
    logf("done frames={d} occluded={d} errors={d} first_error=0x{x}", .{ frames, occluded, errors, @as(u32, @bitCast(first_error)) });
    return if (errors == 0) 0 else 1;
}
