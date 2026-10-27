//! WARNING: this spike captures the screen (through run.ps1) and is not guarded; run it only on a clear desktop.
//! Composition spike (risk R10). A standalone GUI exe, not Ghostty: a top-level
//! window with a dropped caption, a DirectComposition target on a child HWND
//! that shows a premultiplied composition swap chain presented from a worker
//! thread, and a striped backdrop window behind everything so transparency is
//! measurable. Each `--mode` answers some of the checks (a)-(l) of M3 Task 8
//! and logs `CHECK-PASS|CHECK-FAIL|INFO (x) ...` lines; screen captures are
//! taken in-process (only the spike's own windows are on screen under the
//! full-monitor backdrop) and saved as BMP next to the log. run.ps1 drives it.
//!
//! Flags: --mode=transparent|pacing|reparent|cycle|tearing|devrecreate|memory
//!        --backdrop=ext|blur|both  --sbt=none|acrylic  --quick
//!        --out=DIR --log=PATH --go=PATH (wait for this file before the checks)
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
const dcomp = win32.dcomp;
const com = win32.com;
const foundation = win32.foundation;
const HWND = foundation.HWND;
const HRESULT = foundation.HRESULT;
const RECT = foundation.RECT;
const HDC = user32.HDC;

const L = std.unicode.utf8ToUtf16LeStringLiteral;
const alloc = std.heap.page_allocator;

// Buffered paint, declared here like in the chrome spike (Task 18 binds it).
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
extern "kernel32" fn QueryPerformanceCounter(*i64) callconv(.winapi) foundation.BOOL;
extern "kernel32" fn QueryPerformanceFrequency(*i64) callconv(.winapi) foundation.BOOL;
extern "kernel32" fn GetFileAttributesW([*:0]const u16) callconv(.winapi) u32;
extern "user32" fn SetProcessDpiAwarenessContext(ctx: isize) callconv(.winapi) foundation.BOOL;
extern "user32" fn PrintWindow(HWND, HDC, flags: u32) callconv(.winapi) foundation.BOOL;
extern "gdi32" fn BitBlt(HDC, x: i32, y: i32, w: i32, h: i32, HDC, sx: i32, sy: i32, rop: u32) callconv(.winapi) foundation.BOOL;
extern "advapi32" fn RegGetValueW(hkey: usize, sub: [*:0]const u16, value: [*:0]const u16, flags: u32, ty: ?*u32, data: ?*anyopaque, size: ?*u32) callconv(.winapi) i32;

const DPI_PER_MONITOR_V2: isize = -4;
const sc_keymenu = 0xF100;
const SRCCOPY_CAPTUREBLT: u32 = 0x00CC0020 | 0x40000000;
const PW_RENDERFULLCONTENT: u32 = 2;
const CREATE_ALWAYS = 2;
const FILE_SHARE_RW = 3;
const INVALID_FILE_ATTRIBUTES: u32 = 0xFFFFFFFF;
const DXGI_ERROR_INVALID_CALL: HRESULT = @bitCast(@as(u32, 0x887A0001));

const strip_dip = 40;
const SM_CXSCREEN = 0;
const SM_CYSCREEN = 1;

const Mode = enum { transparent, pacing, reparent, cycle, tearing, devrecreate, memory };
const Backdrop = enum { ext, blur, both };
const Sbt = enum { none, acrylic };

const Cfg = struct {
    mode: Mode = .transparent,
    backdrop: Backdrop = .ext,
    sbt: Sbt = .none,
    quick: bool = false,
    /// Child windows get `WS_EX_NOREDIRECTIONBITMAP` (no GDI surface under the visual).
    noredir: bool = false,
    /// The child erases itself with the black class brush (alpha 0 on a glass window)
    /// instead of leaving the parent surface under it untouched.
    child_black: bool = false,
};

var cfg: Cfg = .{};
var arg_buf: [4096]u8 = undefined;
var log_path_w: [520:0]u16 = @splat(0);
var go_path_w: [520:0]u16 = @splat(0);
var out_dir: [400]u8 = undefined;
var out_len: usize = 0;
var log_file: ?foundation.HANDLE = null;
var start_us: i64 = 0;
var qpf: i64 = 1;

var hinst: ?foundation.HINSTANCE = null;
var backdrop_wnd: ?HWND = null;
var quit = false;
var painter: ?Painter = null;

// -- Logging and time -------------------------------------------------------------

fn nowUs() i64 {
    var c: i64 = 0;
    _ = QueryPerformanceCounter(&c);
    return @divFloor(c, qpf) * 1_000_000 + @divFloor(@mod(c, qpf) * 1_000_000, qpf);
}

fn logf(comptime fmt: []const u8, args: anytype) void {
    const file = log_file orelse return;
    var buf: [900]u8 = undefined;
    const head = std.fmt.bufPrint(&buf, "[{d:>6}] ", .{@divFloor(nowUs() - start_us, 1000)}) catch return;
    const body = std.fmt.bufPrint(buf[head.len..], fmt ++ "\n", args) catch return;
    var written: u32 = 0;
    _ = kernel32.WriteFile(file, &buf, @intCast(head.len + body.len), &written, null);
}

/// A recorded check: PASS/FAIL, or INFO for a measurement (`ok` null).
fn report(id: []const u8, ok: ?bool, comptime fmt: []const u8, args: anytype) void {
    const tag: []const u8 = if (ok) |v| (if (v) "CHECK-PASS" else "CHECK-FAIL") else "INFO";
    var buf: [700]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt, args) catch "(too long)";
    logf("{s} ({s}) {s}", .{ tag, id, text });
}

fn fatal(what: []const u8, err: anyerror) noreturn {
    logf("fatal what={s} err={s}", .{ what, @errorName(err) });
    ExitProcess(2);
}

fn hrU(hr: HRESULT) u32 {
    return @bitCast(hr);
}

fn parseArgs() void {
    const cmd = std.mem.span(GetCommandLineW());
    const n = std.unicode.utf16LeToUtf8(&arg_buf, cmd) catch return;
    var it = std.mem.tokenizeScalar(u8, arg_buf[0..n], ' ');
    _ = it.next(); // exe path
    while (it.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--mode=")) {
            cfg.mode = std.meta.stringToEnum(Mode, arg["--mode=".len..]) orelse .transparent;
        } else if (std.mem.startsWith(u8, arg, "--backdrop=")) {
            cfg.backdrop = std.meta.stringToEnum(Backdrop, arg["--backdrop=".len..]) orelse .ext;
        } else if (std.mem.startsWith(u8, arg, "--sbt=")) {
            cfg.sbt = std.meta.stringToEnum(Sbt, arg["--sbt=".len..]) orelse .none;
        } else if (std.mem.eql(u8, arg, "--childblack")) {
            cfg.child_black = true;
        } else if (std.mem.eql(u8, arg, "--noredir")) {
            cfg.noredir = true;
        } else if (std.mem.eql(u8, arg, "--quick")) {
            cfg.quick = true;
        } else if (std.mem.startsWith(u8, arg, "--out=")) {
            const v = arg["--out=".len..];
            out_len = @min(v.len, out_dir.len);
            @memcpy(out_dir[0..out_len], v[0..out_len]);
        } else if (std.mem.startsWith(u8, arg, "--log=")) {
            const len = std.unicode.utf8ToUtf16Le(&log_path_w, arg["--log=".len..]) catch 0;
            log_path_w[len] = 0;
        } else if (std.mem.startsWith(u8, arg, "--go=")) {
            const len = std.unicode.utf8ToUtf16Le(&go_path_w, arg["--go=".len..]) catch 0;
            go_path_w[len] = 0;
        }
    }
}

fn openLog() void {
    if (log_path_w[0] == 0) return;
    const h = kernel32.CreateFileW(&log_path_w, kernel32.GENERIC_WRITE, FILE_SHARE_RW, null, CREATE_ALWAYS, 0, null);
    if (h != kernel32.INVALID_HANDLE_VALUE) log_file = h;
}

fn pump(ms: u32) void {
    const end = nowUs() + @as(i64, ms) * 1000;
    var msg: user32.MSG = .{};
    while (nowUs() < end) {
        while (user32.PeekMessageW(&msg, null, 0, 0, user32.PM_REMOVE) != 0) {
            _ = user32.TranslateMessage(&msg);
            _ = user32.DispatchMessageW(&msg);
        }
        Sleep(1);
    }
}

fn waitGo() void {
    if (go_path_w[0] == 0) return;
    var waited: u32 = 0;
    while (GetFileAttributesW(&go_path_w) == INVALID_FILE_ATTRIBUTES and waited < 20000) : (waited += 20) pump(20);
    logf("go waited_ms={d}", .{waited});
}

fn privateMb() f64 {
    var c: kernel32.PROCESS_MEMORY_COUNTERS_EX = .{};
    _ = kernel32.K32GetProcessMemoryInfo(kernel32.GetCurrentProcess(), &c, @sizeOf(kernel32.PROCESS_MEMORY_COUNTERS_EX));
    return @as(f64, @floatFromInt(c.PrivateUsage)) / (1024.0 * 1024.0);
}

fn transparencyEffects() i64 {
    var v: u32 = 0xFFFF;
    var size: u32 = 4;
    const hkcu: usize = 0x80000001;
    const rc = RegGetValueW(hkcu, L("Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize"), L("EnableTransparency"), 0x10, null, &v, &size);
    return if (rc == 0) @as(i64, v) else -1;
}

// -- Images -----------------------------------------------------------------------

const Rgb = struct { r: u8, g: u8, b: u8 };

const Image = struct {
    w: i32,
    h: i32,
    /// Client (0,0) sits at (ox, oy) of the bitmap.
    ox: i32,
    oy: i32,
    px: []u32,

    fn at(self: Image, x: i32, y: i32) Rgb {
        const p = self.px[@intCast((y + self.oy) * self.w + (x + self.ox))];
        return .{ .r = @truncate(p >> 16), .g = @truncate(p >> 8), .b = @truncate(p) };
    }

    fn deinit(self: Image) void {
        alloc.free(self.px);
    }
};

