//! The Windows 11 style modal dialog (WinUI `ContentDialog`): an owned
//! popup centred on its owner, rounded, on Mica (a solid fill where Mica is
//! not available), a title, a body or a scrollable list, and a bar of
//! equal-width buttons. Text and buttons are drawn with Direct2D and
//! DirectWrite (grayscale anti-aliasing, per-monitor DPI); the buttons are
//! real owner-drawn `BUTTON` children and the body is a `STATIC` that only
//! carries the text for screen readers, so the keyboard and accessibility
//! work as they do for any dialog.
//!
//! `run` is modal: it disables the owner, runs its own message loop and
//! enables the owner again before it returns. Like any modal loop it
//! dispatches the thread's other messages (see `dialogs.zig`).
//!
//! Layout maths are in `layout.zig`, the keyboard in `keys.zig`, colours in
//! `colors.zig` and the text safety in `text.zig`; this file is the window.
const std = @import("std");
const builtin = @import("builtin");
const win32 = @import("win32");
const Chrome = @import("../Chrome.zig");
const geom = @import("../geom.zig");
const theme = @import("../theme.zig");
const util = @import("../util.zig");
const secure_input = @import("../secure_input.zig");
const colors = @import("colors.zig");
const keys = @import("keys.zig");
const layout = @import("layout.zig");
const text = @import("text.zig");

const com = win32.com;
const d2d1 = win32.d2d1;
const dwmapi = win32.dwmapi;
const dwrite = win32.dwrite;
const gdi32 = win32.gdi32;
const user32 = win32.user32;
const uxtheme = win32.uxtheme;
const HWND = win32.foundation.HWND;
const HDC = user32.HDC;
const BOOL = win32.foundation.BOOL;
const WPARAM = win32.foundation.WPARAM;
const LPARAM = win32.foundation.LPARAM;
const LRESULT = win32.foundation.LRESULT;
const RECT = win32.foundation.RECT;

const log = std.log.scoped(.win32_dialog);

const L = std.unicode.utf8ToUtf16LeStringLiteral;

pub const class_name = L("GhosttyDialog");

/// Id a button reports when the dialog is closed without choosing one.
pub const cancel_id = 2;

/// Posted to the dialog by automation: press the button whose id is wparam.
/// The value is `TDM_CLICK_BUTTON` of the task dialog this one replaced.
pub const msg_click_button = user32.WM_USER + 102;

pub const max_buttons = layout.max_buttons;

pub const Button = struct {
    id: i32,
    /// With an optional `&` accelerator.
    text: []const u16,
};

pub const Spec = struct {
    owner: ?HWND,
    /// The window text, what a screen reader announces first.
    window_title: [:0]const u16,
    /// The headline; may be empty.
    title: []const u16,
    /// The text under the headline; may be empty.
    body: []const u16,
    /// Lines in a scrollable, selectable code-font list; may be empty. A
    /// body too tall for the screen moves here as well.
    list: []const u16,
    buttons: []const Button,
    /// The accent button; Enter presses it when nothing else has the focus.
    default_index: usize,
    /// What closing the dialog (Esc, Alt+F4) answers.
    cancel_id: i32 = cancel_id,
    /// Show the app icon (resource 1) above the text.
    icon: bool = false,
};

// -- Win32 odds and ends the bindings do not have ----------------------------------

const ext = struct {
    extern "user32" fn DrawIconEx(user32.HDC, i32, i32, win32.user32.HICON, i32, i32, u32, ?*anyopaque, u32) callconv(.winapi) BOOL;
    extern "user32" fn EnableWindow(HWND, BOOL) callconv(.winapi) BOOL;
    extern "user32" fn IsChild(HWND, ?HWND) callconv(.winapi) BOOL;
    extern "user32" fn GetDpiForSystem() callconv(.winapi) u32;
    extern "gdi32" fn SetBkColor(HDC, u32) callconv(.winapi) u32;
    extern "gdi32" fn SetTextColor(HDC, u32) callconv(.winapi) u32;
    extern "gdi32" fn GetTextMetricsW(HDC, *TEXTMETRICW) callconv(.winapi) BOOL;
    extern "user32" fn ShowScrollBar(HWND, i32, BOOL) callconv(.winapi) BOOL;
    extern "gdi32" fn SetBkMode(HDC, i32) callconv(.winapi) i32;
};

const TEXTMETRICW = extern struct {
    tmHeight: i32,
    tmAscent: i32,
    tmDescent: i32,
    tmInternalLeading: i32,
    tmExternalLeading: i32,
    tmAveCharWidth: i32,
    tmMaxCharWidth: i32,
    tmWeight: i32,
    tmOverhang: i32,
    tmDigitizedAspectX: i32,
    tmDigitizedAspectY: i32,
    tmFirstChar: u16,
    tmLastChar: u16,
    tmDefaultChar: u16,
    tmBreakChar: u16,
    tmItalic: u8,
    tmUnderlined: u8,
    tmStruckOut: u8,
    tmPitchAndFamily: u8,
    tmCharSet: u8,
};

const EM_GETLINECOUNT = 0x00BA;

const DRAWITEMSTRUCT = extern struct {
    CtlType: u32,
    CtlID: u32,
    itemID: u32,
    itemAction: u32,
    itemState: u32,
    hwndItem: ?HWND,
    hDC: ?HDC,
    rcItem: RECT,
    itemData: usize,
};

const WM_SETFONT = 0x0030;
const WM_DRAWITEM = 0x002B;
const WM_CTLCOLORSTATIC = 0x0138;
const WM_NCLBUTTONDBLCLK = 0x00A3;
const EM_SETSEL = 0x00B1;
const EM_SETMARGINS = 0x00D3;
const EC_LEFTMARGIN = 1;
const EC_RIGHTMARGIN = 2;
const BS_OWNERDRAW = 0x0000000B;
const ES_MULTILINE = 0x0004;
const ES_AUTOVSCROLL = 0x0040;
const ES_READONLY = 0x0800;
const WS_TABSTOP = 0x00010000;
const ODT_STATIC = 2;
const ODS_SELECTED = 0x0001;
const ODS_FOCUS = 0x0010;
const BN_CLICKED = 0;
const SM_CXVSCROLL = 2;
const COLOR_WINDOW = 5;
const COLOR_WINDOWTEXT = 8;
const COLOR_GRAYTEXT = 17;
const COLOR_HIGHLIGHT = 13;
const COLOR_HIGHLIGHTTEXT = 14;

/// Control ids: the buttons count up from here.
const id_button = 1000;
const id_body = 900;
const id_list = 901;

