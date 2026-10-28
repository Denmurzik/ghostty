//! Transparency and backdrop blur: the composition swap chain of a surface,
//! the window backdrop that shows through it, and
//! `toggle_background_opacity`.
//!
//! Two layers, both owned here:
//!
//! * Surface: with `background-opacity < 1` or `background-blur` the
//!   renderer presents a premultiplied composition swap chain
//!   (`renderer.D3D11.PresentTarget.hand_off`). The chain is attached to a
//!   DirectComposition visual on the surface child window. The default
//!   opaque config never leaves hwnd mode (no DComp device, no target).
//! * Window: the top-level window is made transparent with
//!   `DwmEnableBlurBehindWindow` (spike R10: an empty blur region turns on
//!   per-pixel alpha, `DwmExtendFrameIntoClientArea(-1)` + `DWMSBT_NONE`
//!   stays opaque black). The surface child erases itself black so its area
//!   is alpha 0, once its visual shows a chain (`surfaceErase`).
//!   `.acrylic` adds the system Acrylic material.
//!
//! Whether a window can be translucent is decided once, when it is created
//! (`WindowState.glass`): measured on Windows 11 10.0.26300, a window that
//! was shown opaque, or that showed an hwnd swap chain, keeps an opaque
//! surface for good (`DwmEnableBlurBehindWindow`, SWP_FRAMECHANGED, a resize,
//! a maximize, hide/show and re-parenting the child did not bring the alpha
//! back). So a window born translucent stays in composition mode for its
//! whole life and goes solid (backdrop `.opaque`) when the config asks for
//! `background-opacity = 1`, the same reversible state as
//! `toggle_background_opacity`. A window born opaque stays solid: a later
//! translucent config only reaches windows created afterwards, like
//! `background-opacity` on macOS ("requires restarting"); its surfaces still
//! switch to composition so that the renderer's premultiplied colours are
//! composed over the solid background (an hwnd chain would show them dim), and
//! back to hwnd when the config is opaque again.
//!
//! Chrome API (Task 15b paints the title and tab rows with the same alpha):
//! `isTranslucent(window)`, `windowAlpha(window)`, `applyToWindow(window)`.
//! `applyToWindow` runs at the end of `frame.applyDecorations`; it is a no-op
//! for a window that is not translucent-capable.
//!
//! Threads: everything except `handOff` (render thread, context lock held)
//! runs on the UI thread. The chain crosses threads in
//! `SurfaceState.pending`.
const std = @import("std");
const win32 = @import("win32");
const apprt = @import("../../apprt.zig");
const configpkg = @import("../../config.zig");
const renderer = @import("../../renderer.zig");
const App = @import("App.zig");
const Surface = @import("Surface.zig");
const Tab = @import("Tab.zig");
const Window = @import("Window.zig");
const messages = @import("messages.zig");
const theme = @import("theme.zig");
const Chrome = @import("Chrome.zig");
const recovery = @import("recovery.zig");
const frame = @import("frame.zig");

const dcomp = win32.dcomp;
const dxgi = win32.dxgi;
const com = win32.com;

const log = std.log.scoped(.win32_composition);

/// What shows behind the terminal.
pub const Backdrop = enum {
    /// The M2 default: `frame.apply` decides (Mica under the title row).
    mica,
    /// Translucent window with the system Acrylic material behind it; the
    /// blur also shows while the window is inactive (`windowMessage`).
    acrylic,
    /// Translucent window, no blur.
    transparent,
    /// A translucent-capable window shown solid: the config says
    /// `background-opacity = 1`, or `toggle_background_opacity`.
    @"opaque",
};

/// The two config values a backdrop depends on. `WindowState` keeps a copy:
/// `frame.applyDecorations` calls `applyToWindow` before `App.config` holds a
/// reloaded config.
pub const Look = struct {
    opacity: f64 = 1.0,
    blur: bool = false,

    pub fn of(config: *const configpkg.Config) Look {
        return .{
            .opacity = std.math.clamp(config.@"background-opacity", 0.0, 1.0),
            .blur = config.@"background-blur" != .false,
        };
    }

    fn translucent(self: Look) bool {
        return self.opacity < 1.0;
    }
};

pub const AppState = struct {
    /// One null-rendering-device DComp device per process, created on the
    /// first composition surface. It survives a D3D device loss (spike l).
    device: ?*dcomp.IDCompositionDevice = null,
};

pub const WindowState = struct {
    /// `toggle_background_opacity`: the window shows solid although the
    /// config is translucent.
    toggled_opaque: bool = false,
    backdrop: Backdrop = .mica,
    look: Look = .{},
    /// Decided once, by the first `applyToWindow` or surface of the window.
    decided: bool = false,
    /// The window is translucent-capable: its surfaces are in composition mode.
    glass: bool = false,
};

pub const SurfaceState = struct {
    /// The swap chain mode the renderer reads (0 = hwnd, 1 = composition).
    mode: std.atomic.Value(u8) = .init(0),
    /// UI thread only.
    target: ?*dcomp.IDCompositionTarget = null,
    visual: ?*dcomp.IDCompositionVisual = null,
    /// The chain waiting for `WM_GHOSTTY_SET_CONTENT`; owns one reference.
    pending: std.atomic.Value(?*dxgi.IDXGISwapChain1) = .init(null),
    /// The generation `pending` was created with; written before `pending`.
    pending_generation: std.atomic.Value(u32) = .init(0),
    /// Chains attached so far (test state).
    attached: u32 = 0,
    /// The visual shows a chain (handed off with a frame in it). Until then
    /// the surface erases itself with a stand-in for that frame. UI thread.
    showing: bool = false,
};

/// Whether the config needs a composition swap chain.
pub fn wantComposition(config: *const configpkg.Config, high_contrast: bool) bool {
    if (high_contrast) return false;
    return Look.of(config).translucent();
}