const Dib = struct {
    mem: HDC,
    bmp: gdi32.HBITMAP,
    old: gdi32.HGDIOBJ,
    bits: [*]u32,

    fn create(screen: HDC, w: i32, h: i32) ?Dib {
        const mem = gdi32.CreateCompatibleDC(screen) orelse return null;
        var bits: ?*anyopaque = null;
        const bi: gdi32.BITMAPINFO = .{ .bmiHeader = .{ .biWidth = w, .biHeight = -h, .biBitCount = 32 } };
        const bmp = gdi32.CreateDIBSection(screen, &bi, 0, &bits, null, 0) orelse {
            _ = gdi32.DeleteDC(mem);
            return null;
        };
        const old = gdi32.SelectObject(mem, @ptrCast(bmp)) orelse {
            _ = gdi32.DeleteObject(@ptrCast(bmp));
            _ = gdi32.DeleteDC(mem);
            return null;
        };
        return .{ .mem = mem, .bmp = bmp, .old = old, .bits = @ptrCast(@alignCast(bits.?)) };
    }

    fn destroy(self: Dib) void {
        _ = gdi32.SelectObject(self.mem, self.old);
        _ = gdi32.DeleteObject(@ptrCast(self.bmp));
        _ = gdi32.DeleteDC(self.mem);
    }
};

fn copyOut(dib: Dib, w: i32, h: i32, ox: i32, oy: i32) ?Image {
    const n: usize = @intCast(w * h);
    const pixels = alloc.alloc(u32, n) catch return null;
    @memcpy(pixels, dib.bits[0..n]);
    return .{ .w = w, .h = h, .ox = ox, .oy = oy, .px = pixels };
}

/// The composed screen content of the client area.
fn captureClient(g: Geo) ?Image {
    const screen = user32.GetDC(null) orelse return null;
    defer _ = user32.ReleaseDC(null, screen);
    const dib = Dib.create(screen, g.w, g.h) orelse return null;
    defer dib.destroy();
    _ = BitBlt(dib.mem, 0, 0, g.w, g.h, screen, g.cx, g.cy, SRCCOPY_CAPTUREBLT);
    return copyOut(dib, g.w, g.h, 0, 0);
}

/// `PrintWindow` of the whole top-level window; client (0,0) is offset by the frame.
fn capturePrintWindow(hwnd: HWND, g: Geo) ?Image {
    const ww = g.wr.right - g.wr.left;
    const wh = g.wr.bottom - g.wr.top;
    const screen = user32.GetDC(null) orelse return null;
    defer _ = user32.ReleaseDC(null, screen);
    const dib = Dib.create(screen, ww, wh) orelse return null;
    defer dib.destroy();
    @memset(dib.bits[0..@intCast(ww * wh)], 0xFFFF00FF); // magenta: never painted
    _ = PrintWindow(hwnd, dib.mem, PW_RENDERFULLCONTENT);
    return copyOut(dib, ww, wh, g.cx - g.wr.left, g.cy - g.wr.top);
}

fn saveBmp(name: []const u8, img: Image) void {
    var path: [520]u8 = undefined;
    const p = std.fmt.bufPrint(&path, "{s}\\{s}.bmp", .{ out_dir[0..out_len], name }) catch return;
    var wide: [520:0]u16 = @splat(0);
    const len = std.unicode.utf8ToUtf16Le(&wide, p) catch return;
    wide[len] = 0;
    const h = kernel32.CreateFileW(&wide, kernel32.GENERIC_WRITE, 0, null, CREATE_ALWAYS, 0, null);
    if (h == kernel32.INVALID_HANDLE_VALUE) return;
    defer _ = kernel32.CloseHandle(h);
    var hdr: [54]u8 = @splat(0);
    const data_len: u32 = @intCast(img.w * img.h * 4);
    hdr[0] = 'B';
    hdr[1] = 'M';
    std.mem.writeInt(u32, hdr[2..6], 54 + data_len, .little);
    std.mem.writeInt(u32, hdr[10..14], 54, .little);
    std.mem.writeInt(u32, hdr[14..18], 40, .little);
    std.mem.writeInt(i32, hdr[18..22], img.w, .little);
    std.mem.writeInt(i32, hdr[22..26], -img.h, .little);
    std.mem.writeInt(u16, hdr[26..28], 1, .little);
    std.mem.writeInt(u16, hdr[28..30], 32, .little);
    std.mem.writeInt(u32, hdr[34..38], data_len, .little);
    var written: u32 = 0;
    _ = kernel32.WriteFile(h, &hdr, 54, &written, null);
    _ = kernel32.WriteFile(h, @ptrCast(img.px.ptr), data_len, &written, null);
}

// -- Geometry and pixel analysis ---------------------------------------------------

const Geo = struct {
    cx: i32,
    cy: i32,
    w: i32,
    h: i32,
    strip_h: i32,
    scale: f32,
    wr: RECT,
};

fn scaleOf(hwnd: HWND) f32 {
    return @as(f32, @floatFromInt(user32.GetDpiForWindow(hwnd))) / 96.0;
}

fn px(dip: i32, scale: f32) i32 {
    return @intFromFloat(@round(@as(f32, @floatFromInt(dip)) * scale));
}

fn geoOf(hwnd: HWND) Geo {
    var rc: RECT = undefined;
    _ = user32.GetClientRect(hwnd, &rc);
    var origin: foundation.POINT = .{ .x = 0, .y = 0 };
    _ = user32.ClientToScreen(hwnd, &origin);
    var wr: RECT = undefined;
    _ = user32.GetWindowRect(hwnd, &wr);
    const scale = scaleOf(hwnd);
    return .{ .cx = origin.x, .cy = origin.y, .w = rc.right, .h = rc.bottom, .strip_h = px(strip_dip, scale), .scale = scale, .wr = wr };
}

// Backdrop stripes (6 px wide) and the swap-chain test pattern.
const stripe_a = Rgb{ .r = 192, .g = 48, .b = 48 };
const stripe_b = Rgb{ .r = 48, .g = 192, .b = 48 };
const pat_blue = Rgb{ .r = 16, .g = 32, .b = 192 };
const solid_a = Rgb{ .r = 16, .g = 32, .b = 48 }; // #102030
const solid_b = Rgb{ .r = 32, .g = 192, .b = 48 };
const tab_fill = Rgb{ .r = 16, .g = 32, .b = 48 };

fn near(a: Rgb, b: Rgb, tol: u8) bool {
    return @abs(@as(i32, a.r) - b.r) <= tol and @abs(@as(i32, a.g) - b.g) <= tol and @abs(@as(i32, a.b) - b.b) <= tol;
}

/// Premultiplied white at alpha 128 over `dst`.
fn halfWhiteOver(dst: Rgb) Rgb {
    const f = struct {
        fn c(d: u8) u8 {
            return @intCast(128 + @divTrunc(@as(u32, d) * 127, 255));
        }
    }.c;
    return .{ .r = f(dst.r), .g = f(dst.g), .b = f(dst.b) };
}

fn fmtRgb(c: Rgb, buf: *[8]u8) []const u8 {
    return std.fmt.bufPrint(buf, "#{X:0>2}{X:0>2}{X:0>2}", .{ c.r, c.g, c.b }) catch "?";
}

const Thirds = struct {
    left_ok: bool,
    mid_frac: f32,
    right_frac: f32,
    mid_sample: Rgb,
    left_sample: Rgb,
    right_sample: Rgb,
    sharpness: f32,

    fn visible(self: Thirds) bool {
        return self.left_ok and self.mid_frac >= 0.9 and self.right_frac >= 0.9;
    }
};

fn analyzeThirds(img: Image, g: Geo) Thirds {
    const ch = g.h - g.strip_h;
    const y = g.strip_h + @divTrunc(ch, 2);
    const t1 = @divTrunc(g.w, 3);
    const t2 = @divTrunc(g.w * 2, 3);
    var mid_hits: i32 = 0;
    var mid_n: i32 = 0;
    var x: i32 = t1 + 8;
    var sharp: i64 = 0;
    var prev = img.at(x, y);
    while (x < t2 - 8) : (x += 1) {
        const p = img.at(x, y);
        if (near(p, stripe_a, 14) or near(p, stripe_b, 14)) mid_hits += 1;
        mid_n += 1;
        sharp += @abs(@as(i32, p.r) - prev.r) + @abs(@as(i32, p.g) - prev.g) + @abs(@as(i32, p.b) - prev.b);
        prev = p;
    }
    var r_hits: i32 = 0;
    var r_n: i32 = 0;
    x = t2 + 8;
    while (x < g.w - 8) : (x += 1) {
        const p = img.at(x, y);
        if (near(p, halfWhiteOver(stripe_a), 14) or near(p, halfWhiteOver(stripe_b), 14)) r_hits += 1;
        r_n += 1;
    }
    const left = img.at(@divTrunc(g.w, 6), y);
    return .{
        .left_ok = near(left, pat_blue, 3),
        .mid_frac = @as(f32, @floatFromInt(mid_hits)) / @as(f32, @floatFromInt(@max(1, mid_n))),
        .right_frac = @as(f32, @floatFromInt(r_hits)) / @as(f32, @floatFromInt(@max(1, r_n))),
        .mid_sample = img.at(@divTrunc(g.w, 2), y),
        .left_sample = left,
        .right_sample = img.at(@divTrunc(g.w * 5, 6), y),
        .sharpness = @as(f32, @floatFromInt(sharp)) / @as(f32, @floatFromInt(@max(1, mid_n))),
    };
}

fn reportThirds(id: []const u8, label: []const u8, t: Thirds, require_through: bool) void {
    var b1: [8]u8 = undefined;
    var b2: [8]u8 = undefined;
    var b3: [8]u8 = undefined;
    report(id, if (require_through) t.visible() else null, "{s}: left={s} (blue {}) mid={s} stripes {d:.0}% right={s} stripes {d:.0}% sharpness {d:.1}", .{
        label,
        fmtRgb(t.left_sample, &b1),
        t.left_ok,
        fmtRgb(t.mid_sample, &b2),
        t.mid_frac * 100,
        fmtRgb(t.right_sample, &b3),
        t.right_frac * 100,
        t.sharpness,
    });
}

// -- Windows -----------------------------------------------------------------------

var active_render: ?*Renderer = null;

fn backdropProc(hwnd: HWND, msg: u32, wp: foundation.WPARAM, lp: foundation.LPARAM) callconv(.winapi) foundation.LRESULT {
    switch (msg) {
        user32.WM_ERASEBKGND => return 1,
        user32.WM_PAINT => {
            var ps: user32.PAINTSTRUCT = undefined;
            const hdc = user32.BeginPaint(hwnd, &ps) orelse return 0;
            defer _ = user32.EndPaint(hwnd, &ps);
            var rc: RECT = undefined;
            _ = user32.GetClientRect(hwnd, &rc);
            const ba = gdi32.CreateSolidBrush(@as(u32, stripe_a.b) << 16 | @as(u32, stripe_a.g) << 8 | stripe_a.r) orelse return 0;
            defer _ = gdi32.DeleteObject(@ptrCast(ba));
            const bb = gdi32.CreateSolidBrush(@as(u32, stripe_b.b) << 16 | @as(u32, stripe_b.g) << 8 | stripe_b.r) orelse return 0;
            defer _ = gdi32.DeleteObject(@ptrCast(bb));
            var x: i32 = 0;
            var odd = false;
            while (x < rc.right) : (x += 6) {
                const r: RECT = .{ .left = x, .top = 0, .right = x + 6, .bottom = rc.bottom };
                _ = gdi32.FillRect(hdc, &r, if (odd) bb else ba);
                odd = !odd;
            }
            return 0;
        },
        else => return user32.DefWindowProcW(hwnd, msg, wp, lp),
    }
}