const hover_none = std.math.maxInt(usize);

/// All formats of one dialog at one DPI.
const Formats = struct {
    title: *dwrite.IDWriteTextFormat,
    body: *dwrite.IDWriteTextFormat,
    button: *dwrite.IDWriteTextFormat,
    list: *dwrite.IDWriteTextFormat,

    fn release(self: Formats) void {
        com.release(self.list);
        com.release(self.button);
        com.release(self.body);
        com.release(self.title);
    }
};

const Dialog = @This();

spec: Spec,
/// The text above the buttons; with a list, the lines (see `Spec.list`).
body: []const u16,
list: []const u16,
hwnd: ?HWND = null,
dpi: u32,
pal: colors.Palette,
mica: bool = false,
sh: *Chrome.Shared,
rt: ?*d2d1.ID2D1DCRenderTarget = null,
fonts: Formats,
title_family: [*:0]const u16,
body_family: [*:0]const u16,
list_family: [*:0]const u16,
plan: layout.Plan,
plan_input: layout.Input = undefined,
/// Line pitch of the list font as GDI sets it, and the tallest the list may be.
list_line_h: i32 = 0,
list_cap: i32 = 0,
/// The owner was already disabled when the dialog opened (it is nested in another one).
owner_was_disabled: bool = false,
labels: [max_buttons][64]u16 = undefined,
label_len: [max_buttons]usize = @splat(0),
accels: [max_buttons]u16 = @splat(0),
buttons: [max_buttons]?HWND = @splat(null),
body_static: ?HWND = null,
edit: ?HWND = null,
edit_font: ?gdi32.HFONT = null,
edit_brush: ?user32.HBRUSH = null,
state: keys.State,
hover: usize = hover_none,
kb_focus: bool = false,
result: ?i32 = null,
done: bool = false,
/// The first paint failure is logged, not every one.
paint_logged: bool = false,

/// Shows the dialog and returns the id of the button pressed; `cancel_id`
/// of the spec when it was closed. Null when the dialog could not be built
/// (nothing was shown): the caller falls back to a message box.
pub fn run(spec: Spec) ?i32 {
    if (spec.buttons.len == 0) return null;
    const sh = Chrome.shared() catch |err| {
        log.warn("no direct2d for the dialog err={}", .{err});
        return null;
    };

    var self: Dialog = undefined;
    self.init(spec, sh) catch |err| {
        log.warn("unable to build the dialog err={}", .{err});
        return null;
    };
    defer self.deinit();

    self.create() catch |err| {
        log.warn("unable to create the dialog window err={}", .{err});
        return null;
    };

    return self.loop();
}

fn ownerAlive(self: *const Dialog) ?HWND {
    const owner = self.spec.owner orelse return null;
    return if (user32.IsWindow(owner) != 0) owner else null;
}

fn init(self: *Dialog, spec: Spec, sh: *Chrome.Shared) !void {
    const dpi = dpiOf(spec.owner);
    const dark = ownerIsDark(spec.owner);
    const hc = theme.highContrast();
    const accent = colors.accentFor(dark, systemAccent());
    const pal = if (hc) colors.forHighContrast(systemColors()) else colors.forTheme(dark, accent);

    self.* = .{
        .spec = spec,
        .body = spec.body,
        .list = spec.list,
        .dpi = dpi,
        .pal = pal,
        .sh = sh,
        .fonts = undefined,
        .title_family = pickFamily(sh.dwrite, L("Segoe UI Variable Display"), L("Segoe UI")),
        .body_family = sh.title_family,
        .list_family = pickFamily(sh.dwrite, L("Cascadia Mono"), L("Consolas")),
        .plan = undefined,
        .state = keys.State.init(@min(spec.buttons.len, max_buttons), spec.default_index, spec.list.len > 0),
    };

    const count = @min(spec.buttons.len, max_buttons);
    for (spec.buttons[0..count], 0..) |b, i| {
        const stripped = text.stripAccelerator(&self.labels[i], b.text);
        self.label_len[i] = stripped.len;
        self.accels[i] = stripped.accel;
    }

    self.fonts = try self.makeFormats(dpi);
    errdefer self.fonts.release();
    self.plan = try self.buildPlan();
}

fn deinit(self: *Dialog) void {
    if (self.edit_font) |f| _ = gdi32.DeleteObject(@ptrCast(f));
    if (self.edit_brush) |b| _ = gdi32.DeleteObject(@ptrCast(b));
    com.release(self.rt);
    self.fonts.release();
}

// -- Environment ----------------------------------------------------------------------

fn dpiOf(owner: ?HWND) u32 {
    const dpi = if (owner) |o| user32.GetDpiForWindow(o) else 0;
    if (dpi != 0) return dpi;
    const sys = ext.GetDpiForSystem();
    return if (sys != 0) sys else 96;
}

/// The dialog follows the theme of its owner: the window's dark mode flag is
/// set from the same source as the chrome (`theme.applyToWindow`). Without an
/// owner, the system scheme.
fn ownerIsDark(owner: ?HWND) bool {
    if (owner) |o| {
        var flag: BOOL = 0;
        const hr = dwmapi.DwmGetWindowAttribute(o, dwmapi.DWMWA_USE_IMMERSIVE_DARK_MODE, &flag, @sizeOf(BOOL));
        if (hr >= 0) return flag != 0;
    }
    return util.systemUsesDarkTheme();
}

/// The accent colour the user picked in Settings (`DWM\AccentColor`, 0xAABBGGRR);
/// null when none was picked. The DWM colorization colour is not used: it is
/// the accent mixed with the glass tint, and comes out washed out.
fn systemAccent() ?colors.Rgba {
    var data: u32 = 0;
    var size: u32 = @sizeOf(u32);
    const rc = win32.advapi32.RegGetValueW(
        win32.advapi32.HKEY_CURRENT_USER,
        L("Software\\Microsoft\\Windows\\DWM"),
        L("AccentColor"),
        win32.advapi32.RRF_RT_REG_DWORD,
        null,
        &data,
        &size,
    );
    if (rc != 0) return null;
    return .{ .r = @truncate(data), .g = @truncate(data >> 8), .b = @truncate(data >> 16) };
}

fn systemColors() colors.SystemColors {
    const f = struct {
        fn get(index: i32) colors.Rgba {
            const c = user32.GetSysColor(index);
            return .{ .r = @truncate(c), .g = @truncate(c >> 8), .b = @truncate(c >> 16) };
        }
    };
    return .{
        .window = f.get(COLOR_WINDOW),
        .window_text = f.get(COLOR_WINDOWTEXT),
        .highlight = f.get(COLOR_HIGHLIGHT),
        .highlight_text = f.get(COLOR_HIGHLIGHTTEXT),
        .gray_text = f.get(COLOR_GRAYTEXT),
    };
}