pub fn backdropFor(config: *const configpkg.Config, toggled_opaque: bool, high_contrast: bool) Backdrop {
    if (!wantComposition(config, high_contrast)) return .mica;
    return backdropOf(Look.of(config), toggled_opaque);
}

/// The backdrop of a translucent-capable window.
fn backdropOf(look: Look, toggled_opaque: bool) Backdrop {
    if (toggled_opaque or !look.translucent()) return .@"opaque";
    return if (look.blur) .acrylic else .transparent;
}

/// The window shows what is behind it (transparent client area).
pub fn isTranslucent(window: *const Window) bool {
    return switch (window.composition.backdrop) {
        .acrylic, .transparent => true,
        .mica, .@"opaque" => false,
    };
}

/// The alpha the chrome paints its rows with: the configured opacity while
/// translucent, 1 otherwise.
pub fn windowAlpha(window: *const Window) f32 {
    if (!isTranslucent(window)) return 1.0;
    return @floatCast(window.composition.look.opacity);
}

// ----------------------------------------------------------------------
// Surface

/// Decides once, from the config at the window's creation, whether the
/// window can be translucent.
fn decide(window: *Window) void {
    if (window.composition.decided) return;
    window.composition.decided = true;
    window.composition.look = .of(&window.app.config);
    window.composition.glass = wantComposition(&window.app.config, theme.highContrast());
}

/// Before core initialises the surface (the renderer thread starts there):
/// the first swap chain must already be in the right mode.
pub fn surfaceWillInit(surface: *Surface) void {
    const window = surface.window;
    decide(window);
    // A translucent-capable window is always in composition mode; any other
    // window only while the config asks for it (it then shows solid, see
    // `configChanged`).
    if (!window.composition.glass and !wantComposition(&surface.app.config, theme.highContrast())) return;
    enterComposition(surface) catch |err|
        log.warn("surface {d}: staying in hwnd mode err={}", .{ surface.id, err });
}

/// After core initialised the surface.
pub fn surfaceCreated(surface: *Surface) void {
    _ = surface;
}

/// The chain was handed over by the renderer: park it and wake the UI
/// thread. Render thread, context lock held: post-only.
pub fn handOff(ctx: *anyopaque, chain: *dxgi.IDXGISwapChain1, generation: u32) void {
    const surface: *Surface = @ptrCast(@alignCast(ctx));
    park(&surface.composition, chain, generation);
    if (win32.user32.PostMessageW(surface.hwnd, messages.WM_GHOSTTY_SET_CONTENT, generation, 0) == 0) {
        // The window is gone; Surface.deinit releases `pending`.
        log.debug("surface {d}: hand-off post failed", .{surface.id});
    }
}

pub fn handOffFor(surface: *Surface) renderer.D3D11.PresentTarget.HandOff {
    return .{ .ctx = surface, .func = handOff };
}

fn park(state: *SurfaceState, chain: *dxgi.IDXGISwapChain1, generation: u32) void {
    state.pending_generation.store(generation, .release);
    com.release(state.pending.swap(chain, .acq_rel));
}

/// `WM_GHOSTTY_SET_CONTENT` on a surface.
pub fn setContent(surface: *Surface, wparam: win32.foundation.WPARAM) ?win32.foundation.LRESULT {
    _ = wparam;
    const state = &surface.composition;
    const chain = state.pending.swap(null, .acq_rel) orelse return 0;
    const generation = state.pending_generation.load(.acquire);
    const stand_in = !state.showing;
    if (!attach(&surface.app.composition, state, chain, generation, surface.present_generation.load(.acquire))) return 0;
    // The stand-in goes only once DWM shows the frame: cleared any earlier,
    // the glass would show through for a moment (a white flash over Acrylic).
    if (stand_in and eraseTransparent(surface.window)) {
        if (surface.app.composition.device) |d| d.waitForCommitCompletion() catch {};
        surface.repaintBackground();
    }
    return 0;
}

/// Shows `chain` (one reference, always released) unless it belongs to an
/// older present target or the surface has no visual any more. True when
/// the visual shows it.
fn attach(
    app_state: *AppState,
    state: *SurfaceState,
    chain: *dxgi.IDXGISwapChain1,
    chain_generation: u32,
    current_generation: u32,
) bool {
    defer com.release(chain);
    if (chain_generation != current_generation) return false;
    const visual = state.visual orelse return false;
    const device = app_state.device orelse return false;
    visual.setContent(chain) catch |err| {
        log.warn("SetContent failed err={}", .{err});
        return false;
    };
    device.commit() catch |err| {
        log.warn("Commit failed err={}", .{err});
        return false;
    };
    state.attached += 1;
    state.showing = true;
    return true;
}

fn ensureDevice(app_state: *AppState) !*dcomp.IDCompositionDevice {
    if (app_state.device) |d| return d;
    const d = try dcomp.createDevice(null);
    app_state.device = d;
    return d;
}

/// Creates the target and visual of `hwnd`. The old tree is released first
/// (a second target on one window fails with WINDOW_ALREADY_COMPOSED).
fn createTree(device: *dcomp.IDCompositionDevice, state: *SurfaceState, hwnd: win32.foundation.HWND) !void {
    destroyTree(device, state);
    const target = try device.createTargetForHwnd(hwnd, true);
    errdefer com.release(target);
    const visual = try device.createVisual();
    errdefer com.release(visual);
    try target.setRoot(visual);
    try device.commit();
    state.target = target;
    state.visual = visual;
}

/// SetContent(null) + Commit, then the target and visual go.
fn destroyTree(device: ?*dcomp.IDCompositionDevice, state: *SurfaceState) void {
    if (state.visual) |v| v.setContent(null) catch {};
    if (device) |d| if (state.visual != null) d.commit() catch {};
    com.release(state.target);
    com.release(state.visual);
    state.target = null;
    state.visual = null;
    state.showing = false;
}