fn childProc(hwnd: HWND, msg: u32, wp: foundation.WPARAM, lp: foundation.LPARAM) callconv(.winapi) foundation.LRESULT {
    switch (msg) {
        user32.WM_ERASEBKGND => return if (cfg.child_black) user32.DefWindowProcW(hwnd, msg, wp, lp) else 1,
        user32.WM_SIZE => {
            if (active_render) |r| {
                r.want_w.store(@max(1, user32.loWord(@bitCast(lp))), .release);
                r.want_h.store(@max(1, user32.hiWord(@bitCast(lp))), .release);
            }
            return 0;
        },
        else => return user32.DefWindowProcW(hwnd, msg, wp, lp),
    }
}

/// Size of the sizing frame a maximized window overhangs the monitor by.
fn frameInset(dpi: u32) i32 {
    return user32.GetSystemMetricsForDpi(user32.SM_CYFRAME, dpi) +
        user32.GetSystemMetricsForDpi(user32.SM_CXPADDEDBORDER, dpi);
}

fn placeChild(parent: HWND, child: HWND) void {
    const g = geoOf(parent);
    _ = user32.MoveWindow(child, 0, g.strip_h, g.w, @max(1, g.h - g.strip_h), 1);
}

/// The child belonging to a top-level window, for WM_SIZE placement.
var top_child: [2]struct { top: ?HWND = null, child: ?HWND = null } = .{ .{}, .{} };