fn pickFamily(dw: *dwrite.IDWriteFactory, preferred: [*:0]const u16, fallback: [*:0]const u16) [*:0]const u16 {
    const fonts = dwrite.getSystemFontCollection(dw) catch return fallback;
    defer com.release(fonts);
    const exists = fonts.hasFamily(preferred) catch return fallback;
    return if (exists) preferred else fallback;
}

fn colorF(c: colors.Rgba) d2d1.D2D1_COLOR_F {
    return .{
        .r = @as(f32, @floatFromInt(c.r)) / 255.0,
        .g = @as(f32, @floatFromInt(c.g)) / 255.0,
        .b = @as(f32, @floatFromInt(c.b)) / 255.0,
        .a = @as(f32, @floatFromInt(c.a)) / 255.0,
    };
}

fn colorRef(c: colors.Rgba) u32 {
    return @as(u32, c.r) | (@as(u32, c.g) << 8) | (@as(u32, c.b) << 16);
}

// -- Text ---------------------------------------------------------------------------

fn makeFormat(self: *Dialog, family: [*:0]const u16, weight: dwrite.FontWeight, px_size: i32, dpi: u32) !*dwrite.IDWriteTextFormat {
    const size: f32 = @floatFromInt(layout.px(px_size, dpi));
    const format = try self.sh.dwrite.createTextFormat(family, weight, .NORMAL, .NORMAL, size, L("en-us"));
    errdefer com.release(format);
    try format.setTextAlignment(.LEADING);
    try format.setParagraphAlignment(.NEAR);
    // A long word with no break (a URL) wraps by character, not off the edge.
    format.setWordWrapping(.EMERGENCY_BREAK) catch {};
    return format;
}

fn makeFormats(self: *Dialog, dpi: u32) !Formats {
    const title = try self.makeFormat(self.title_family, .SEMI_BOLD, layout.title_px, dpi);
    errdefer com.release(title);
    const body = try self.makeFormat(self.body_family, .NORMAL, layout.body_px, dpi);
    errdefer com.release(body);
    const button = try self.makeFormat(self.body_family, .NORMAL, layout.body_px, dpi);
    errdefer com.release(button);
    try button.setTextAlignment(.CENTER);
    try button.setParagraphAlignment(.CENTER);
    try button.setWordWrapping(.NO_WRAP);
    const sign = try self.sh.dwrite.createEllipsisTrimmingSign(button);
    defer com.release(sign);
    try button.setTrimming(.{ .granularity = .CHARACTER }, sign);
    const list = try self.makeFormat(self.list_family, .NORMAL, layout.list_px, dpi);
    errdefer com.release(list);
    return .{ .title = title, .body = body, .button = button, .list = list };
}

const Size = struct { w: i32, h: i32 };

/// Size in px of `str` set in `format`, wrapped at `max_w` px.
fn measure(self: *const Dialog, str: []const u16, format: *dwrite.IDWriteTextFormat, max_w: i32) !Size {
    if (str.len == 0) return .{ .w = 0, .h = 0 };
    const tl = try self.sh.dwrite.createTextLayout(str, format, @floatFromInt(max_w), 100000);
    defer com.release(tl);
    const m = try tl.getMetrics();
    return .{ .w = @intFromFloat(@ceil(m.width)), .h = @intFromFloat(@ceil(m.height)) };
}

fn label(self: *const Dialog, i: usize) []const u16 {
    return self.labels[i][0..self.label_len[i]];
}

const unwrapped = 20000;

/// The work area (px) of the monitor the dialog opens on.
fn workArea(self: *const Dialog) layout.Rect {
    var info: user32.MONITORINFO = .{};
    const monitor = if (self.ownerAlive()) |o|
        user32.MonitorFromWindow(o, user32.MONITOR_DEFAULTTONEAREST)
    else
        null;
    if (monitor) |m| {
        if (user32.GetMonitorInfoW(m, &info) != 0) return layout.Rect.fromRECT(info.rcWork);
    }
    return .{ .w = layout.px(1280, self.dpi), .h = layout.px(720, self.dpi) };
}

/// Measures the text and lays the dialog out at the current DPI. A body too
/// tall for the work area moves into the scrollable list.
fn buildPlan(self: *Dialog) !layout.Plan {
    const dpi = self.dpi;
    const count = @min(self.spec.buttons.len, max_buttons);
    const f = self.fonts;

    var label_w: [max_buttons]i32 = undefined;
    for (0..count) |i| label_w[i] = (try self.measure(self.label(i), f.button, unwrapped)).w;
    const buttons_w = layout.buttonsNaturalWidth(label_w[0..count], dpi);

    const title_wide = try self.measure(self.spec.title, f.title, unwrapped);
    const body_wide = try self.measure(self.body, f.body, unwrapped);
    const text_w = @max(title_wide.w, body_wide.w);

    var has_list = self.list.len > 0;
    var width = if (has_list) layout.px(layout.max_w, dpi) else layout.dialogWidth(text_w, buttons_w, dpi);
    var content_w = width - 2 * layout.px(layout.pad, dpi);

    var title = try self.measure(self.spec.title, f.title, content_w);
    var body = try self.measure(self.body, f.body, content_w);
    const work = self.workArea();
    var cap = layout.bodyCap(work.h, title.h, dpi);

    // Too tall to show: the body goes into the scrollable list, whole.
    if (!has_list and body.h > cap) {
        self.list = self.body;
        self.body = &.{};
        has_list = true;
        self.state = keys.State.init(count, self.spec.default_index, true);
        width = layout.px(layout.max_w, dpi);
        content_w = width - 2 * layout.px(layout.pad, dpi);
        title = try self.measure(self.spec.title, f.title, content_w);
        body = .{ .w = 0, .h = 0 };
        cap = layout.bodyCap(work.h, title.h, dpi);
    }
    if (has_list) body = try self.measure(self.body, f.body, content_w);

    var list_h: i32 = 0;
    if (has_list) {
        cap -= body.h;
        const cell = self.listMetrics();
        const scroll = user32.GetSystemMetricsForDpi(SM_CXVSCROLL, dpi);
        const cols: usize = @intCast(@max(1, @divFloor(
            content_w - 2 * layout.px(layout.list_inset + 6, dpi) - scroll,
            @max(cell.w, 1),
        )));
        const lines = layout.lineCount(self.list, cols);
        list_h = layout.listHeight(lines, cell.h, cap, dpi);
        self.list_line_h = cell.h;
        self.list_cap = cap;
    }

    self.plan_input = .{
        .dpi = dpi,
        .text_w = text_w,
        .buttons_w = buttons_w,
        .button_count = count,
        .title_h = title.h,
        .body_h = body.h,
        .list_h = list_h,
        .icon_h = if (self.spec.icon) layout.px(48, dpi) else 0,
    };
    return layout.plan(self.plan_input);
}