/// hwnd -> composition, before the surface has any swap chain: the tree
/// exists before the renderer is told (the store).
fn enterComposition(surface: *Surface) !void {
    const state = &surface.composition;
    const device = try ensureDevice(&surface.app.composition);
    try createTree(device, state, surface.hwnd);
    state.mode.store(1, .release);
}

/// Before core tears the surface down: the visual stops showing the chain.
/// The mode stays as it is: the render thread runs until core deinit, and a
/// frame drawn after a store of 0 would retire the composition chain and
/// create an hwnd chain on a closing pane (and could taint the glass of its
/// window). A chain handed over late finds no visual in `attach` and is
/// released.
pub fn surfaceDestroying(surface: *Surface) void {
    destroyTree(surface.app.composition.device, &surface.composition);
}

/// After core's render thread is gone: nothing can be handed over any more.
pub fn surfaceReleased(surface: *Surface) void {
    com.release(surface.composition.pending.swap(null, .acq_rel));
}

/// composition -> hwnd: the target must go BEFORE the store, or the
/// renderer's `CreateSwapChainForHwnd` fails (the window is still composed).
fn leaveComposition(surface: *Surface) void {
    const state = &surface.composition;
    destroyTree(surface.app.composition.device, state);
    state.mode.store(0, .release);
}

const SyncAction = enum { none, enter, leave };

/// What a surface in (or out of) composition mode does to reach `want`.
fn syncAction(in_composition: bool, want: bool) SyncAction {
    if (in_composition == want) return .none;
    return if (want) .enter else .leave;
}

/// Whether the surfaces of a window should be in composition mode: always on
/// a glass window, else when the config asks for it.
fn wantFor(glass: bool, config_wants: bool) bool {
    return glass or config_wants;
}

/// Puts a surface of a window that is not translucent-capable in the mode the
/// config asks for, and asks the renderer to draw once so it takes the new
/// mode (the renderer reads it only while drawing). hwnd -> composition
/// creates the tree while the hwnd chain still exists, which works (measured).
fn syncSurface(surface: *Surface, want: bool) void {
    const state = &surface.composition;
    const action = syncAction(state.mode.load(.acquire) == 1, want);
    if (action == .none) return;
    if (action == .enter) {
        enterComposition(surface) catch |err| {
            log.warn("surface {d}: unable to enter composition err={}", .{ surface.id, err });
            return;
        };
    } else {
        leaveComposition(surface);
    }
    surface.bumpPresentTarget();
}

/// Re-parenting keeps the target (spike e); nothing to recreate.
pub fn tabReparented(tab: *Tab, from: *Window, to: *Window) void {
    _ = from;
    // A surface from a window of the other kind follows the new window.
    decide(to);
    const want = wantFor(to.composition.glass, wantComposition(&to.app.config, theme.highContrast()));
    var it = tab.tree.iterator();
    while (it.next()) |entry| syncSurface(entry.view, want);
}

/// A split that was parked (out of every tree, so out of `configChanged`) is
/// back: it takes the mode the config asks for now.
pub fn surfaceUnparked(surface: *Surface) void {
    const window = surface.window;
    decide(window);
    syncSurface(surface, wantFor(window.composition.glass, wantComposition(&window.app.config, theme.highContrast())));
}

// ----------------------------------------------------------------------
// Window

pub fn configChanged(app: *App, config: *const configpkg.Config) void {
    const hc = theme.highContrast();
    const look = Look.of(config);
    var windows = app.forEachWindow(true);
    while (windows.next()) |window| {
        if (window.tearing_down) continue;
        decide(window);
        window.composition.toggled_opaque = false;
        window.composition.look = look;
        if (!window.composition.glass) {
            // Created opaque: the window stays solid (a translucent look
            // needs a window created for it), but the surfaces follow the
            // config so that the renderer's premultiplied colours are
            // composed over the solid background instead of being shown dim.
            const want = wantComposition(config, hc);
            var all_tabs = window.allTabs();
            while (all_tabs.next()) |tab| {
                var it = tab.tree.iterator();
                while (it.next()) |entry| syncSurface(entry.view, want);
            }
            continue;
        }
        applyGlass(window, if (hc) .mica else backdropOf(look, false));
    }
}

/// Puts the window's backdrop in line with the config and the toggle.
/// Called at the end of `frame.applyDecorations`.
pub fn applyToWindow(window: *Window) void {
    decide(window);
    if (!window.composition.glass) return;
    const bd = if (theme.highContrast()) Backdrop.mica else backdropOf(window.composition.look, window.composition.toggled_opaque);
    applyGlass(window, bd);
}