fn topProc(hwnd: HWND, msg: u32, wp: foundation.WPARAM, lp: foundation.LPARAM) callconv(.winapi) foundation.LRESULT {
    switch (msg) {
        user32.WM_NCCALCSIZE => {
            if (wp == 0) return user32.DefWindowProcW(hwnd, msg, wp, lp);
            const params: *user32.NCCALCSIZE_PARAMS = @ptrFromInt(@as(usize, @bitCast(lp)));
            const orig_top = params.rgrc[0].top;
            const res = user32.DefWindowProcW(hwnd, msg, wp, lp);
            if (res != 0) return res;
            params.rgrc[0].top = if (user32.IsZoomed(hwnd) != 0)
                orig_top + frameInset(user32.GetDpiForWindow(hwnd))
            else
                orig_top;
            return 0;
        },
        user32.WM_SYSCOMMAND => {
            // The harness's Alt tap would start the system menu's modal loop.
            if ((wp & 0xFFF0) == sc_keymenu and lp == 0) return 0;
            return user32.DefWindowProcW(hwnd, msg, wp, lp);
        },
        user32.WM_SIZE => {
            if (wp != user32.SIZE_MINIMIZED) {
                for (top_child) |tc| {
                    if (tc.top == hwnd) {
                        if (tc.child) |c| if (user32.GetParent(c) == hwnd) placeChild(hwnd, c);
                    }
                }
                const g = geoOf(hwnd);
                const rc: RECT = .{ .left = 0, .top = 0, .right = g.w, .bottom = g.strip_h };
                _ = user32.InvalidateRect(hwnd, &rc, 1);
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

fn registerClasses() void {
    const arrow = user32.LoadCursorW(null, user32.IDC_ARROW);
    const black: ?*anyopaque = gdi32.GetStockObject(gdi32.BLACK_BRUSH);
    const bd: user32.WNDCLASSEXW = .{ .lpfnWndProc = &backdropProc, .hInstance = hinst, .hCursor = arrow, .lpszClassName = L("CompSpikeBackdrop") };
    if (user32.RegisterClassExW(&bd) == 0) fatal("RegisterClassExW backdrop", error.RegisterClass);
    const top: user32.WNDCLASSEXW = .{
        .style = user32.CS_HREDRAW | user32.CS_VREDRAW,
        .lpfnWndProc = &topProc,
        .hInstance = hinst,
        .hCursor = arrow,
        // Black is the colour DWM treats as glass in the extended frame.
        .hbrBackground = @ptrCast(black),
        .lpszClassName = L("CompSpikeTop"),
    };
    if (user32.RegisterClassExW(&top) == 0) fatal("RegisterClassExW top", error.RegisterClass);
    const kid: user32.WNDCLASSEXW = .{ .lpfnWndProc = &childProc, .hInstance = hinst, .hCursor = arrow, .hbrBackground = @ptrCast(black), .lpszClassName = L("CompSpikeChild") };
    if (user32.RegisterClassExW(&kid) == 0) fatal("RegisterClassExW child", error.RegisterClass);
}

/// Full-monitor striped window behind the test windows, so a capture of any
/// test window never contains anything but the spike's own windows.
fn createBackdropWindow() void {
    const sw = user32.GetSystemMetrics(SM_CXSCREEN);
    const sh = user32.GetSystemMetrics(SM_CYSCREEN);
    const w = user32.CreateWindowExW(
        user32.WS_EX_TOPMOST | user32.WS_EX_TOOLWINDOW | user32.WS_EX_NOACTIVATE,
        L("CompSpikeBackdrop"),
        L("Composition Spike Backdrop"),
        user32.WS_POPUP,
        0,
        0,
        sw,
        sh,
        null,
        null,
        hinst,
        null,
    ) orelse fatal("CreateWindowExW backdrop", error.CreateWindow);
    _ = user32.ShowWindow(w, user32.SW_SHOWNA);
    _ = user32.UpdateWindow(w);
    backdrop_wnd = w;
    logf("backdrop hwnd=0x{x} size={d}x{d}", .{ @intFromPtr(w), sw, sh });
}

fn applyFrame(hwnd: HWND, backdrop: Backdrop, sbt: Sbt) void {
    const dark: u32 = 1;
    _ = dwmapi.DwmSetWindowAttribute(hwnd, dwmapi.DWMWA_USE_IMMERSIVE_DARK_MODE, &dark, @sizeOf(u32));
    const kind: u32 = if (sbt == .acrylic) dwmapi.DWMSBT_TRANSIENTWINDOW else dwmapi.DWMSBT_NONE;
    const hr_sbt = dwmapi.DwmSetWindowAttribute(hwnd, dwmapi.DWMWA_SYSTEMBACKDROP_TYPE, &kind, @sizeOf(u32));
    var hr_ext: HRESULT = 1;
    if (backdrop == .ext or backdrop == .both) {
        const margins: dwmapi.MARGINS = .{ .cxLeftWidth = -1, .cxRightWidth = -1, .cyTopHeight = -1, .cyBottomHeight = -1 };
        hr_ext = dwmapi.DwmExtendFrameIntoClientArea(hwnd, &margins);
    }
    var hr_blur: HRESULT = 1;
    if (backdrop == .blur or backdrop == .both) {
        // An empty region turns on per-pixel alpha without blurring anything.
        const rgn = gdi32.CreateRectRgn(0, 0, -1, -1);
        const bb: dwmapi.DWM_BLURBEHIND = .{ .dwFlags = dwmapi.DWM_BB_ENABLE | dwmapi.DWM_BB_BLURREGION, .fEnable = 1, .hRgnBlur = rgn };
        hr_blur = dwmapi.DwmEnableBlurBehindWindow(hwnd, &bb);
    }
    _ = user32.SetWindowPos(hwnd, null, 0, 0, 0, 0, user32.SWP_NOMOVE | user32.SWP_NOSIZE | user32.SWP_NOZORDER | user32.SWP_NOACTIVATE | user32.SWP_FRAMECHANGED);
    logf("frame hwnd=0x{x} backdrop={s} sbt={s} sbt_hr=0x{x} extend_hr=0x{x} blur_hr=0x{x} (1 = not requested)", .{
        @intFromPtr(hwnd), @tagName(backdrop), @tagName(sbt), hrU(hr_sbt), hrU(hr_ext), hrU(hr_blur),
    });
}

fn createTop(slot_idx: usize, title: [*:0]const u16, x: i32, y: i32, w: i32, h: i32) HWND {
    const hwnd = user32.CreateWindowExW(
        0,
        L("CompSpikeTop"),
        title,
        user32.WS_OVERLAPPEDWINDOW | user32.WS_CLIPCHILDREN,
        x,
        y,
        w,
        h,
        null,
        null,
        hinst,
        null,
    ) orelse fatal("CreateWindowExW top", error.CreateWindow);
    _ = user32.SetWindowPos(hwnd, user32.HWND_TOPMOST, 0, 0, 0, 0, user32.SWP_NOMOVE | user32.SWP_NOSIZE | user32.SWP_NOACTIVATE);
    applyFrame(hwnd, cfg.backdrop, cfg.sbt);
    top_child[slot_idx].top = hwnd;
    return hwnd;
}

fn createChild(slot_idx: usize, parent: HWND) HWND {
    const g = geoOf(parent);
    const c = user32.CreateWindowExW(
        @as(u32, if (cfg.noredir) user32.WS_EX_NOREDIRECTIONBITMAP else 0),
        L("CompSpikeChild"),
        L(""),
        user32.WS_CHILD | user32.WS_VISIBLE | user32.WS_CLIPSIBLINGS,
        0,
        g.strip_h,
        g.w,
        @max(1, g.h - g.strip_h),
        parent,
        null,
        hinst,
        null,
    ) orelse fatal("CreateWindowExW child", error.CreateWindow);
    top_child[slot_idx].child = c;
    return c;
}

fn showTop(hwnd: HWND) void {
    _ = user32.ShowWindow(hwnd, user32.SW_SHOW);
    _ = user32.UpdateWindow(hwnd);
    _ = user32.SetForegroundWindow(hwnd);
}

fn childSize(child: HWND) struct { w: u32, h: u32 } {
    var rc: RECT = undefined;
    _ = user32.GetClientRect(child, &rc);
    return .{ .w = @intCast(@max(1, rc.right)), .h = @intCast(@max(1, rc.bottom)) };
}

// -- Direct2D strip painter (check d) -----------------------------------------------

const Painter = struct {
    factory: *d2d1.ID2D1Factory,
    dw: *dwrite.IDWriteFactory,
    target: *d2d1.ID2D1DCRenderTarget,
    ui_format: *dwrite.IDWriteTextFormat,

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
        return .{ .factory = factory, .dw = dw, .target = target, .ui_format = ui };
    }

    fn paint(self: *Painter, hdc: HDC, g: Geo) !void {
        try self.target.bindDC(hdc, .{ .left = 0, .top = 0, .right = g.w, .bottom = g.strip_h });
        const rt = self.target.asRenderTarget();
        const fill = try rt.createSolidColorBrush(.{ .r = 16.0 / 255.0, .g = 32.0 / 255.0, .b = 48.0 / 255.0, .a = 1 });
        defer com.release(fill);
        const ink = try rt.createSolidColorBrush(.{ .r = 0.92, .g = 0.92, .b = 0.92, .a = 1 });
        defer com.release(ink);
        rt.beginDraw();
        rt.setTextAntialiasMode(.GRAYSCALE);
        rt.clear(.{ .r = 0, .g = 0, .b = 0, .a = 0 });
        const t = tabRect(g);
        const radius: f32 = 6 * g.scale;
        rt.fillRoundedRectangle(.{
            .rect = .{
                .left = @floatFromInt(t.left),
                .top = @floatFromInt(t.top),
                .right = @floatFromInt(t.right),
                .bottom = @as(f32, @floatFromInt(g.strip_h)) + radius,
            },
            .radiusX = radius,
            .radiusY = radius,
        }, fill.asBrush());
        const pad = px(12, g.scale);
        const layout = try self.dw.createTextLayout(L("Spike Tab"), self.ui_format, @floatFromInt(t.right - t.left - 2 * pad), @floatFromInt(t.bottom - t.top));
        defer com.release(layout);
        rt.drawTextLayout(.{ .x = @floatFromInt(t.left + pad), .y = @floatFromInt(t.top) }, layout, ink.asBrush(), d2d1.DRAW_TEXT_OPTIONS_NONE);
        try rt.endDraw();
    }
};

fn tabRect(g: Geo) RECT {
    return .{ .left = px(8, g.scale), .top = px(6, g.scale), .right = px(168, g.scale), .bottom = g.strip_h };
}

fn paintStrip(hwnd: HWND) void {
    var ps: user32.PAINTSTRUCT = undefined;
    const hdc = user32.BeginPaint(hwnd, &ps) orelse return;
    defer _ = user32.EndPaint(hwnd, &ps);
    const g = geoOf(hwnd);
    if (painter == null) painter = Painter.init(g.scale) catch |e| fatal("painter init", e);
    const rc: RECT = .{ .left = 0, .top = 0, .right = g.w, .bottom = g.strip_h };
    const params: BP_PAINTPARAMS = .{ .dwFlags = BPPF_ERASE };
    var mem: ?HDC = null;
    const hbp = BeginBufferedPaint(hdc, &rc, BPBF_TOPDOWNDIB, &params, &mem) orelse {
        logf("paint BeginBufferedPaint failed", .{});
        return;
    };
    painter.?.paint(mem.?, g) catch |e| logf("paint failed err={s}", .{@errorName(e)});
    _ = EndBufferedPaint(hbp, 1);
}

/// Check (d): the tab fill and its text stay readable on the strip.
fn checkStrip(label: []const u8, img: Image, g: Geo) void {
    const t = tabRect(g);
    var ink: i32 = 0;
    var y = t.top;
    while (y < t.bottom) : (y += 1) {
        var x = t.left + px(8, g.scale);
        while (x < t.right - px(8, g.scale)) : (x += 1) {
            const p = img.at(x, y);
            if (@max(p.r, @max(p.g, p.b)) > 140) ink += 1;
        }
    }
    const fill_pt = img.at(t.left + 4, t.top + @divTrunc(t.bottom - t.top, 2));
    const bg_pt = img.at(g.w - 80, @divTrunc(g.strip_h, 2));
    var b1: [8]u8 = undefined;
    var b2: [8]u8 = undefined;
    const bg_ok = !near(bg_pt, .{ .r = 0, .g = 0, .b = 0 }, 6) and !near(bg_pt, tab_fill, 3);
    report("d", ink >= 20 and near(fill_pt, tab_fill, 3) and bg_ok, "{s}: {d} bright text pixels in the tab, tab fill {s} (expect #102030), strip background {s} (not black, not tab fill: {})", .{
        label, ink, fmtRgb(fill_pt, &b1), fmtRgb(bg_pt, &b2), bg_ok,
    });
}

// -- Renderer: swap chain on a worker thread ----------------------------------------

const Kind = enum { comp, hwnd };
const Pattern = enum { thirds, solid_a, solid_b };

const Renderer = struct {
    kind: Kind,
    hwnd: HWND,
    pattern: Pattern = .thirds,
    /// `ALLOW_TEARING` on the swap chain / on every `Present`.
    chain_tearing: bool = false,
    present_tearing: bool = false,
    sync: u32 = 1,

    thread: ?std.Thread = null,
    ready: std.atomic.Value(u32) = .init(0), // 1 ok, 2 failed
    stop: std.atomic.Value(bool) = .init(false),
    want_w: std.atomic.Value(u32) = .init(1),
    want_h: std.atomic.Value(u32) = .init(1),
    frames: std.atomic.Value(u64) = .init(0),
    occluded: std.atomic.Value(u64) = .init(0),
    errors: std.atomic.Value(u64) = .init(0),
    resizes: std.atomic.Value(u64) = .init(0),
    first_err: std.atomic.Value(u32) = .init(0),
    create_hr: HRESULT = 0,
    measure: std.atomic.Value(bool) = .init(false),
    pace_n: std.atomic.Value(u32) = .init(0),
    wait_ms: [320]f32 = undefined,
    interval_ms: [320]f32 = undefined,

    device: ?*d3d11.ID3D11Device = null,
    context: ?*d3d11.ID3D11DeviceContext = null,
    swap: ?*dxgi.IDXGISwapChain1 = null,

    fn flags(self: *const Renderer) u32 {
        return dxgi.SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT | (if (self.chain_tearing) dxgi.SWAP_CHAIN_FLAG_ALLOW_TEARING else 0);
    }

    fn start(self: *Renderer) void {
        const sz = childSize(self.hwnd);
        self.want_w.store(sz.w, .release);
        self.want_h.store(sz.h, .release);
        self.thread = std.Thread.spawn(.{}, run, .{self}) catch |e| fatal("spawn render thread", e);
    }

    fn waitReady(self: *Renderer) bool {
        var waited: u32 = 0;
        while (self.ready.load(.acquire) == 0 and waited < 8000) : (waited += 5) Sleep(5);
        return self.ready.load(.acquire) == 1;
    }

    fn stopAndJoin(self: *Renderer) void {
        self.stop.store(true, .release);
        if (self.thread) |t| t.join();
        self.thread = null;
    }

    /// Releases the swap chain and the device; call after `stopAndJoin`.
    fn destroy(self: *Renderer) void {
        com.release(self.swap);
        self.swap = null;
        if (self.context) |c| {
            c.flush();
            com.release(c);
        }
        com.release(self.device);
        self.context = null;
        self.device = null;
    }

    fn makePattern(self: *Renderer, dev: *d3d11.ID3D11Device, w: u32, h: u32) !*d3d11.ID3D11Texture2D {
        const px_buf = try alloc.alloc(u32, w * h);
        defer alloc.free(px_buf);
        const t1 = w / 3;
        const t2 = w * 2 / 3;
        for (0..h) |yy| {
            for (0..w) |xx| {
                px_buf[yy * w + xx] = switch (self.pattern) {
                    .thirds => if (xx < t1) 0xFF1020C0 else if (xx < t2) 0x00000000 else 0x80808080,
                    .solid_a => 0xFF102030,
                    .solid_b => 0xFF20C030,
                };
            }
        }
        const init: d3d11.SUBRESOURCE_DATA = .{ .pSysMem = px_buf.ptr, .SysMemPitch = w * 4, .SysMemSlicePitch = 0 };
        return dev.createTexture2D(&.{
            .Width = w,
            .Height = h,
            .MipLevels = 1,
            .ArraySize = 1,
            .Format = .B8G8R8A8_UNORM,
            .SampleDesc = .{ .Count = 1, .Quality = 0 },
            .Usage = .default,
            .BindFlags = .{},
            .CPUAccessFlags = .{},
            .MiscFlags = 0,
        }, &init);
    }

    fn fail(self: *Renderer, what: []const u8, err: anyerror) void {
        logf("render thread {s} failed: {s} create_hr=0x{x}", .{ what, @errorName(err), hrU(self.create_hr) });
        self.ready.store(2, .release);
    }

    fn run(self: *Renderer) void {
        const created = d3d11.createDevice(.hardware, .{ .bgra_support = true }) catch |e| return self.fail("createDevice", e);
        self.device = created.device;
        self.context = created.context;
        const factory = dxgi.createFactory(false) catch |e| return self.fail("createFactory", e);
        defer com.release(factory);

        const w0 = self.want_w.load(.acquire);
        const h0 = self.want_h.load(.acquire);
        const desc: dxgi.SWAP_CHAIN_DESC1 = .{
            .Width = w0,
            .Height = h0,
            .Format = .B8G8R8A8_UNORM,
            .BufferUsage = dxgi.USAGE_RENDER_TARGET_OUTPUT,
            .BufferCount = 2,
            .Scaling = .STRETCH,
            .SwapEffect = .FLIP_DISCARD,
            .AlphaMode = if (self.kind == .comp) .PREMULTIPLIED else .IGNORE,
            .Flags = self.flags(),
        };
        var out: ?*dxgi.IDXGISwapChain1 = null;
        self.create_hr = switch (self.kind) {
            .comp => factory.vtable.CreateSwapChainForComposition(factory, @ptrCast(created.device), &desc, null, &out),
            .hwnd => factory.vtable.CreateSwapChainForHwnd(factory, @ptrCast(created.device), self.hwnd, &desc, null, null, &out),
        };
        if (!foundation.succeeded(self.create_hr) or out == null) return self.fail("create swap chain", error.ComFailure);
        const swap = out.?;
        self.swap = swap;

        const sc2 = com.queryInterface(swap, dxgi.IDXGISwapChain2) catch |e| return self.fail("IDXGISwapChain2", e);
        defer com.release(sc2);
        sc2.setMaximumFrameLatency(1) catch |e| return self.fail("SetMaximumFrameLatency", e);
        const waitable = sc2.getFrameLatencyWaitableObject() orelse return self.fail("waitable", error.ComFailure);
        defer _ = kernel32.CloseHandle(waitable);

        var cur_w = w0;
        var cur_h = h0;
        var back = swap.asSwapChain().getBuffer(0, d3d11.ID3D11Texture2D) catch |e| return self.fail("GetBuffer", e);
        var pattern = self.makePattern(created.device, cur_w, cur_h) catch |e| return self.fail("pattern", e);
        self.ready.store(1, .release);

        var prev_us: i64 = nowUs();
        while (!self.stop.load(.acquire)) {
            const want_w = self.want_w.load(.acquire);
            const want_h = self.want_h.load(.acquire);
            if (want_w != cur_w or want_h != cur_h) {
                com.release(back);
                com.release(pattern);
                swap.asSwapChain().resizeBuffers(0, want_w, want_h, .UNKNOWN, self.flags()) catch |e| {
                    logf("ResizeBuffers {d}x{d} failed: {s}", .{ want_w, want_h, @errorName(e) });
                    _ = self.errors.fetchAdd(1, .monotonic);
                    return;
                };
                cur_w = want_w;
                cur_h = want_h;
                back = swap.asSwapChain().getBuffer(0, d3d11.ID3D11Texture2D) catch return;
                pattern = self.makePattern(created.device, cur_w, cur_h) catch return;
                _ = self.resizes.fetchAdd(1, .monotonic);
            }

            const t_wait = nowUs();
            _ = kernel32.WaitForSingleObjectEx(waitable, 1000, 0);
            const t_got = nowUs();

            created.context.copyResource(back.asResource(), pattern.asResource());
            const sc = swap.asSwapChain();
            const hr = sc.vtable.Present(sc, self.sync, if (self.present_tearing) dxgi.PRESENT_ALLOW_TEARING else 0);
            if (hr == dxgi.STATUS_OCCLUDED) {
                _ = self.occluded.fetchAdd(1, .monotonic);
                Sleep(10);
            } else if (foundation.succeeded(hr)) {
                _ = self.frames.fetchAdd(1, .monotonic);
            } else {
                _ = self.errors.fetchAdd(1, .monotonic);
                if (self.first_err.load(.monotonic) == 0) self.first_err.store(hrU(hr), .monotonic);
                Sleep(10);
            }

            if (self.measure.load(.acquire)) {
                const n = self.pace_n.load(.monotonic);
                if (n < 300) {
                    self.wait_ms[n] = @floatFromInt(t_got - t_wait);
                    self.wait_ms[n] /= 1000.0;
                    self.interval_ms[n] = @as(f32, @floatFromInt(t_got - prev_us)) / 1000.0;
                    self.pace_n.store(n + 1, .release);
                }
            }
            prev_us = t_got;
        }
        com.release(back);
        com.release(pattern);
    }
};

fn pace(label: []const u8, r: *Renderer) void {
    const n = r.pace_n.load(.acquire);
    if (n < 10) {
        report("g", false, "{s}: only {d} paced frames", .{ label, n });
        return;
    }
    var w: [300]f32 = undefined;
    var iv: [300]f32 = undefined;
    @memcpy(w[0..n], r.wait_ms[0..n]);
    @memcpy(iv[0..n], r.interval_ms[0..n]);
    var wsum: f32 = 0;
    var isum: f32 = 0;
    for (0..n) |i| {
        wsum += w[i];
        isum += iv[i];
    }
    std.mem.sort(f32, w[0..n], {}, std.sort.asc(f32));
    std.mem.sort(f32, iv[0..n], {}, std.sort.asc(f32));
    report("g", null, "{s}: {d} frames; wait ms mean {d:.2} p50 {d:.2} p95 {d:.2} max {d:.2}; frame interval ms mean {d:.2} p50 {d:.2} p95 {d:.2} max {d:.2}", .{
        label,
        n,
        wsum / @as(f32, @floatFromInt(n)),
        w[n / 2],
        w[n * 95 / 100],
        w[n - 1],
        isum / @as(f32, @floatFromInt(n)),
        iv[n / 2],
        iv[n * 95 / 100],
        iv[n - 1],
    });
}

fn collectPace(r: *Renderer) void {
    r.pace_n.store(0, .release);
    r.measure.store(true, .release);
    var waited: u32 = 0;
    while (r.pace_n.load(.acquire) < 300 and waited < 12000) : (waited += 20) pump(20);
    r.measure.store(false, .release);
}

// -- DirectComposition -------------------------------------------------------------

const Comp = struct {
    dev: ?*dcomp.IDCompositionDevice = null,
    target: ?*dcomp.IDCompositionTarget = null,
    visual: ?*dcomp.IDCompositionVisual = null,

    fn ensureDevice(self: *Comp) *dcomp.IDCompositionDevice {
        if (self.dev == null) self.dev = dcomp.createDevice(null) catch |e| fatal("DCompositionCreateDevice2", e);
        return self.dev.?;
    }

    /// Raw `CreateTargetForHwnd`; returns the HRESULT and stores the target on success.
    fn createTarget(self: *Comp, child: HWND) HRESULT {
        const dev = self.ensureDevice();
        var t: ?*dcomp.IDCompositionTarget = null;
        const hr = dev.vtable.CreateTargetForHwnd(dev, child, 1, &t);
        if (foundation.succeeded(hr)) self.target = t;
        return hr;
    }

    /// Target on `child`, visual showing `swap`, committed. Returns the target HRESULT.
    fn attach(self: *Comp, child: HWND, swap: *dxgi.IDXGISwapChain1) HRESULT {
        const dev = self.ensureDevice();
        const hr = self.createTarget(child);
        if (!foundation.succeeded(hr)) return hr;
        if (self.visual == null) self.visual = dev.createVisual() catch |e| fatal("CreateVisual", e);
        self.visual.?.setContent(swap) catch |e| fatal("SetContent", e);
        self.target.?.setRoot(self.visual) catch |e| fatal("SetRoot", e);
        dev.commit() catch |e| fatal("Commit", e);
        return hr;
    }

    fn setContent(self: *Comp, swap: anytype) void {
        self.visual.?.setContent(swap) catch |e| fatal("SetContent", e);
        self.dev.?.commit() catch |e| fatal("Commit", e);
    }

    fn releaseTarget(self: *Comp) void {
        if (self.target) |t| {
            t.setRoot(null) catch {};
            com.release(t);
        }
        self.target = null;
        if (self.dev) |d| d.commit() catch {};
    }

    fn deinit(self: *Comp) void {
        self.releaseTarget();
        if (self.visual) |v| {
            v.setContent(null) catch {};
            com.release(v);
        }
        self.visual = null;
        com.release(self.dev);
        self.dev = null;
    }
};

// -- Modes ---------------------------------------------------------------------------

var comp: Comp = .{};

fn outerSize(w: i32, h: i32) struct { w: i32, h: i32 } {
    const sw = user32.GetSystemMetrics(SM_CXSCREEN);
    const sh = user32.GetSystemMetrics(SM_CYSCREEN);
    return .{ .w = @min(w, sw - 80), .h = @min(h, sh - 120) };
}

fn snap(name: []const u8, hwnd: HWND, g: Geo) ?Image {
    const img = captureClient(g) orelse {
        logf("capture {s} failed", .{name});
        return null;
    };
    saveBmp(name, img);
    _ = hwnd;
    return img;
}

fn modeTransparent() void {
    const sz = outerSize(1000, 640);
    const top = createTop(0, L("Composition Spike"), 120, 80, sz.w, sz.h);
    const child = createChild(0, top);
    showTop(top);
    waitGo();

    var tag_buf: [64]u8 = undefined;
    const tag = std.fmt.bufPrint(&tag_buf, "{s}-{s}{s}{s}", .{ @tagName(cfg.backdrop), @tagName(cfg.sbt), if (cfg.noredir) "-nr" else "", if (cfg.child_black) "-cb" else "" }) catch "run";
    var name_buf: [96]u8 = undefined;
    report("env", null, "variant {s}; foreground is spike window: {}; transparency effects (registry EnableTransparency): {d}", .{
        tag,
        user32.GetForegroundWindow() == top,
        transparencyEffects(),
    });

    var r: Renderer = .{ .kind = .comp, .hwnd = child, .pattern = .thirds };
    active_render = &r;
    r.start();
    if (!r.waitReady()) {
        report("a", false, "composition swap chain creation on the worker thread failed, hr=0x{x}", .{hrU(r.create_hr)});
        return;
    }
    const hr_target = comp.attach(child, r.swap.?);
    report("a", foundation.succeeded(hr_target), "CreateTargetForHwnd(child, TRUE) hr=0x{x}; swap chain created on the worker (hr=0x{x}), SetContent+Commit on the UI thread", .{ hrU(hr_target), hrU(r.create_hr) });
    if (!foundation.succeeded(hr_target)) return;

    pump(300);
    collectPace(&r);
    pace("composition chain, transparent window", &r);
    report("a", r.errors.load(.acquire) == 0 and r.frames.load(.acquire) > 100, "present on the worker: frames={d} occluded={d} errors={d} first_err=0x{x}", .{ r.frames.load(.acquire), r.occluded.load(.acquire), r.errors.load(.acquire), r.first_err.load(.acquire) });

    var g = geoOf(top);
    const idle = snap(std.fmt.bufPrint(&name_buf, "transparent-{s}-idle", .{tag}) catch "idle", top, g);
    if (idle) |img| {
        defer img.deinit();
        const t = analyzeThirds(img, g);
        reportThirds(if (cfg.sbt == .acrylic) "c" else "b", "idle", t, cfg.sbt == .none);
        checkStrip(tag, img, g);
        if (cfg.sbt == .acrylic) {
            report("c", null, "Acrylic: stripes behind the alpha-0 third are blurred when sharpness is far below the sharp-backdrop value (~100+); measured {d:.1}", .{t.sharpness});
        }
        // (f) PrintWindow against the screen capture of the same points.
        if (capturePrintWindow(top, g)) |pw| {
            defer pw.deinit();
            const tp = analyzeThirds(pw, g);
            saveBmp(std.fmt.bufPrint(&name_buf, "transparent-{s}-printwindow", .{tag}) catch "pw", .{ .w = pw.w, .h = pw.h, .ox = 0, .oy = 0, .px = pw.px });
            var b1: [8]u8 = undefined;
            var b2: [8]u8 = undefined;
            var b3: [8]u8 = undefined;
            report("f", null, "PrintWindow(PW_RENDERFULLCONTENT): left={s} (screen {}) mid={s} right={s}; has swap-chain content: {}; matches the screen capture: {}", .{
                fmtRgb(tp.left_sample, &b1),
                t.left_ok,
                fmtRgb(tp.mid_sample, &b2),
                fmtRgb(tp.right_sample, &b3),
                tp.left_ok,
                tp.left_ok == t.left_ok and near(tp.mid_sample, t.mid_sample, 8),
            });
        }
    }
    if (cfg.quick) {
        r.stopAndJoin();
        comp.deinit();
        r.destroy();
        return;
    }

    // (a) resize on the UI thread while the worker presents and resizes buffers.
    const sizes = [_][2]i32{ .{ 860, 560 }, .{ 700, 450 }, .{ 1000, 640 } };
    for (sizes, 0..) |s, i| {
        const f0 = r.frames.load(.acquire);
        const rz0 = r.resizes.load(.acquire);
        const o = outerSize(s[0], s[1]);
        _ = user32.SetWindowPos(top, null, 0, 0, o.w, o.h, user32.SWP_NOMOVE | user32.SWP_NOZORDER | user32.SWP_NOACTIVATE);
        pump(800);
        g = geoOf(top);
        if (snap(std.fmt.bufPrint(&name_buf, "transparent-{s}-resize{d}", .{ tag, i }) catch "rs", top, g)) |img| {
            defer img.deinit();
            const t = analyzeThirds(img, g);
            reportThirds("a", "after resize", t, cfg.sbt == .none);
        }
        report("a", r.errors.load(.acquire) == 0 and r.frames.load(.acquire) > f0 + 10, "resize to {d}x{d}: client {d}x{d}, buffer resizes on the worker {d}, frames +{d}, errors {d}", .{
            o.w, o.h, g.w, g.h, r.resizes.load(.acquire) - rz0, r.frames.load(.acquire) - f0, r.errors.load(.acquire),
        });
    }

    // (i) maximize.
    _ = user32.ShowWindow(top, user32.SW_MAXIMIZE);
    pump(1500);
    g = geoOf(top);
    if (snap(std.fmt.bufPrint(&name_buf, "transparent-{s}-maximized", .{tag}) catch "mx", top, g)) |img| {
        defer img.deinit();
        reportThirds("i", "maximized", analyzeThirds(img, g), cfg.sbt == .none);
        checkStrip("maximized", img, g);
    }
    report("i", r.errors.load(.acquire) == 0, "maximized client {d}x{d}, buffer resizes so far {d}, errors {d}", .{ g.w, g.h, r.resizes.load(.acquire), r.errors.load(.acquire) });
    _ = user32.ShowWindow(top, user32.SW_RESTORE);
    pump(700);

    // (i) "DPI 144": the window rect scaled by 1.5, like the dpi-sim scenario.
    g = geoOf(top);
    const o144 = outerSize(@divTrunc((g.wr.right - g.wr.left) * 3, 2), @divTrunc((g.wr.bottom - g.wr.top) * 3, 2));
    _ = user32.SetWindowPos(top, null, 0, 0, o144.w, o144.h, user32.SWP_NOMOVE | user32.SWP_NOZORDER | user32.SWP_NOACTIVATE);
    pump(1000);
    g = geoOf(top);
    if (snap(std.fmt.bufPrint(&name_buf, "transparent-{s}-scaled150", .{tag}) catch "dpi", top, g)) |img| {
        defer img.deinit();
        reportThirds("i", "window rect x1.5 (DPI 144 simulation)", analyzeThirds(img, g), cfg.sbt == .none);
    }

    // (i) minimize / restore.
    const f_min0 = r.frames.load(.acquire);
    const o_min0 = r.occluded.load(.acquire);
    _ = user32.ShowWindow(top, user32.SW_MINIMIZE);
    pump(1000);
    report("i", null, "while minimized: frames +{d}, occluded +{d}, errors {d}", .{ r.frames.load(.acquire) - f_min0, r.occluded.load(.acquire) - o_min0, r.errors.load(.acquire) });
    _ = user32.ShowWindow(top, user32.SW_RESTORE);
    _ = user32.SetForegroundWindow(top);
    pump(1500);
    const f_res0 = r.frames.load(.acquire);
    pump(500);
    g = geoOf(top);
    if (snap(std.fmt.bufPrint(&name_buf, "transparent-{s}-restored", .{tag}) catch "rst", top, g)) |img| {
        defer img.deinit();
        reportThirds("i", "after minimize/restore", analyzeThirds(img, g), cfg.sbt == .none);
    }
    report("i", r.errors.load(.acquire) == 0 and r.frames.load(.acquire) > f_res0 + 10, "after restore: frames +{d} in 500 ms, errors {d}", .{ r.frames.load(.acquire) - f_res0, r.errors.load(.acquire) });

    r.stopAndJoin();
    comp.deinit();
    r.destroy();
}

fn modePacing() void {
    const sz = outerSize(1000, 640);
    const top = createTop(0, L("Composition Spike"), 120, 80, sz.w, sz.h);
    showTop(top);
    waitGo();
    // hwnd, comp, comp, hwnd: each chain alone on its own child, same window.
    const order = [_]Kind{ .hwnd, .comp, .comp, .hwnd };
    for (order, 0..) |kind, i| {
        const child = createChild(0, top);
        var r: Renderer = .{ .kind = kind, .hwnd = child, .pattern = .solid_a };
        active_render = &r;
        r.start();
        if (!r.waitReady()) {
            report("g", false, "{s} chain creation failed hr=0x{x}", .{ @tagName(kind), hrU(r.create_hr) });
            r.stopAndJoin();
            r.destroy();
            _ = user32.DestroyWindow(child);
            continue;
        }
        if (kind == .comp) _ = comp.attach(child, r.swap.?);
        pump(500);
        collectPace(&r);
        var lbl: [48]u8 = undefined;
        pace(std.fmt.bufPrint(&lbl, "{s} chain, run {d}", .{ @tagName(kind), i }) catch "chain", &r);
        r.stopAndJoin();
        comp.deinit();
        r.destroy();
        active_render = null;
        _ = user32.DestroyWindow(child);
        pump(200);
    }
}

fn modeReparent() void {
    const sz = outerSize(900, 600);
    const a = createTop(0, L("Composition Spike A"), 100, 60, sz.w, sz.h);
    const child = createChild(0, a);
    showTop(a);
    waitGo();
    var r: Renderer = .{ .kind = .comp, .hwnd = child, .pattern = .thirds };
    active_render = &r;
    r.start();
    if (!r.waitReady()) {
        report("e", false, "swap chain creation failed hr=0x{x}", .{hrU(r.create_hr)});
        return;
    }
    const hr0 = comp.attach(child, r.swap.?);
    pump(1200);
    var ga = geoOf(a);
    if (snap("reparent-1-before-in-A", a, ga)) |img| {
        defer img.deinit();
        const t = analyzeThirds(img, ga);
        reportThirds("e", "before: child in A", t, cfg.sbt == .none);
    }
    report("e", foundation.succeeded(hr0), "target created on the child in A, hr=0x{x}", .{hrU(hr0)});

    const b = createTop(1, L("Composition Spike B"), 200, 120, sz.w, sz.h);
    showTop(b);
    pump(300);
    const prev = user32.SetParent(child, b);
    const last_err = kernel32.GetLastError();
    top_child[0].top = null; // WM_SIZE of A no longer places the child
    top_child[1].child = child;
    placeChild(b, child);
    _ = user32.ShowWindow(child, user32.SW_SHOW);
    report("e", prev != null, "SetParent(child, B) returned previous parent {} (last_error {d}); child parent is B: {}", .{ prev == a, last_err, user32.GetParent(child) == b });
    const f0 = r.frames.load(.acquire);
    pump(1500);
    const gb = geoOf(b);
    var survived = false;
    if (snap("reparent-2-after-SetParent-in-B", b, gb)) |img| {
        defer img.deinit();
        const t = analyzeThirds(img, gb);
        survived = t.visible();
        reportThirds("e", "after SetParent, no re-creation", t, false);
    }
    report("e", null, "DComp target survives SetParent without re-creation: {}; frames +{d}, errors {d}", .{ survived, r.frames.load(.acquire) - f0, r.errors.load(.acquire) });

    // Probe: a second target on the same child while the old one is alive.
    {
        const dev = comp.dev.?;
        var probe_target: ?*dcomp.IDCompositionTarget = null;
        const hr = dev.vtable.CreateTargetForHwnd(dev, child, 1, &probe_target);
        report("e", null, "probe: second CreateTargetForHwnd(child) while the first target is alive hr=0x{x} (0x88980800 = WINDOW_ALREADY_COMPOSED)", .{hrU(hr)});
        com.release(probe_target);
    }

    if (!survived) {
        comp.releaseTarget();
        const hr = comp.createTarget(child);
        if (foundation.succeeded(hr)) {
            comp.target.?.setRoot(comp.visual) catch |e| fatal("SetRoot", e);
            comp.dev.?.commit() catch |e| fatal("Commit", e);
        }
        pump(1200);
        if (snap("reparent-3-after-recreate", b, geoOf(b))) |img| {
            defer img.deinit();
            reportThirds("e", "after re-creating the target in B", analyzeThirds(img, geoOf(b)), cfg.sbt == .none);
        }
        report("e", foundation.succeeded(hr), "re-created target for the child after the move: hr=0x{x}", .{hrU(hr)});
    }

    // Destroying A and resizing B must not disturb the child.
    _ = user32.DestroyWindow(a);
    pump(800);
    const o = outerSize(1000, 660);
    _ = user32.SetWindowPos(b, null, 0, 0, o.w, o.h, user32.SWP_NOMOVE | user32.SWP_NOZORDER | user32.SWP_NOACTIVATE);
    pump(900);
    ga = geoOf(b);
    if (snap("reparent-4-A-destroyed-B-resized", b, ga)) |img| {
        defer img.deinit();
        reportThirds("e", "after destroying A and resizing B", analyzeThirds(img, ga), cfg.sbt == .none);
    }
    report("e", r.errors.load(.acquire) == 0, "final: frames={d} errors={d} first_err=0x{x} resizes={d}", .{ r.frames.load(.acquire), r.errors.load(.acquire), r.first_err.load(.acquire), r.resizes.load(.acquire) });
    r.stopAndJoin();
    comp.deinit();
    r.destroy();
}

// Pixel sampler for check (j): polls one screen pixel as fast as GDI allows.
const Sample = struct { t_us: i64, rgb: u32 };
var samples: []Sample = &.{};
var sample_n = std.atomic.Value(usize).init(0);
var sample_stop = std.atomic.Value(bool).init(false);
var sample_x: i32 = 0;
var sample_y: i32 = 0;

fn samplerMain() void {
    const screen = user32.GetDC(null) orelse return;
    defer _ = user32.ReleaseDC(null, screen);
    const dib = Dib.create(screen, 1, 1) orelse return;
    defer dib.destroy();
    while (!sample_stop.load(.acquire)) {
        const n = sample_n.load(.monotonic);
        if (n >= samples.len) return;
        _ = BitBlt(dib.mem, 0, 0, 1, 1, screen, sample_x, sample_y, 0x00CC0020);
        samples[n] = .{ .t_us = nowUs(), .rgb = dib.bits[0] & 0x00FFFFFF };
        sample_n.store(n + 1, .release);
    }
}

const Mark = struct { t_us: i64, label: []const u8 };

fn modeCycle() void {
    const sz = outerSize(1000, 640);
    const top = createTop(0, L("Composition Spike"), 120, 80, sz.w, sz.h);
    const child = createChild(0, top);
    showTop(top);
    waitGo();
    const g = geoOf(top);
    const cs = childSize(child);
    sample_x = g.cx + @as(i32, @intCast(cs.w / 2));
    sample_y = g.cy + g.strip_h + @as(i32, @intCast(cs.h / 2));
    samples = alloc.alloc(Sample, 600_000) catch fatal("samples", error.OutOfMemory);
    var marks: [32]Mark = undefined;
    var nm: usize = 0;
    const sampler = std.Thread.spawn(.{}, samplerMain, .{}) catch |e| fatal("spawn sampler", e);

    var control_t: i64 = std.math.maxInt(i64);
    var hr_hwnd_fail: u32 = 0;
    var hr_target_fail: u32 = 0;
    var first_bad_hr: u32 = 0;
    var cycle: usize = 0;
    while (cycle < 3) : (cycle += 1) {
        // 1. hwnd flip chain.
        var rh: Renderer = .{ .kind = .hwnd, .hwnd = child, .pattern = .solid_a };
        active_render = &rh;
        marks[nm] = .{ .t_us = nowUs(), .label = "hwnd chain create" };
        nm += 1;
        rh.start();
        if (!rh.waitReady()) {
            hr_hwnd_fail += 1;
            if (first_bad_hr == 0) first_bad_hr = hrU(rh.create_hr);
        }
        marks[nm] = .{ .t_us = nowUs(), .label = "hwnd chain ready" };
        nm += 1;
        pump(600);
        // 2. -> composition.
        rh.stopAndJoin();
        rh.destroy();
        marks[nm] = .{ .t_us = nowUs(), .label = "hwnd chain released" };
        nm += 1;
        var rc: Renderer = .{ .kind = .comp, .hwnd = child, .pattern = .solid_a };
        active_render = &rc;
        rc.start();
        const ok = rc.waitReady();
        const hr = if (ok) comp.attach(child, rc.swap.?) else rc.create_hr;
        marks[nm] = .{ .t_us = nowUs(), .label = "composition attached" };
        nm += 1;
        if (!foundation.succeeded(hr)) {
            hr_target_fail += 1;
            if (first_bad_hr == 0) first_bad_hr = hrU(hr);
        }
        pump(600);
        // 3. -> hwnd again.
        rc.stopAndJoin();
        if (comp.visual) |v| v.setContent(null) catch {};
        comp.releaseTarget();
        if (cycle == 2) comp.deinit(); // the last round also drops the DComp device
        rc.destroy();
        marks[nm] = .{ .t_us = nowUs(), .label = "composition released" };
        nm += 1;
        pump(100);
        report("j", foundation.succeeded(hr) and ok, "cycle {d}: hwnd chain hr=0x{x}, CreateTargetForHwnd hr=0x{x}, composition chain frames {d} errors {d}", .{
            cycle, hrU(rh.create_hr), hrU(hr), rc.frames.load(.acquire), rc.errors.load(.acquire),
        });
    }
    // Final hwnd chain: still works after all the switching.
    var rf: Renderer = .{ .kind = .hwnd, .hwnd = child, .pattern = .solid_a };
    active_render = &rf;
    rf.start();
    const final_ok = rf.waitReady();
    pump(700);
    // Control: a deliberate 60 ms hole must show up in the samples.
    control_t = nowUs();
    marks[nm] = .{ .t_us = control_t, .label = "control: child hidden" };
    nm += 1;
    _ = user32.ShowWindow(child, user32.SW_HIDE);
    pump(60);
    _ = user32.ShowWindow(child, user32.SW_SHOW);
    marks[nm] = .{ .t_us = nowUs(), .label = "control: child shown" };
    nm += 1;
    pump(400);
    report("j", final_ok and rf.errors.load(.acquire) == 0 and rf.frames.load(.acquire) > 10, "final hwnd chain after 3 cycles: ready {} create hr=0x{x} frames {d} errors {d}; CreateSwapChainForHwnd failures {d}, CreateTargetForHwnd failures {d}, first bad hr=0x{x}", .{
        final_ok, hrU(rf.create_hr), rf.frames.load(.acquire), rf.errors.load(.acquire), hr_hwnd_fail, hr_target_fail, first_bad_hr,
    });
    if (snap("cycle-final", top, geoOf(top))) |img| {
        defer img.deinit();
        const p = img.at(@as(i32, @intCast(cs.w / 2)), g.strip_h + @as(i32, @intCast(cs.h / 2)));
        var b1: [8]u8 = undefined;
        report("j", near(p, solid_a, 2), "final capture centre pixel {s} (expect #102030)", .{fmtRgb(p, &b1)});
    }
    rf.stopAndJoin();
    rf.destroy();
    sample_stop.store(true, .release);
    sampler.join();

    // Longest run of samples that are not the expected colour.
    const n = sample_n.load(.acquire);
    if (n == 0) {
        report("j", false, "the pixel sampler recorded nothing", .{});
        return;
    }
    var longest_us: i64 = 0;
    var longest_at: i64 = 0;
    var runs_over: u32 = 0;
    var run_start: i64 = -1;
    var seen_good = false;
    var i: usize = 0;
    while (i < n and samples[i].t_us < control_t) : (i += 1) {
        const good = near(.{ .r = @truncate(samples[i].rgb >> 16), .g = @truncate(samples[i].rgb >> 8), .b = @truncate(samples[i].rgb) }, .{ .r = 16, .g = 32, .b = 48 }, 3);
        if (good) seen_good = true;
        if (!seen_good) continue;
        if (!good and run_start < 0) run_start = samples[i].t_us;
        if (good and run_start >= 0) {
            const len = samples[i].t_us - run_start;
            if (len > longest_us) {
                longest_us = len;
                longest_at = run_start;
            }
            if (len > 18_000) {
                runs_over += 1;
                var where: []const u8 = "between transitions";
                for (marks[0..nm]) |m| {
                    if (@abs(m.t_us - run_start) < 120_000) where = m.label;
                }
                report("j", null, "non-expected pixel for {d:.1} ms at +{d} ms (nearest transition: {s})", .{ @as(f64, @floatFromInt(len)) / 1000.0, @divFloor(run_start - samples[0].t_us, 1000), where });
            }
            run_start = -1;
        }
    }
    var off: usize = 0;
    var off_first: u32 = 0;
    for (samples[0..n]) |s| {
        if (s.t_us >= control_t) break;
        if (!near(.{ .r = @truncate(s.rgb >> 16), .g = @truncate(s.rgb >> 8), .b = @truncate(s.rgb) }, .{ .r = 16, .g = 32, .b = 48 }, 3)) {
            off += 1;
            if (off_first == 0) off_first = s.rgb;
        }
    }
    report("j", null, "{d} of {d} samples were not #102030 (first off colour #{X:0>6})", .{ off, n, off_first });
    var k: usize = 0;
    while (k + 1 < nm) : (k += 1) {
        var in_gap: usize = 0;
        var off_gap: usize = 0;
        for (samples[0..n]) |s| {
            if (s.t_us < marks[k].t_us or s.t_us > marks[k + 1].t_us) continue;
            in_gap += 1;
            if (!near(.{ .r = @truncate(s.rgb >> 16), .g = @truncate(s.rgb >> 8), .b = @truncate(s.rgb) }, .{ .r = 16, .g = 32, .b = 48 }, 3)) off_gap += 1;
        }
        report("j", null, "gap '{s}' -> '{s}': {d:.1} ms, {d} samples, {d} not #102030", .{ marks[k].label, marks[k + 1].label, @as(f64, @floatFromInt(marks[k + 1].t_us - marks[k].t_us)) / 1000.0, in_gap, off_gap });
    }
    report("j", longest_us <= 25_000, "{d} pixel samples ({d:.2} ms apart on average); longest run off #102030: {d:.1} ms at +{d} ms; runs over 18 ms: {d} (one refresh at 60 Hz is 16.7 ms)", .{
        n,
        if (n > 1) @as(f64, @floatFromInt(samples[n - 1].t_us - samples[0].t_us)) / 1000.0 / @as(f64, @floatFromInt(n)) else 0.0,
        @as(f64, @floatFromInt(longest_us)) / 1000.0,
        @divFloor(longest_at - samples[0].t_us, 1000),
        runs_over,
    });
}

fn modeTearing() void {
    const sz = outerSize(1000, 640);
    const top = createTop(0, L("Composition Spike"), 120, 80, sz.w, sz.h);
    const child = createChild(0, top);
    showTop(top);
    waitGo();
    if (dxgi.createFactory(false)) |f| {
        defer com.release(f);
        if (com.queryInterface(f, dxgi.IDXGIFactory5)) |f5| {
            defer com.release(f5);
            report("k", null, "IDXGIFactory5::CheckFeatureSupport(PRESENT_ALLOW_TEARING) = {}", .{f5.supportsTearing()});
        } else |_| report("k", null, "IDXGIFactory5 not available", .{});
    } else |_| {}

    const cases = [_]struct { name: []const u8, chain: bool, present: bool, sync: u32 }{
        .{ .name = "chain flag + Present(0, ALLOW_TEARING)", .chain = true, .present = true, .sync = 0 },
        .{ .name = "chain flag + Present(1, 0)", .chain = true, .present = false, .sync = 1 },
        .{ .name = "no chain flag + Present(0, ALLOW_TEARING)", .chain = false, .present = true, .sync = 0 },
        .{ .name = "no chain flag + Present(0, 0)", .chain = false, .present = false, .sync = 0 },
    };
    for (cases) |c| {
        var r: Renderer = .{ .kind = .comp, .hwnd = child, .pattern = .thirds, .chain_tearing = c.chain, .present_tearing = c.present, .sync = c.sync };
        active_render = &r;
        r.start();
        const ok = r.waitReady();
        if (!ok) {
            report("k", if (c.chain) null else false, "{s}: CreateSwapChainForComposition failed hr=0x{x}", .{ c.name, hrU(r.create_hr) });
            r.stopAndJoin();
            r.destroy();
            continue;
        }
        if (comp.visual == null) {
            _ = comp.attach(child, r.swap.?);
        } else {
            comp.setContent(r.swap.?);
        }
        pump(800);
        const g = geoOf(top);
        var shown = false;
        if (snap("tearing-case", top, g)) |img| {
            defer img.deinit();
            shown = analyzeThirds(img, g).left_ok;
        }
        report("k", r.errors.load(.acquire) == 0, "{s}: swap chain created (hr=0x{x}); frames {d}, present errors {d}, first error hr=0x{x}; pattern visible {}", .{
            c.name, hrU(r.create_hr), r.frames.load(.acquire), r.errors.load(.acquire), r.first_err.load(.acquire), shown,
        });
        r.stopAndJoin();
        comp.setContent(null);
        r.destroy();
    }
    comp.deinit();
}

fn modeDevRecreate() void {
    const sz = outerSize(1000, 640);
    const top = createTop(0, L("Composition Spike"), 120, 80, sz.w, sz.h);
    const child = createChild(0, top);
    showTop(top);
    waitGo();
    _ = comp.ensureDevice(); // no rendering device, created before any D3D device
    var b1: [8]u8 = undefined;
    const cs = childSize(child);
    const gy = geoOf(top).strip_h + @as(i32, @intCast(cs.h / 2));
    const gx = @as(i32, @intCast(cs.w / 2));

    var r1: Renderer = .{ .kind = .comp, .hwnd = child, .pattern = .solid_a };
    active_render = &r1;
    r1.start();
    if (!r1.waitReady()) {
        report("l", false, "first chain failed hr=0x{x}", .{hrU(r1.create_hr)});
        return;
    }
    const hr = comp.attach(child, r1.swap.?);
    pump(900);
    var g = geoOf(top);
    if (snap("devrecreate-1", top, g)) |img| {
        defer img.deinit();
        const p = img.at(gx, gy);
        report("l", near(p, solid_a, 2), "device 1: target hr=0x{x}, centre pixel {s} (expect #102030)", .{ hrU(hr), fmtRgb(p, &b1) });
    }

    // Drop chain and D3D device 1 completely, then bring up device 2 on the same DComp device.
    r1.stopAndJoin();
    comp.setContent(null);
    r1.destroy();
    pump(200);
    report("l", null, "after releasing D3D device 1: IDCompositionDevice::CheckDeviceState = {}", .{comp.dev.?.checkDeviceState() catch false});

    var r2: Renderer = .{ .kind = .comp, .hwnd = child, .pattern = .solid_b };
    active_render = &r2;
    r2.start();
    if (!r2.waitReady()) {
        report("l", false, "second chain failed hr=0x{x}", .{hrU(r2.create_hr)});
        return;
    }
    comp.setContent(r2.swap.?);
    pump(900);
    g = geoOf(top);
    if (snap("devrecreate-2", top, g)) |img| {
        defer img.deinit();
        const p = img.at(gx, gy);
        report("l", near(p, solid_b, 2), "device 2 on the same DComp device: centre pixel {s} (expect #20C030); frames {d} errors {d}", .{ fmtRgb(p, &b1), r2.frames.load(.acquire), r2.errors.load(.acquire) });
    }

    // Release the old chain's device while the visual still holds it, then swap.
    var r3: Renderer = .{ .kind = .comp, .hwnd = child, .pattern = .solid_a };
    active_render = &r3;
    r3.start();
    if (r3.waitReady()) {
        comp.setContent(r3.swap.?);
        r2.stopAndJoin();
        r2.destroy();
        pump(900);
        if (snap("devrecreate-3", top, g)) |img| {
            defer img.deinit();
            const p = img.at(gx, gy);
            report("l", near(p, solid_a, 2), "device 3 after destroying device 2: centre pixel {s} (expect #102030); frames {d} errors {d}", .{ fmtRgb(p, &b1), r3.frames.load(.acquire), r3.errors.load(.acquire) });
        }
    }
    report("l", comp.dev.?.checkDeviceState() catch false, "final CheckDeviceState", .{});
    r3.stopAndJoin();
    comp.deinit();
    r3.destroy();
}

fn modeMemory() void {
    const sz = outerSize(1000, 640);
    const top = createTop(0, L("Composition Spike"), 120, 80, sz.w, sz.h);
    const child = createChild(0, top);
    showTop(top);
    waitGo();
    pump(500);
    const base = privateMb();
    report("h", null, "baseline (windows, D2D painter, no D3D/DComp): private {d:.2} MB", .{base});

    const created = d3d11.createDevice(.hardware, .{ .bgra_support = true }) catch |e| fatal("createDevice", e);
    const factory = dxgi.createFactory(false) catch |e| fatal("createFactory", e);
    pump(200);
    const after_d3d = privateMb();
    report("h", null, "+ D3D11 device and DXGI factory: private {d:.2} MB (+{d:.2})", .{ after_d3d, after_d3d - base });

    const dev = comp.ensureDevice();
    pump(200);
    const after_dcomp = privateMb();
    report("h", null, "+ DComp device (null rendering device): private {d:.2} MB (+{d:.2})", .{ after_dcomp, after_dcomp - after_d3d });

    // One target + visual on the main child, then 16 more on tiny children.
    const t0 = privateMb();
    var hr = comp.createTarget(child);
    comp.visual = dev.createVisual() catch |e| fatal("CreateVisual", e);
    comp.target.?.setRoot(comp.visual) catch |e| fatal("SetRoot", e);
    dev.commit() catch |e| fatal("Commit", e);
    pump(100);
    const t1 = privateMb();
    report("h", foundation.succeeded(hr), "+ 1 target + visual on the main child: private {d:.2} MB (+{d:.2}), hr=0x{x}", .{ t1, t1 - t0, hrU(hr) });

    var extra_children: [16]HWND = undefined;
    var extra_targets: [16]?*dcomp.IDCompositionTarget = @splat(null);
    var extra_visuals: [16]?*dcomp.IDCompositionVisual = @splat(null);
    for (0..16) |i| {
        extra_children[i] = user32.CreateWindowExW(0, L("CompSpikeChild"), L(""), user32.WS_CHILD | user32.WS_VISIBLE | user32.WS_CLIPSIBLINGS, @intCast(4 + i * 12), 4, 8, 8, top, null, hinst, null) orelse fatal("extra child", error.CreateWindow);
    }
    pump(200);
    const before = privateMb();
    for (0..16) |i| {
        var t: ?*dcomp.IDCompositionTarget = null;
        hr = dev.vtable.CreateTargetForHwnd(dev, extra_children[i], 1, &t);
        extra_targets[i] = t;
        extra_visuals[i] = dev.createVisual() catch null;
        if (t != null and extra_visuals[i] != null) t.?.setRoot(extra_visuals[i]) catch {};
    }
    dev.commit() catch {};
    pump(300);
    const after16 = privateMb();
    report("h", null, "+ 16 targets + visuals on 8x8 children: private {d:.2} MB (+{d:.2}, {d:.1} KB per target+visual)", .{ after16, after16 - before, (after16 - before) * 1024.0 / 16.0 });
    for (0..16) |i| {
        if (extra_targets[i]) |t| {
            t.setRoot(null) catch {};
            com.release(t);
        }
        com.release(extra_visuals[i]);
    }
    dev.commit() catch {};
    for (extra_children) |c| _ = user32.DestroyWindow(c);
    pump(300);
    const released = privateMb();
    report("h", null, "after releasing the 16: private {d:.2} MB ({d:.2} vs before)", .{ released, released - before });

    // A composition swap chain and an hwnd swap chain of the same size, each alone,
    // three alternating rounds (the first one pays the lazy driver allocations).
    const cs = childSize(child);
    const desc_c: dxgi.SWAP_CHAIN_DESC1 = .{ .Width = cs.w, .Height = cs.h, .Format = .B8G8R8A8_UNORM, .BufferUsage = dxgi.USAGE_RENDER_TARGET_OUTPUT, .BufferCount = 2, .Scaling = .STRETCH, .SwapEffect = .FLIP_DISCARD, .AlphaMode = .PREMULTIPLIED, .Flags = 0 };
    var desc_h = desc_c;
    desc_h.AlphaMode = .IGNORE;
    for (0..3) |round| {
        const c0 = privateMb();
        _ = comp.createTarget(child);
        comp.target.?.setRoot(comp.visual) catch {};
        const sc = factory.createSwapChainForComposition(created.device, &desc_c) catch |e| fatal("comp chain", e);
        comp.visual.?.setContent(sc) catch {};
        dev.commit() catch {};
        _ = sc.asSwapChain().present(1, 0) catch {};
        pump(300);
        const c1 = privateMb();
        report("h", null, "round {d}: + composition swap chain {d}x{d} (2 buffers, premultiplied) with target+visual: private {d:.2} MB (+{d:.2})", .{ round, cs.w, cs.h, c1, c1 - c0 });
        comp.visual.?.setContent(null) catch {};
        com.release(sc);
        comp.releaseTarget();
        pump(300);
        const h0 = privateMb();
        const sh = factory.createSwapChainForHwnd(created.device, child, &desc_h) catch |e| fatal("hwnd chain", e);
        _ = sh.asSwapChain().present(1, 0) catch {};
        pump(300);
        const h1 = privateMb();
        report("h", null, "round {d}: + hwnd swap chain {d}x{d} (2 buffers, ignore alpha): private {d:.2} MB (+{d:.2})", .{ round, cs.w, cs.h, h1, h1 - h0 });
        com.release(sh);
        created.context.flush();
        pump(300);
    }
    com.release(factory);
    created.context.flush();
    com.release(created.context);
    com.release(created.device);
    comp.deinit();
    pump(300);
    report("h", null, "end: private {d:.2} MB", .{privateMb()});
}

pub fn main() u8 {
    var f: i64 = 1;
    _ = QueryPerformanceFrequency(&f);
    qpf = f;
    start_us = nowUs();
    parseArgs();
    openLog();
    logf("start mode={s} backdrop={s} sbt={s} quick={} noredir={} childblack={}", .{ @tagName(cfg.mode), @tagName(cfg.backdrop), @tagName(cfg.sbt), cfg.quick, cfg.noredir, cfg.child_black });
    _ = SetProcessDpiAwarenessContext(DPI_PER_MONITOR_V2);
    _ = BufferedPaintInit();
    defer _ = BufferedPaintUnInit();
    hinst = kernel32.GetModuleHandleW(null);
    registerClasses();
    createBackdropWindow();
    logf("ready", .{});
    switch (cfg.mode) {
        .transparent => modeTransparent(),
        .pacing => modePacing(),
        .reparent => modeReparent(),
        .cycle => modeCycle(),
        .tearing => modeTearing(),
        .devrecreate => modeDevRecreate(),
        .memory => modeMemory(),
    }
    logf("done", .{});
    return 0;
}