// -- Window ---------------------------------------------------------------------------

fn create(self: *Dialog) !void {
    const hinstance = win32.kernel32.GetModuleHandleW(null);
    try util.registerClass(&.{
        .style = user32.CS_HREDRAW | user32.CS_VREDRAW,
        .lpfnWndProc = wndProc,
        .hInstance = hinstance,
        .hCursor = user32.LoadCursorW(null, user32.IDC_ARROW),
        .lpszClassName = class_name,
    });

    const size: geom.Size = .{ .w = self.plan.width, .h = self.plan.height };
    const at = self.position(size);

    // Thick frame for the shadow and the rounded border; `WM_NCCALCSIZE`
    // takes the frame away, so the client area is the whole window.
    const hwnd = user32.CreateWindowExW(
        0,
        class_name,
        self.spec.window_title.ptr,
        user32.WS_POPUP | user32.WS_THICKFRAME | user32.WS_CLIPCHILDREN,
        at.x,
        at.y,
        size.w,
        size.h,
        self.ownerAlive(),
        null,
        hinstance,
        self,
    ) orelse {
        log.warn("CreateWindowExW failed err={}", .{win32.kernel32.GetLastError()});
        return error.CreateWindowFailed;
    };
    secure_input.apply(hwnd);
    errdefer _ = user32.DestroyWindow(hwnd);
    self.hwnd = hwnd;

    self.applyBackdrop();
    try self.createChildren();
}

/// Where the dialog goes: centred on the owner, or on the work area.
fn position(self: *const Dialog, size: geom.Size) geom.Point {
    const work = self.workArea();
    var anchor = work;
    if (self.ownerAlive()) |o| {
        var rc: RECT = undefined;
        if (user32.IsIconic(o) == 0 and user32.GetWindowRect(o, &rc) != 0) {
            anchor = layout.Rect.fromRECT(rc);
        }
    }
    return layout.centerIn(anchor, size, work);
}

fn applyBackdrop(self: *Dialog) void {
    const hwnd = self.hwnd.?;
    const dark_flag: BOOL = @intFromBool(self.pal.dark);
    _ = dwmapi.DwmSetWindowAttribute(hwnd, dwmapi.DWMWA_USE_IMMERSIVE_DARK_MODE, &dark_flag, @sizeOf(BOOL));
    const round: i32 = dwmapi.DWMWCP_ROUND;
    _ = dwmapi.DwmSetWindowAttribute(hwnd, dwmapi.DWMWA_WINDOW_CORNER_PREFERENCE, &round, @sizeOf(i32));

    // Mica where the system has it; the call fails before Windows 11 22H2.
    // Not under a list: GDI controls (the list is an edit control) draw
    // with alpha 0 on glass, so their text would show the backdrop instead
    // of its colour. Everything else is Direct2D.
    self.mica = false;
    if (!theme.highContrast() and self.list.len == 0) {
        const kind: i32 = dwmapi.DWMSBT_MAINWINDOW;
        const hr = dwmapi.DwmSetWindowAttribute(hwnd, dwmapi.DWMWA_SYSTEMBACKDROP_TYPE, &kind, @sizeOf(i32));
        if (hr >= 0) {
            const margins: dwmapi.MARGINS = .{ .cxLeftWidth = -1, .cxRightWidth = -1, .cyTopHeight = -1, .cyBottomHeight = -1 };
            self.mica = dwmapi.DwmExtendFrameIntoClientArea(hwnd, &margins) >= 0;
        }
    }
}

fn createChildren(self: *Dialog) !void {
    const hwnd = self.hwnd.?;
    const hinstance = win32.kernel32.GetModuleHandleW(null);
    const count = self.state.count;

    for (0..count) |i| {
        const r = self.plan.buttons[i];
        var wide: [65]u16 = undefined;
        // The name keeps its &, which screen readers report as the access key.
        const raw = self.spec.buttons[i].text;
        const raw_n = @min(raw.len, wide.len - 1);
        @memcpy(wide[0..raw_n], raw[0..raw_n]);
        wide[raw_n] = 0;
        const child = user32.CreateWindowExW(
            0,
            L("BUTTON"),
            @ptrCast(&wide),
            user32.WS_CHILD | user32.WS_VISIBLE | WS_TABSTOP | BS_OWNERDRAW,
            r.x,
            r.y,
            r.w,
            r.h,
            hwnd,
            @ptrFromInt(id_button + i),
            hinstance,
            null,
        ) orelse return error.CreateButtonFailed;
        self.buttons[i] = child;
    }

    // The text is painted by the window (a child cannot paint over Mica).
    // This one-pixel control, in the corner the rounding cuts off, only
    // carries the headline and the body for screen readers and draws
    // nothing (its brush is hollow, see `WM_CTLCOLORSTATIC`).
    if (self.spec.title.len + self.body.len > 0) {
        const alloc = std.heap.page_allocator;
        if (alloc.alloc(u16, self.spec.title.len + self.body.len + 2)) |buf| {
            defer alloc.free(buf);
            // The window text is the headline already when they are the same:
            // a screen reader would say it twice.
            const same = std.mem.eql(u16, self.spec.title, self.spec.window_title);
            const head = if (same) 0 else self.spec.title.len;
            @memcpy(buf[0..head], self.spec.title[0..head]);
            var n = head;
            if (self.body.len > 0) {
                if (head > 0) {
                    buf[n] = '\n';
                    n += 1;
                }
                @memcpy(buf[n..][0..self.body.len], self.body);
                n += self.body.len;
            }
            buf[n] = 0;
            self.body_static = user32.CreateWindowExW(
                user32.WS_EX_TRANSPARENT,
                L("STATIC"),
                @ptrCast(buf.ptr),
                user32.WS_CHILD | user32.WS_VISIBLE,
                0,
                0,
                1,
                1,
                hwnd,
                @ptrFromInt(id_body),
                hinstance,
                null,
            );
        } else |_| {}
    }

    if (self.list.len > 0) try self.createList(hwnd, hinstance);
}