fn applyGlass(window: *Window, backdrop: Backdrop) void {
    window.composition.backdrop = backdrop;
    const dwm = win32.dwmapi;
    switch (backdrop) {
        .mica => {
            // High contrast: nothing translucent. The M2 look of `frame.apply`.
            disableBlurBehind(window);
            const kind: i32 = if (theme.palette(window).mica) dwm.DWMSBT_MAINWINDOW else dwm.DWMSBT_NONE;
            _ = dwm.DwmSetWindowAttribute(window.hwnd, dwm.DWMWA_SYSTEMBACKDROP_TYPE, &kind, @sizeOf(i32));
        },
        .@"opaque" => {
            disableBlurBehind(window);
            const none: i32 = dwm.DWMSBT_NONE;
            _ = dwm.DwmSetWindowAttribute(window.hwnd, dwm.DWMWA_SYSTEMBACKDROP_TYPE, &none, @sizeOf(i32));
        },
        .transparent, .acrylic => {
            // `.acrylic` is the system Acrylic material over the transparent
            // client (spike c); `windowMessage` keeps it from going solid
            // when the window is deactivated.
            const kind: i32 = if (backdrop == .acrylic) dwm.DWMSBT_TRANSIENTWINDOW else dwm.DWMSBT_NONE;
            _ = dwm.DwmSetWindowAttribute(window.hwnd, dwm.DWMWA_SYSTEMBACKDROP_TYPE, &kind, @sizeOf(i32));
            // An empty region: per-pixel alpha without blurring (spike b).
            const rgn = win32.gdi32.CreateRectRgn(0, 0, -1, -1);
            defer if (rgn) |r| {
                _ = win32.gdi32.DeleteObject(@ptrCast(r));
            };
            const bb: dwm.DWM_BLURBEHIND = .{
                .dwFlags = dwm.DWM_BB_ENABLE | dwm.DWM_BB_BLURREGION,
                .fEnable = 1,
                .hRgnBlur = rgn,
            };
            const hr = dwm.DwmEnableBlurBehindWindow(window.hwnd, &bb);
            if (hr < 0) log.warn("DwmEnableBlurBehindWindow failed hr=0x{x}", .{@as(u32, @bitCast(hr))});
        },
    }
    repaintSurfaces(window);
    // The rows are painted at the window's alpha.
    Chrome.invalidate(window);
}

fn disableBlurBehind(window: *Window) void {
    const dwm = win32.dwmapi;
    const bb: dwm.DWM_BLURBEHIND = .{ .dwFlags = dwm.DWM_BB_ENABLE, .fEnable = 0 };
    _ = dwm.DwmEnableBlurBehindWindow(window.hwnd, &bb);
}

/// The surface child erases itself once (`surfaceErase`); a backdrop change
/// needs the erase again.
fn repaintSurfaces(window: *Window) void {
    for (window.tabs.items) |tab| {
        var it = tab.tree.iterator();
        while (it.next()) |entry| entry.view.repaintBackground();
    }
}

/// `toggle_background_opacity`: a window-level switch between the
/// translucent look and a solid one. No swap chain changes (R-M3-2).
pub fn toggleOpacity(app: *App, target: apprt.Target) bool {
    const window = app.windowForTarget(target) orelse return false;
    if (!window.composition.glass or !window.composition.look.translucent()) {
        log.debug("toggle_background_opacity: the window is not translucent", .{});
        return false;
    }
    window.composition.toggled_opaque = !window.composition.toggled_opaque;
    applyToWindow(window);
    return true;
}

/// Fills `rc` of a translucent-capable window with a brush, with alpha: GDI
/// alone writes alpha 0, which DWM adds to the backdrop instead of covering it
/// (a toggled-solid window showed the colour plus the backdrop). Buffered
/// paint (as the chrome painter does) sets the alpha: 0 when `see_through`
/// (black is then glass), 255 otherwise.
pub fn fillWithAlpha(hdc: win32.user32.HDC, rc: *const win32.foundation.RECT, brush: win32.user32.HBRUSH, see_through: bool) void {
    fillAlpha(hdc, rc, brush, if (see_through) 0 else 255);
}

/// `fillWithAlpha` with any alpha; the brush colour must be premultiplied.
pub fn fillAlpha(hdc: win32.user32.HDC, rc: *const win32.foundation.RECT, brush: win32.user32.HBRUSH, alpha: u8) void {
    const uxtheme = win32.uxtheme;
    const params: uxtheme.BP_PAINTPARAMS = .{ .dwFlags = uxtheme.BPPF_ERASE };
    var mem: ?win32.user32.HDC = null;
    const hbp = uxtheme.BeginBufferedPaint(hdc, rc, uxtheme.BPBF_TOPDOWNDIB, &params, &mem);
    _ = win32.gdi32.FillRect(mem orelse hdc, rc, brush);
    const b = hbp orelse return;
    if (alpha != 0) _ = uxtheme.BufferedPaintSetAlpha(b, rc, alpha);
    _ = uxtheme.EndBufferedPaint(b, 1);
}

/// What a surface child erases itself with: a premultiplied colour and its
/// alpha (255 is opaque; only a glass window uses the alpha).
pub const Erase = struct { r: u8, g: u8, b: u8, alpha: u8 };

/// The erase of a surface child. In a translucent window the swap chain
/// draws the background at the window's `alpha` over a child of alpha 0, but
/// until the visual shows a chain (`SurfaceState.showing`) the child stands
/// in for that frame: transparent there, the new pane would show the bare
/// glass (Acrylic, or the desktop behind) until the chain is attached.
pub fn surfaceErase(bg: configpkg.Config.Color, translucent: bool, showing: bool, alpha: u8) Erase {
    if (!translucent) return .{ .r = bg.r, .g = bg.g, .b = bg.b, .alpha = 255 };
    if (showing) return .{ .r = 0, .g = 0, .b = 0, .alpha = 0 };
    return .{
        .r = premultiply(bg.r, alpha),
        .g = premultiply(bg.g, alpha),
        .b = premultiply(bg.b, alpha),
        .alpha = alpha,
    };
}

fn premultiply(c: u8, alpha: u8) u8 {
    return @intCast((@as(u32, c) * alpha + 127) / 255);
}

/// `windowAlpha` as the 0..255 alpha of the chrome rows.
pub fn alphaByte(window: *const Window) u8 {
    return alphaToByte(windowAlpha(window));
}

fn alphaToByte(alpha: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(alpha, 0.0, 1.0) * 255.0));
}

/// Whether the surface child must erase to alpha 0 (the glass shows
/// through) instead of the terminal background.
pub fn eraseTransparent(window: *const Window) bool {
    return isTranslucent(window);
}