fn listRect(self: *const Dialog) layout.Rect {
    const card = self.plan.list;
    const inset = layout.px(layout.list_inset, self.dpi);
    return .{ .x = card.x + 1, .y = card.y + inset, .w = card.w - 2, .h = card.h - 2 * inset };
}

fn createList(self: *Dialog, hwnd: HWND, hinstance: ?win32.foundation.HINSTANCE) !void {
    // The edit control wants CR LF.
    const alloc = std.heap.page_allocator;
    const wide = try alloc.alloc(u16, self.list.len * 2 + 1);
    defer alloc.free(wide);
    var n: usize = 0;
    for (self.list) |c| {
        if (c == '\n') {
            wide[n] = '\r';
            n += 1;
        }
        wide[n] = c;
        n += 1;
    }
    wide[n] = 0;

    const r = self.listRect();
    const edit = user32.CreateWindowExW(
        0,
        L("EDIT"),
        @ptrCast(wide.ptr),
        user32.WS_CHILD | user32.WS_VISIBLE | user32.WS_VSCROLL | WS_TABSTOP | ES_MULTILINE | ES_AUTOVSCROLL | ES_READONLY,
        r.x,
        r.y,
        r.w,
        r.h,
        hwnd,
        @ptrFromInt(id_list),
        hinstance,
        null,
    ) orelse return error.CreateListFailed;
    self.edit = edit;

    self.edit_brush = gdi32.CreateSolidBrush(colorRef(self.pal.card));
    self.applyListFont();
    const margin: LPARAM = @intCast(layout.px(8, self.dpi) | (layout.px(8, self.dpi) << 16));
    _ = user32.SendMessageW(edit, EM_SETMARGINS, EC_LEFTMARGIN | EC_RIGHTMARGIN, margin);
    _ = user32.SendMessageW(edit, EM_SETSEL, 0, 0);
    _ = uxtheme.SetWindowTheme(edit, if (self.pal.dark) L("DarkMode_Explorer") else L("Explorer"), null);
    self.fitList();
}

fn makeListFont(self: *const Dialog) ?gdi32.HFONT {
    const height = -layout.px(layout.list_px, self.dpi);
    return gdi32.CreateFontW(height, 0, 0, 0, 400, 0, 0, 0, 1, 0, 0, 4, 0x31, self.list_family);
}

/// Line pitch and character width (px) of the list font as GDI sets it: the
/// edit control draws with a GDI font, whose lines are not DirectWrite's.
fn listMetrics(self: *const Dialog) struct { h: i32, w: i32 } {
    const fallback = layout.px(layout.list_px + 4, self.dpi);
    const font = self.makeListFont() orelse return .{ .h = fallback, .w = layout.px(8, self.dpi) };
    defer _ = gdi32.DeleteObject(@ptrCast(font));
    const dc = gdi32.CreateCompatibleDC(null) orelse return .{ .h = fallback, .w = layout.px(8, self.dpi) };
    defer _ = gdi32.DeleteDC(dc);
    const old = gdi32.SelectObject(dc, @ptrCast(font));
    defer if (old) |o| {
        _ = gdi32.SelectObject(dc, o);
    };
    var tm: TEXTMETRICW = undefined;
    if (ext.GetTextMetricsW(dc, &tm) == 0) return .{ .h = fallback, .w = layout.px(8, self.dpi) };
    return .{ .h = tm.tmHeight + tm.tmExternalLeading, .w = @max(tm.tmAveCharWidth, 1) };
}

/// The list as the edit control wrapped it: its real line count, not the
/// estimate, sets the card's height (up to the cap).
fn fitList(self: *Dialog) void {
    const edit = self.edit orelse return;
    const hwnd = self.hwnd orelse return;
    const count = user32.SendMessageW(edit, EM_GETLINECOUNT, 0, 0);
    const lines: usize = @intCast(@max(count, 0));
    const want = layout.listHeight(lines, self.list_line_h, self.list_cap, self.dpi);
    defer self.updateScrollBar(lines);
    if (want == self.plan_input.list_h) return;

    self.plan_input.list_h = want;
    self.plan = layout.plan(self.plan_input);
    for (self.buttons[0..self.state.count], 0..) |b, i| if (b) |h| {
        const r = self.plan.buttons[i];
        _ = user32.MoveWindow(h, r.x, r.y, r.w, r.h, 1);
    };
    const r = self.listRect();
    _ = user32.MoveWindow(edit, r.x, r.y, r.w, r.h, 1);
    const size: geom.Size = .{ .w = self.plan.width, .h = self.plan.height };
    const at = self.position(size);
    _ = user32.SetWindowPos(hwnd, null, at.x, at.y, size.w, size.h, user32.SWP_NOZORDER | user32.SWP_NOACTIVATE);
    _ = user32.InvalidateRect(hwnd, null, 0);
}

/// The scrollbar shows only when the lines do not all fit.
fn updateScrollBar(self: *Dialog, lines: usize) void {
    const edit = self.edit orelse return;
    const r = self.listRect();
    const visible: usize = @intCast(@max(@divFloor(r.h, @max(self.list_line_h, 1)), 1));
    _ = ext.ShowScrollBar(edit, 1, @intFromBool(lines > visible));
}

fn applyListFont(self: *Dialog) void {
    const edit = self.edit orelse return;
    const font = self.makeListFont();
    _ = user32.SendMessageW(edit, WM_SETFONT, @intFromPtr(font), 1);
    if (self.edit_font) |old| _ = gdi32.DeleteObject(@ptrCast(old));
    self.edit_font = font;
}

// -- The loop -------------------------------------------------------------------------

fn loop(self: *Dialog) ?i32 {
    const hwnd = self.hwnd.?;
    const owner = self.ownerAlive();
    // EnableWindow answers whether the window was disabled already: nested in
    // another dialog, the owner stays disabled when this one closes.
    if (owner) |o| self.owner_was_disabled = ext.EnableWindow(o, 0) != 0;

    _ = user32.ShowWindow(hwnd, user32.SW_SHOW);
    _ = user32.SetForegroundWindow(hwnd);
    _ = user32.SetFocus(self.buttons[self.state.default] orelse hwnd);
    _ = user32.UpdateWindow(hwnd);

    var msg: user32.MSG = .{};
    while (!self.done) {
        const got = user32.GetMessageW(&msg, null, 0, 0);
        if (got == 0) {
            // WM_QUIT is not ours to swallow.
            user32.PostQuitMessage(@bitCast(@as(u32, @truncate(msg.wParam))));
            break;
        }
        if (got < 0) break;
        if (self.preTranslate(&msg)) continue;
        _ = user32.TranslateMessage(&msg);
        _ = user32.DispatchMessageW(&msg);
    }

    // Enable the owner first, so that destroying the dialog hands the
    // activation back to it and not to some other window.
    if (self.ownerAlive()) |o| if (!self.owner_was_disabled) {
        _ = ext.EnableWindow(o, 1);
    };
    if (self.hwnd) |h| {
        self.hwnd = null;
        _ = user32.DestroyWindow(h);
    }
    return self.result orelse self.spec.cancel_id;
}

/// wparam of msg_click_button as an id of one of the buttons or the cancel id.
fn knownId(self: *const Dialog, wparam: WPARAM) ?i32 {
    const id = std.math.cast(i32, wparam) orelse return null;
    if (id == self.spec.cancel_id) return id;
    for (self.spec.buttons[0..self.state.count]) |b| if (b.id == id) return id;
    return null;
}

fn finish(self: *Dialog, id: i32) void {
    if (self.done) return;
    self.result = id;
    self.done = true;
}

fn buttonIndex(self: *const Dialog, h: HWND) ?usize {
    for (self.buttons[0..self.state.count], 0..) |b, i| if (b == h) return i;
    return null;
}

/// Messages looked at before they are dispatched: the keyboard, and the
/// pointer over the buttons. True when the message is consumed.
fn preTranslate(self: *Dialog, msg: *const user32.MSG) bool {
    const dlg = self.hwnd orelse return false;
    const h = msg.hwnd orelse return false;
    if (h != dlg and ext.IsChild(dlg, h) == 0) return false;

    switch (msg.message) {
        user32.WM_KEYDOWN, user32.WM_SYSKEYDOWN => return self.onKey(msg),
        user32.WM_MOUSEMOVE => {
            if (self.buttonIndex(h)) |i| {
                if (self.hover != i) {
                    self.setHover(i);
                    var track: user32.TRACKMOUSEEVENT = .{ .dwFlags = user32.TME_LEAVE, .hwndTrack = h };
                    _ = user32.TrackMouseEvent(&track);
                }
            }
        },
        user32.WM_MOUSELEAVE => {
            if (self.buttonIndex(h)) |i| if (self.hover == i) self.setHover(hover_none);
        },
        user32.WM_LBUTTONDOWN => {
            self.kb_focus = false;
            if (self.buttonIndex(h)) |i| self.state.set(.{ .button = i });
        },
        else => {},
    }
    return false;
}

fn setHover(self: *Dialog, i: usize) void {
    const old = self.hover;
    self.hover = i;
    if (old < self.state.count) if (self.buttons[old]) |b| {
        _ = user32.InvalidateRect(b, null, 0);
    };
    if (i < self.state.count) if (self.buttons[i]) |b| {
        _ = user32.InvalidateRect(b, null, 0);
    };
}

/// The focus the system reports, brought into the state machine.
fn syncFocus(self: *Dialog) void {
    const focus = user32.GetFocus() orelse return;
    if (self.edit != null and focus == self.edit.?) {
        self.state.set(.list);
    } else if (self.buttonIndex(focus)) |i| {
        self.state.set(.{ .button = i });
    }
}

fn onKey(self: *Dialog, msg: *const user32.MSG) bool {
    const vk: u32 = @truncate(msg.wParam);
    const alt = msg.message == user32.WM_SYSKEYDOWN;
    const ctrl = user32.GetKeyState(user32.VK_CONTROL) < 0;

    var key: keys.Key = undefined;
    if (alt) {
        if (vk == user32.VK_F4) {
            key = .alt_f4;
        } else {
            // Alt + the underlined letter presses that button.
            for (self.accels[0..self.state.count], 0..) |a, i| {
                if (a != 0 and a == vk) {
                    self.finish(self.spec.buttons[i].id);
                    return true;
                }
            }
            return false;
        }
    } else {
        if (ctrl and vk != user32.VK_TAB) return false;
        key = switch (vk) {
            user32.VK_TAB => if (user32.GetKeyState(user32.VK_SHIFT) < 0) .shift_tab else .tab,
            user32.VK_LEFT => .left,
            user32.VK_RIGHT => .right,
            user32.VK_UP => .up,
            user32.VK_DOWN => .down,
            user32.VK_HOME => .home,
            user32.VK_END => .end,
            user32.VK_RETURN => .enter,
            user32.VK_ESCAPE => .escape,
            else => return false,
        };
    }

    self.syncFocus();
    switch (self.state.press(key)) {
        .pass => return false,
        .none => {},
        .focus => |f| self.moveFocus(f),
        .activate => |i| self.finish(self.spec.buttons[i].id),
        .cancel => self.finish(self.spec.cancel_id),
    }
    return true;
}

fn moveFocus(self: *Dialog, f: keys.Focus) void {
    self.kb_focus = true;
    const target = switch (f) {
        .list => self.edit,
        .button => |i| self.buttons[i],
    };
    if (target) |t| _ = user32.SetFocus(t);
    for (self.buttons[0..self.state.count]) |b| if (b) |h| {
        _ = user32.InvalidateRect(h, null, 0);
    };
}

// -- Painting -------------------------------------------------------------------------

fn renderTarget(self: *Dialog) !*d2d1.ID2D1DCRenderTarget {
    if (self.rt) |t| return t;
    const t = try self.sh.d2d.createDCRenderTarget(.{
        .type = .SOFTWARE,
        .pixelFormat = .{ .format = .B8G8R8A8_UNORM, .alphaMode = .PREMULTIPLIED },
        .dpiX = 96,
        .dpiY = 96,
    });
    self.rt = t;
    return t;
}

fn dropTarget(self: *Dialog) void {
    com.release(self.rt);
    self.rt = null;
}