/// Whether a `WM_NCACTIVATE` is swallowed: only the deactivation of an
/// Acrylic window, and not with the native caption (`window-decoration =
/// server`), which has to show the window inactive. Known side effects: the
/// owner of a MessageBox and a second Acrylic window look active too.
fn swallowDeactivation(backdrop: Backdrop, decorations: frame.Decorations, wparam: win32.foundation.WPARAM) bool {
    return wparam == 0 and backdrop == .acrylic and decorations != .server;
}

/// `WM_NCACTIVATE` and `WM_SHOWWINDOW` of a window. DWM turns the Acrylic backdrop into a solid
/// colour when it sees the window deactivated (the owner wants the blur to
/// stay): measured on Windows 11 10.0.26300, the Acrylic of a window whose
/// deactivation is swallowed here stays blurred while another window has the
/// focus. `WM_ACTIVATE` and the real activation are untouched.
pub fn windowMessage(window: *Window, msg: u32, wparam: win32.foundation.WPARAM) ?win32.foundation.LRESULT {
    switch (msg) {
        win32.user32.WM_NCACTIVATE => {
            if (!swallowDeactivation(window.composition.backdrop, window.frame.decorations, wparam)) return null;
            return 1;
        },
        // The glass set while the window was being created is not always in
        // effect once it shows (seen on the first start after a build).
        win32.user32.WM_SHOWWINDOW => {
            if (wparam != 0 and window.composition.glass) applyToWindow(window);
            return null;
        },
        else => return null,
    }
}

/// `recovery.composition_hook`: the renderer of a surface moved to a new
/// device and dropped its swap chain. The old chain must leave the visual and
/// any chain still waiting is stale; the renderer hands the new one over.
pub fn recoveryHook(surface: *Surface) void {
    dropChains(surface.app.composition.device, &surface.composition);
    // The empty visual shows the glass: the stand-in covers it again.
    surface.repaintBackground();
}

fn dropChains(device: ?*dcomp.IDCompositionDevice, state: *SurfaceState) void {
    com.release(state.pending.swap(null, .acq_rel));
    if (state.visual) |v| {
        v.setContent(null) catch {};
        if (device) |d| d.commit() catch {};
    }
    state.showing = false;
}

/// Used by `Surface.create` when core init fails.
pub fn surfaceAborted(surface: *Surface) void {
    surfaceDestroying(surface);
    surfaceReleased(surface);
}

pub fn appStarted() void {
    recovery.composition_hook = recoveryHook;
}

pub fn appStopping(app: *App) void {
    _ = app;
    recovery.composition_hook = null;
}

/// After the windows are destroyed: their trees were released against the
/// device, which can go now.
pub fn appStopped(app: *App) void {
    com.release(app.composition.device);
    app.composition.device = null;
}

pub fn testState(app: *App, jw: *std.json.Stringify) !void {
    try jw.beginObject();
    var any = false;
    for (app.windows.items) |window| {
        for (window.tabs.items) |tab| {
            var it = tab.tree.iterator();
            while (it.next()) |entry| {
                if (entry.view.composition.mode.load(.acquire) == 1) any = true;
            }
        }
    }
    try jw.objectField("mode");
    try jw.write(if (any) "composition" else "hwnd");
    try jw.objectField("windows");
    try jw.beginArray();
    for (app.windows.items) |window| {
        try jw.beginObject();
        try jw.objectField("id");
        try jw.write(window.id);
        try jw.objectField("glass");
        try jw.write(window.composition.glass);
        try jw.objectField("backdrop");
        try jw.write(@tagName(window.composition.backdrop));
        try jw.objectField("toggled_opaque");
        try jw.write(window.composition.toggled_opaque);
        try jw.objectField("alpha");
        try jw.write(windowAlpha(window));
        try jw.objectField("surfaces");
        try jw.beginArray();
        for (window.tabs.items) |tab| {
            var it = tab.tree.iterator();
            while (it.next()) |entry| {
                const s = entry.view;
                try jw.beginObject();
                try jw.objectField("id");
                try jw.write(s.id);
                try jw.objectField("mode");
                try jw.write(if (s.composition.mode.load(.acquire) == 1) "composition" else "hwnd");
                try jw.objectField("target");
                try jw.write(s.composition.target != null);
                try jw.objectField("attached");
                try jw.write(s.composition.attached);
                try jw.endObject();
            }
        }
        try jw.endArray();
        try jw.endObject();
    }
    try jw.endArray();
    try jw.endObject();
}

// ----------------------------------------------------------------------
// Tests

fn testConfig(opacity: f64, blur: configpkg.Config.BackgroundBlur) configpkg.Config {
    var cfg: configpkg.Config = undefined;
    cfg.@"background-opacity" = opacity;
    cfg.@"background-blur" = blur;
    return cfg;
}

test "win32 composition: wantComposition" {
    const opaque_cfg = testConfig(1.0, .false);
    try std.testing.expect(!wantComposition(&opaque_cfg, false));
    const translucent = testConfig(0.9, .false);
    try std.testing.expect(wantComposition(&translucent, false));
    try std.testing.expect(!wantComposition(&translucent, true));
    const blurred = testConfig(1.0, .true);
    try std.testing.expect(!wantComposition(&blurred, false));
    const radius = testConfig(1.0, .{ .radius = 20 });
    try std.testing.expect(!wantComposition(&radius, false));
    // Out-of-range values clamp like the renderer's.
    try std.testing.expect(!wantComposition(&testConfig(2.5, .false), false));
    try std.testing.expect(wantComposition(&testConfig(-1, .false), false));
}