const Pen = struct {
    rt: *d2d1.ID2D1RenderTarget,
    brush: *d2d1.ID2D1SolidColorBrush,
    dw: *dwrite.IDWriteFactory,

    fn rectF(r: layout.Rect) d2d1.D2D1_RECT_F {
        return .{
            .left = @floatFromInt(r.x),
            .top = @floatFromInt(r.y),
            .right = @floatFromInt(r.right()),
            .bottom = @floatFromInt(r.bottom()),
        };
    }

    fn fill(self: Pen, r: layout.Rect, c: colors.Rgba) void {
        self.brush.setColor(colorF(c));
        self.rt.fillRectangle(rectF(r), self.brush.asBrush());
    }

    fn fillRound(self: Pen, r: layout.Rect, radius: f32, c: colors.Rgba) void {
        self.brush.setColor(colorF(c));
        self.rt.fillRoundedRectangle(.{ .rect = rectF(r), .radiusX = radius, .radiusY = radius }, self.brush.asBrush());
    }

    /// An outline of `width` px lying inside `r`.
    fn strokeRound(self: Pen, r: layout.Rect, radius: f32, width: f32, inset: f32, c: colors.Rgba) void {
        self.brush.setColor(colorF(c));
        const half = width / 2 + inset;
        const rect: d2d1.D2D1_RECT_F = .{
            .left = @as(f32, @floatFromInt(r.x)) + half,
            .top = @as(f32, @floatFromInt(r.y)) + half,
            .right = @as(f32, @floatFromInt(r.right())) - half,
            .bottom = @as(f32, @floatFromInt(r.bottom())) - half,
        };
        const rad = @max(radius - half, 0);
        self.rt.drawRoundedRectangle(.{ .rect = rect, .radiusX = rad, .radiusY = rad }, self.brush.asBrush(), width);
    }

    fn drawText(self: Pen, r: layout.Rect, str: []const u16, format: *dwrite.IDWriteTextFormat, c: colors.Rgba) void {
        if (r.w <= 0 or r.h <= 0 or str.len == 0) return;
        const tl = self.dw.createTextLayout(str, format, @floatFromInt(r.w), @floatFromInt(r.h)) catch return;
        defer com.release(tl);
        self.brush.setColor(colorF(c));
        self.rt.drawTextLayout(
            .{ .x = @floatFromInt(r.x), .y = @floatFromInt(r.y) },
            tl,
            self.brush.asBrush(),
            d2d1.DRAW_TEXT_OPTIONS_CLIP,
        );
    }
};

/// Binds the render target to `hdc` and runs `body`; a lost device drops the
/// target so that the next paint makes a new one.
fn draw(self: *Dialog, hdc: HDC, w: i32, h: i32, clear: ?colors.Rgba, ctx: anytype, comptime body: fn (*Dialog, Pen, @TypeOf(ctx)) void) !void {
    const t = try self.renderTarget();
    try t.bindDC(hdc, .{ .left = 0, .top = 0, .right = w, .bottom = h });
    const rt = t.asRenderTarget();
    const brush = try rt.createSolidColorBrush(.{ .r = 0, .g = 0, .b = 0, .a = 1 });
    defer com.release(brush);

    rt.beginDraw();
    rt.setTextAntialiasMode(.GRAYSCALE);
    rt.clear(if (clear) |c| colorF(c) else null);
    body(self, .{ .rt = rt, .brush = brush, .dw = self.sh.dwrite }, ctx);
    rt.endDraw() catch |err| {
        if (err == error.DeviceLost) self.dropTarget();
        return err;
    };
}

/// `draw` into a buffered (premultiplied) DIB that is then blended onto
/// `hdc`, so that pixels left transparent show the Mica behind.
fn drawBuffered(self: *Dialog, hdc: HDC, rc: RECT, ctx: anytype, comptime body: fn (*Dialog, Pen, @TypeOf(ctx)) void) void {
    const params: uxtheme.BP_PAINTPARAMS = .{ .dwFlags = uxtheme.BPPF_ERASE };
    var mem: ?HDC = null;
    const buffer = uxtheme.BeginBufferedPaint(hdc, &rc, uxtheme.BPBF_TOPDOWNDIB, &params, &mem);
    const clear: ?colors.Rgba = if (self.mica) null else self.pal.body_solid;
    self.draw(mem orelse hdc, rc.right - rc.left, rc.bottom - rc.top, clear, ctx, body) catch |err| {
        if (!self.paint_logged) log.warn("unable to paint the dialog err={}", .{err});
        self.paint_logged = true;
    };
    if (buffer) |b| _ = uxtheme.EndBufferedPaint(b, 1);
}

fn drawParent(self: *Dialog, pen: Pen, _: void) void {
    const p = &self.plan;
    const pal = &self.pal;
    pen.drawText(p.title, self.spec.title, self.fonts.title, pal.text);
    pen.drawText(p.body, self.body, self.fonts.body, pal.text);

    if (p.list.h > 0) {
        const radius: f32 = @floatFromInt(layout.px(layout.card_radius, self.dpi));
        pen.fillRound(p.list, radius, pal.card);
        pen.strokeRound(p.list, radius, 1, 0, pal.card_border);
    }

    pen.fill(p.footer, pal.footer);
    pen.fill(.{ .x = p.footer.x, .y = p.footer.y, .w = p.footer.w, .h = 1 }, pal.divider);
}

fn drawIcon(self: *Dialog, hdc: user32.HDC) void {
    if (!self.spec.icon or self.plan.icon.w <= 0) return;
    const hinstance = win32.kernel32.GetModuleHandleW(null);
    const id: *const anyopaque = @ptrFromInt(1);
    const icon = user32.LoadImageW(hinstance, id, user32.IMAGE_ICON, self.plan.icon.w, self.plan.icon.h, user32.LR_DEFAULTCOLOR) orelse return;
    defer _ = user32.DestroyIcon(@ptrCast(icon));
    _ = ext.DrawIconEx(hdc, self.plan.icon.x, self.plan.icon.y, @ptrCast(icon), self.plan.icon.w, self.plan.icon.h, 0, null, 3);
}

fn paint(self: *Dialog, hwnd: HWND) void {
    var ps: user32.PAINTSTRUCT = undefined;
    const hdc = user32.BeginPaint(hwnd, &ps) orelse return;
    defer _ = user32.EndPaint(hwnd, &ps);

    var rc: RECT = undefined;
    _ = user32.GetClientRect(hwnd, &rc);
    self.drawBuffered(hdc, rc, {}, drawParent);
    self.drawIcon(hdc);
}

const ButtonPaint = struct {
    index: usize,
    state: u32,
};

fn drawButtonBody(self: *Dialog, pen: Pen, bp: ButtonPaint) void {
    const i = bp.index;
    const pal = &self.pal;
    const r = self.plan.buttons[i];
    const local: layout.Rect = .{ .w = r.w, .h = r.h };
    const radius: f32 = @floatFromInt(layout.px(layout.button_radius, self.dpi));
    const pressed = bp.state & ODS_SELECTED != 0;
    const hot = self.hover == i;
    const accent = i == self.spec.default_index;

    const fill_c = if (accent)
        (if (pressed) pal.accent_pressed else if (hot) pal.accent_hover else pal.accent)
    else
        (if (pressed) pal.button_pressed else if (hot) pal.button_hover else pal.button);
    const ink = if (accent)
        (if (pressed) pal.accent_text_pressed else pal.accent_text)
    else
        (if (pressed) pal.button_text_pressed else pal.button_text);

    pen.fillRound(local, radius, fill_c);
    if (!accent) pen.strokeRound(local, radius, 1, 0, pal.button_border);
    pen.drawText(local, self.label(i), self.fonts.button, ink);

    if (bp.state & ODS_FOCUS != 0 and self.kb_focus) {
        pen.strokeRound(local, radius, 2, 0, pal.focus_outer);
        pen.strokeRound(local, radius, 1, 2, pal.focus_inner);
    }
}