test "win32 composition: backdrop table" {
    const blurred = testConfig(0.8, .true);
    try std.testing.expectEqual(Backdrop.acrylic, backdropFor(&blurred, false, false));
    const translucent = testConfig(0.8, .false);
    try std.testing.expectEqual(Backdrop.transparent, backdropFor(&translucent, false, false));
    try std.testing.expectEqual(Backdrop.@"opaque", backdropFor(&translucent, true, false));
    try std.testing.expectEqual(Backdrop.@"opaque", backdropFor(&blurred, true, false));
    // High contrast: nothing translucent, the M2 frame decides.
    try std.testing.expectEqual(Backdrop.mica, backdropFor(&blurred, false, true));
    try std.testing.expectEqual(Backdrop.mica, backdropFor(&translucent, true, true));
    // Opaque config: the toggle changes nothing.
    const solid = testConfig(1.0, .false);
    try std.testing.expectEqual(Backdrop.mica, backdropFor(&solid, false, false));
    try std.testing.expectEqual(Backdrop.mica, backdropFor(&solid, true, false));
}

// Fakes: COM objects whose vtables count what the code under test does.

const Counts = struct {
    released: u32 = 0,
    set_content: u32 = 0,
    set_content_null: u32 = 0,
    commits: u32 = 0,
    targets: u32 = 0,
    visuals: u32 = 0,
    events: [32]u8 = undefined,
    n_events: usize = 0,

    fn event(self: *Counts, e: u8) void {
        if (self.n_events < self.events.len) {
            self.events[self.n_events] = e;
            self.n_events += 1;
        }
    }
    fn log(self: *const Counts) []const u8 {
        return self.events[0..self.n_events];
    }
};
var counts: Counts = .{};

const Fake = struct {
    vtable: *const anyopaque,
    refs: u32 = 1,
};

fn fakeQi(_: *com.IUnknown, _: *const win32.foundation.GUID, _: *?*anyopaque) callconv(.winapi) win32.foundation.HRESULT {
    return -1;
}
fn fakeAddRef(p: *com.IUnknown) callconv(.winapi) u32 {
    const f: *Fake = @ptrCast(p);
    f.refs += 1;
    return f.refs;
}
fn fakeRelease(p: *com.IUnknown) callconv(.winapi) u32 {
    const f: *Fake = @ptrCast(p);
    f.refs -= 1;
    counts.released += 1;
    return f.refs;
}
const fake_base: com.IUnknown.VTable = .{ .QueryInterface = fakeQi, .AddRef = fakeAddRef, .Release = fakeRelease };

fn fakeCommit(_: *dcomp.IDCompositionDevice) callconv(.winapi) win32.foundation.HRESULT {
    counts.commits += 1;
    counts.event('c');
    return 0;
}
var fake_target: Fake = undefined;
var fake_visual: Fake = undefined;
fn fakeCreateTarget(_: *dcomp.IDCompositionDevice, _: win32.foundation.HWND, _: win32.foundation.BOOL, out: *?*dcomp.IDCompositionTarget) callconv(.winapi) win32.foundation.HRESULT {
    counts.targets += 1;
    counts.event('T');
    fake_target = .{ .vtable = &fake_target_vtable };
    out.* = @ptrCast(&fake_target);
    return 0;
}
fn fakeCreateVisual(_: *dcomp.IDCompositionDevice, out: *?*dcomp.IDCompositionVisual) callconv(.winapi) win32.foundation.HRESULT {
    counts.visuals += 1;
    counts.event('V');
    fake_visual = .{ .vtable = &fake_visual_vtable };
    out.* = @ptrCast(&fake_visual);
    return 0;
}
fn fakeSetRoot(_: *dcomp.IDCompositionTarget, _: ?*dcomp.IDCompositionVisual) callconv(.winapi) win32.foundation.HRESULT {
    return 0;
}
fn fakeSetContent(_: *dcomp.IDCompositionVisual, content: ?*com.IUnknown) callconv(.winapi) win32.foundation.HRESULT {
    if (content == null) {
        counts.set_content_null += 1;
        counts.event('n');
    } else {
        counts.set_content += 1;
        counts.event('s');
    }
    return 0;
}

var fake_device_vtable: dcomp.IDCompositionDevice.VTable = undefined;
var fake_target_vtable: dcomp.IDCompositionTarget.VTable = undefined;
var fake_visual_vtable: dcomp.IDCompositionVisual.VTable = undefined;
var fake_device: Fake = undefined;

fn fakeDevice() *dcomp.IDCompositionDevice {
    counts = .{};
    fake_device_vtable = std.mem.zeroes(dcomp.IDCompositionDevice.VTable);
    fake_device_vtable.base = fake_base;
    fake_device_vtable.Commit = fakeCommit;
    fake_device_vtable.CreateTargetForHwnd = fakeCreateTarget;
    fake_device_vtable.CreateVisual = fakeCreateVisual;
    fake_target_vtable = std.mem.zeroes(dcomp.IDCompositionTarget.VTable);
    fake_target_vtable.base = fake_base;
    fake_target_vtable.SetRoot = fakeSetRoot;
    fake_visual_vtable = std.mem.zeroes(dcomp.IDCompositionVisual.VTable);
    fake_visual_vtable.base = fake_base;
    fake_visual_vtable.SetContent = fakeSetContent;
    fake_device = .{ .vtable = &fake_device_vtable };
    return @ptrCast(&fake_device);
}

var fake_chain_vtable: dxgi.IDXGISwapChain1.VTable = undefined;
fn fakeChain() struct { chain: *dxgi.IDXGISwapChain1, obj: *Fake } {
    const alloc = std.testing.allocator;
    fake_chain_vtable = std.mem.zeroes(dxgi.IDXGISwapChain1.VTable);
    @as(*com.IUnknown.VTable, @ptrCast(&fake_chain_vtable)).* = fake_base;
    const obj = alloc.create(Fake) catch @panic("oom");
    obj.* = .{ .vtable = &fake_chain_vtable, .refs = 1 };
    return .{ .chain = @ptrCast(obj), .obj = obj };
}

test "win32 composition: stale hand-off is released" {
    const device = fakeDevice();
    var app_state: AppState = .{ .device = device };
    var state: SurfaceState = .{};
    try createTree(device, &state, undefined);
    const fc = fakeChain();
    defer std.testing.allocator.destroy(fc.obj);

    // The chain belongs to generation 3, the present target is at 4.
    try std.testing.expect(!attach(&app_state, &state, fc.chain, 3, 4));
    try std.testing.expectEqual(@as(u32, 0), counts.set_content);
    try std.testing.expectEqual(@as(u32, 0), fc.obj.refs);
    try std.testing.expect(!state.showing);

    // A current one is shown, and still released by the caller's reference.
    const fresh = fakeChain();
    defer std.testing.allocator.destroy(fresh.obj);
    try std.testing.expect(attach(&app_state, &state, fresh.chain, 4, 4));
    try std.testing.expectEqual(@as(u32, 1), counts.set_content);
    try std.testing.expectEqual(@as(u32, 0), fresh.obj.refs);
    try std.testing.expectEqual(@as(u32, 1), state.attached);
    try std.testing.expect(state.showing);
    destroyTree(device, &state);
    try std.testing.expect(!state.showing);
}

test "win32 composition: a pane stands in for its first frame until a chain shows" {
    const t = std.testing;
    const bg: configpkg.Config.Color = .{ .r = 0x1a, .g = 0x2b, .b = 0x4c };
    // Opaque (hwnd mode, or a glass window shown solid): the background.
    try t.expectEqual(Erase{ .r = 0x1a, .g = 0x2b, .b = 0x4c, .alpha = 255 }, surfaceErase(bg, false, false, 255));
    try t.expectEqual(Erase{ .r = 0x1a, .g = 0x2b, .b = 0x4c, .alpha = 255 }, surfaceErase(bg, false, true, 255));
    // Translucent, no chain shown yet: the background at the window's alpha,
    // premultiplied, never the bare glass.
    const stand_in = surfaceErase(bg, true, false, 204);
    try t.expectEqual(Erase{ .r = 21, .g = 34, .b = 61, .alpha = 204 }, stand_in);
    try t.expect(stand_in.alpha != 0);
    // Translucent with the chain shown: alpha 0 under it, so the frame is
    // not composed twice.
    try t.expectEqual(Erase{ .r = 0, .g = 0, .b = 0, .alpha = 0 }, surfaceErase(bg, true, true, 204));
    // Premultiplication rounds and keeps the ends.
    try t.expectEqual(@as(u8, 255), premultiply(255, 255));
    try t.expectEqual(@as(u8, 0), premultiply(255, 0));
    try t.expectEqual(@as(u8, 128), premultiply(255, 128));
}

test "win32 composition: dropping the chains brings the stand-in back" {
    const device = fakeDevice();
    var app_state: AppState = .{ .device = device };
    var state: SurfaceState = .{};
    try createTree(device, &state, undefined);
    const fc = fakeChain();
    defer std.testing.allocator.destroy(fc.obj);
    try std.testing.expect(attach(&app_state, &state, fc.chain, 0, 0));
    try std.testing.expect(state.showing);
    dropChains(device, &state);
    try std.testing.expect(!state.showing);
    destroyTree(device, &state);
}

test "win32 composition: hand-off after surfaceDestroying is released" {
    const device = fakeDevice();
    var app_state: AppState = .{ .device = device };
    var state: SurfaceState = .{};
    try createTree(device, &state, undefined);
    destroyTree(device, &state);
    try std.testing.expect(state.visual == null and state.target == null);

    // The render thread hands a chain over after the hook ran.
    const fc = fakeChain();
    defer std.testing.allocator.destroy(fc.obj);
    park(&state, fc.chain, 0);
    const taken = state.pending.swap(null, .acq_rel).?;
    _ = attach(&app_state, &state, taken, 0, 0);
    try std.testing.expectEqual(@as(u32, 0), counts.set_content);
    try std.testing.expectEqual(@as(u32, 0), fc.obj.refs);

    // One parked at destroy time is released with the surface.
    const late = fakeChain();
    defer std.testing.allocator.destroy(late.obj);
    park(&state, late.chain, 0);
    com.release(state.pending.swap(null, .acq_rel));
    try std.testing.expectEqual(@as(u32, 0), late.obj.refs);
}

test "win32 composition: parking a second chain releases the first" {
    var state: SurfaceState = .{};
    const a = fakeChain();
    defer std.testing.allocator.destroy(a.obj);
    const b = fakeChain();
    defer std.testing.allocator.destroy(b.obj);
    park(&state, a.chain, 1);
    park(&state, b.chain, 2);
    try std.testing.expectEqual(@as(u32, 0), a.obj.refs);
    try std.testing.expectEqual(@as(u32, 1), b.obj.refs);
    try std.testing.expectEqual(@as(u32, 2), state.pending_generation.load(.acquire));
    com.release(state.pending.swap(null, .acq_rel));
}

test "win32 composition: mode switch creates and destroys targets" {
    const device = fakeDevice();
    var state: SurfaceState = .{};

    // hwnd -> composition: target and visual exist before the mode store.
    try createTree(device, &state, undefined);
    state.mode.store(1, .release);
    try std.testing.expect(state.target != null and state.visual != null);
    try std.testing.expectEqual(@as(u32, 1), counts.targets);
    try std.testing.expectEqual(@as(u32, 1), counts.visuals);
    try std.testing.expectEqualStrings("TVc", counts.log());

    // A second creation releases the first target before asking for a new one.
    try createTree(device, &state, undefined);
    try std.testing.expectEqual(@as(u32, 2), counts.targets);
    try std.testing.expectEqual(@as(u32, 1), counts.set_content_null);
    try std.testing.expect(std.mem.indexOf(u8, counts.log(), "ncTV") != null);

    // composition -> hwnd: SetContent(null) + Commit, then both are gone.
    destroyTree(device, &state);
    state.mode.store(0, .release);
    try std.testing.expect(state.target == null and state.visual == null);
    try std.testing.expectEqual(@as(u32, 4), counts.released);
}