fn drawItem(self: *Dialog, dis: *const DRAWITEMSTRUCT) void {
    const hdc = dis.hDC orelse return;
    const w = dis.rcItem.right - dis.rcItem.left;
    const h = dis.rcItem.bottom - dis.rcItem.top;
    // The screen reader control draws nothing.
    if (dis.CtlType == ODT_STATIC) return;
    const item = dis.hwndItem orelse return;
    const i = self.buttonIndex(item) orelse return;
    self.draw(hdc, w, h, self.pal.footer, ButtonPaint{ .index = i, .state = dis.itemState }, drawButtonBody) catch |err| {
        if (!self.paint_logged) log.warn("unable to paint a dialog button err={}", .{err});
        self.paint_logged = true;
    };
}

// -- DPI --------------------------------------------------------------------------------

/// The dialog moved to a monitor with another DPI: new formats, new plan,
/// children moved, the window resized around the suggested position.
fn dpiChanged(self: *Dialog, new_dpi: u32, suggested: ?*const RECT) void {
    const hwnd = self.hwnd orelse return;
    if (new_dpi == 0 or new_dpi == self.dpi) return;

    const formats = self.makeFormats(new_dpi) catch return;
    const old = self.fonts;
    const old_dpi = self.dpi;
    self.fonts = formats;
    self.dpi = new_dpi;
    self.body = self.spec.body;
    self.list = self.spec.list;
    const plan = self.buildPlan() catch {
        // Keep the old look rather than a half scaled one.
        self.fonts = old;
        self.dpi = old_dpi;
        formats.release();
        return;
    };
    old.release();
    self.plan = plan;

    var x: i32 = 0;
    var y: i32 = 0;
    if (suggested) |r| {
        x = r.left;
        y = r.top;
    } else {
        var rc: RECT = undefined;
        _ = user32.GetWindowRect(hwnd, &rc);
        x = rc.left;
        y = rc.top;
    }
    for (self.buttons[0..self.state.count], 0..) |b, i| if (b) |h| {
        const r = plan.buttons[i];
        _ = user32.MoveWindow(h, r.x, r.y, r.w, r.h, 1);
    };
    if (self.edit) |e| {
        const r = self.listRect();
        _ = user32.MoveWindow(e, r.x, r.y, r.w, r.h, 1);
        self.applyListFont();
    }
    _ = user32.SetWindowPos(hwnd, null, x, y, plan.width, plan.height, user32.SWP_NOZORDER | user32.SWP_NOACTIVATE);
    _ = user32.InvalidateRect(hwnd, null, 0);
}

// -- Window procedure -------------------------------------------------------------------

fn lo(v: usize) u32 {
    return @as(u32, @truncate(v)) & 0xFFFF;
}

fn hi(v: usize) u32 {
    return (@as(u32, @truncate(v)) >> 16) & 0xFFFF;
}

fn wndProc(hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) LRESULT {
    if (msg == user32.WM_NCCREATE) {
        const cs: *const user32.CREATESTRUCTW = @ptrFromInt(@as(usize, @bitCast(lparam)));
        util.setUserData(hwnd, cs.lpCreateParams);
        return user32.DefWindowProcW(hwnd, msg, wparam, lparam);
    }
    const self = util.fromUserData(Dialog, hwnd) orelse return user32.DefWindowProcW(hwnd, msg, wparam, lparam);

    switch (msg) {
        // No frame: the client area is the whole window.
        user32.WM_NCCALCSIZE => return 0,
        user32.WM_NCHITTEST => {
            // The text area drags the dialog; nothing resizes it.
            var pt: win32.foundation.POINT = .{
                .x = @as(i16, @truncate(lparam)),
                .y = @as(i16, @truncate(lparam >> 16)),
            };
            _ = user32.ScreenToClient(hwnd, &pt);
            return if (pt.y >= 0 and pt.y < self.plan.drag_h) user32.HTCAPTION else user32.HTCLIENT;
        },
        WM_NCLBUTTONDBLCLK => return 0,
        user32.WM_ERASEBKGND => return 1,
        user32.WM_PAINT => {
            self.paint(hwnd);
            return 0;
        },
        WM_DRAWITEM => {
            const dis: *const DRAWITEMSTRUCT = @ptrFromInt(@as(usize, @bitCast(lparam)));
            self.drawItem(dis);
            return 1;
        },
        user32.WM_COMMAND => {
            const id = lo(wparam);
            if (hi(wparam) == BN_CLICKED and id >= id_button and id < id_button + self.state.count) {
                self.finish(self.spec.buttons[id - id_button].id);
            }
            return 0;
        },
        WM_CTLCOLORSTATIC, user32.WM_CTLCOLOREDIT => {
            const h: ?HWND = @ptrFromInt(@as(usize, @bitCast(lparam)));
            const hdc: HDC = @ptrFromInt(wparam);
            if (h != null and self.edit != null and h.? == self.edit.?) {
                _ = ext.SetTextColor(hdc, colorRef(self.pal.text));
                _ = ext.SetBkColor(hdc, colorRef(self.pal.card));
                if (self.edit_brush) |b| return @bitCast(@intFromPtr(b));
            } else if (h != null and self.body_static != null and h.? == self.body_static.?) {
                // Hollow: not even the pixel of the screen reader control is filled.
                _ = ext.SetBkMode(hdc, 1);
                if (gdi32.GetStockObject(gdi32.NULL_BRUSH)) |b| return @bitCast(@intFromPtr(b));
            }
        },
        user32.WM_DPICHANGED => {
            const suggested: *const RECT = @ptrFromInt(@as(usize, @bitCast(lparam)));
            self.dpiChanged(lo(wparam), suggested);
            return 0;
        },
        msg_click_button => {
            if (self.knownId(wparam)) |id| self.finish(id);
            return 0;
        },
        user32.WM_CLOSE => {
            self.finish(self.spec.cancel_id);
            return 0;
        },
        user32.WM_DESTROY => {
            // Destroyed under the loop (the owner went away): stop it.
            self.hwnd = null;
            self.finish(self.spec.cancel_id);
        },
        else => {},
    }
    return user32.DefWindowProcW(hwnd, msg, wparam, lparam);
}