test "win32 composition: a translucent-capable window goes solid, not hwnd" {
    // The look of a window born translucent whose config became opaque.
    try std.testing.expectEqual(Backdrop.@"opaque", backdropOf(.{ .opacity = 1.0, .blur = true }, false));
    try std.testing.expectEqual(Backdrop.transparent, backdropOf(.{ .opacity = 0.5, .blur = false }, false));
    try std.testing.expectEqual(Backdrop.acrylic, backdropOf(.{ .opacity = 0.9, .blur = true }, false));
    try std.testing.expectEqual(Backdrop.@"opaque", backdropOf(.{ .opacity = 0.5, .blur = true }, true));

    const cfg = testConfig(2.5, .{ .radius = 12 });
    const look = Look.of(&cfg);
    try std.testing.expectEqual(@as(f64, 1.0), look.opacity);
    try std.testing.expect(look.blur);
}

test "win32 composition: recovery drops the old and the waiting chain" {
    const device = fakeDevice();
    var app_state: AppState = .{ .device = device };
    var state: SurfaceState = .{};
    try createTree(device, &state, undefined);
    const shown = fakeChain();
    defer std.testing.allocator.destroy(shown.obj);
    _ = attach(&app_state, &state, shown.chain, 0, 0);
    try std.testing.expectEqual(@as(u32, 1), counts.set_content);
    const waiting = fakeChain();
    defer std.testing.allocator.destroy(waiting.obj);
    park(&state, waiting.chain, 0);
    const commits = counts.commits;
    dropChains(device, &state);
    try std.testing.expect(state.pending.load(.acquire) == null);
    try std.testing.expectEqual(@as(u32, 0), waiting.obj.refs);
    try std.testing.expectEqual(@as(u32, 1), counts.set_content_null);
    try std.testing.expectEqual(commits + 1, counts.commits);
    // The tree itself stays for the chain the renderer hands over next.
    try std.testing.expect(state.visual != null);
    destroyTree(device, &state);
}

test "win32 composition: a closing surface keeps its mode and releases late chains" {
    const device = fakeDevice();
    var app_state: AppState = .{ .device = device };
    var state: SurfaceState = .{};
    try createTree(device, &state, undefined);
    state.mode.store(1, .release);
    destroyTree(device, &state);
    // surfaceDestroying only does this: the render thread must not see mode 0.
    try std.testing.expectEqual(@as(u8, 1), state.mode.load(.acquire));
    const late = fakeChain();
    defer std.testing.allocator.destroy(late.obj);
    _ = attach(&app_state, &state, late.chain, 0, 0);
    try std.testing.expectEqual(@as(u32, 0), counts.set_content);
    try std.testing.expectEqual(@as(u32, 0), late.obj.refs);
}

test "win32 composition: WM_NCACTIVATE is swallowed only for Acrylic without a native caption" {
    try std.testing.expect(swallowDeactivation(.acrylic, .client, 0));
    try std.testing.expect(swallowDeactivation(.acrylic, .none, 0));
    try std.testing.expect(!swallowDeactivation(.acrylic, .server, 0));
    try std.testing.expect(!swallowDeactivation(.acrylic, .client, 1));
    try std.testing.expect(!swallowDeactivation(.transparent, .client, 0));
    try std.testing.expect(!swallowDeactivation(.@"opaque", .client, 0));
    try std.testing.expect(!swallowDeactivation(.mica, .client, 0));
}

test "win32 composition: background-blur defaults on for Windows" {
    const info = @typeInfo(configpkg.Config).@"struct";
    inline for (info.field_names, info.field_types, info.field_attrs) |name, T, attrs| {
        if (comptime std.mem.eql(u8, name, "background-blur")) {
            const def = comptime attrs.defaultValue(T).?;
            const want: configpkg.Config.BackgroundBlur = if (@import("builtin").os.tag == .windows) .true else .false;
            try std.testing.expectEqual(std.meta.activeTag(want), std.meta.activeTag(def));
        }
    }
    // With that default a translucent config is frosted, an opaque one needs nothing.
    const frosted = testConfig(0.9, .true);
    try std.testing.expectEqual(Backdrop.acrylic, backdropFor(&frosted, false, false));
    try std.testing.expect(!wantComposition(&testConfig(1.0, .true), false));
}

test "win32 composition: chrome alpha byte" {
    try std.testing.expectEqual(@as(u8, 255), alphaToByte(1.0));
    try std.testing.expectEqual(@as(u8, 0), alphaToByte(0.0));
    try std.testing.expectEqual(@as(u8, 153), alphaToByte(0.6));
    try std.testing.expectEqual(@as(u8, 230), alphaToByte(0.9));
    try std.testing.expectEqual(@as(u8, 255), alphaToByte(7.0));
}

test "win32 composition: a tab moved between glass and opaque windows follows the new window" {
    const t = std.testing;
    // Opaque config (no translucency wanted): only a glass window composes.
    // Glass -> opaque: the surfaces leave composition mode.
    try t.expectEqual(SyncAction.leave, syncAction(true, wantFor(false, false)));
    // Opaque -> glass: they enter it.
    try t.expectEqual(SyncAction.enter, syncAction(false, wantFor(true, false)));
    // Same kind of window: nothing changes.
    try t.expectEqual(SyncAction.none, syncAction(true, wantFor(true, false)));
    try t.expectEqual(SyncAction.none, syncAction(false, wantFor(false, false)));
    // An opaque window under a translucent config keeps composing its surfaces.
    try t.expectEqual(SyncAction.none, syncAction(true, wantFor(false, true)));
    try t.expectEqual(SyncAction.enter, syncAction(false, wantFor(false, true)));
}
