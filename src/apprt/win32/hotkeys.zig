//! Global hotkeys (`global:` keybinds) registered on the message window.
//! `RegisterHotKey` and the action dispatch sit behind a small seam so the
//! bookkeeping is tested without touching the owner's real hotkeys.
const std = @import("std");
const win32 = @import("win32");
const configpkg = @import("../../config.zig");
const input = @import("../../input.zig");
const App = @import("App.zig");

const Allocator = std.mem.Allocator;
const user32 = win32.user32;
const Binding = input.Binding;

const log = std.log.scoped(.win32_hotkeys);

/// A `RegisterHotKey` modifier mask plus virtual key.
pub const Chord = struct { mods: u32, vk: u16 };

/// A binding's leaf, exactly as stored in `config.keybind.set`. A chained
/// leaf points into config memory, so `configChanged` replaces every entry
/// before the old config is freed.
pub const Leaf = Binding.Set.Value;

/// Registered hotkeys; owned by `App`.
pub const State = struct {
    ids: std.AutoHashMapUnmanaged(i32, Leaf) = .empty,
    /// The trigger each id was registered for, to find its leaf again in a
    /// new config.
    triggers: std.AutoHashMapUnmanaged(i32, Binding.Trigger) = .empty,
    next_id: i32 = 1,
    failed: u32 = 0,
    /// Hash of the global binds that were registered; equal for a config
    /// that changed nothing about them.
    signature: u64 = 0,
};

/// What registers a chord and runs a binding's actions.
const Backend = struct {
    ctx: ?*anyopaque,
    register: *const fn (ctx: ?*anyopaque, id: i32, chord: Chord) bool,
    unregister: *const fn (ctx: ?*anyopaque, id: i32) void,
    perform: *const fn (ctx: ?*anyopaque, actions: []const Binding.Action) void,
};

/// The chord for `trigger` on `hkl` (the calling thread's layout when
/// null); null when the trigger cannot be a system-wide hotkey.
pub fn chordFor(trigger: Binding.Trigger, hkl: ?*anyopaque) ?Chord {
    const layout: ?user32.HKL = if (hkl) |h| @ptrCast(h) else user32.GetKeyboardLayout(0);

    var mods: u32 = 0;
    if (trigger.mods.ctrl) mods |= user32.MOD_CONTROL;
    if (trigger.mods.alt) mods |= user32.MOD_ALT;
    if (trigger.mods.shift) mods |= user32.MOD_SHIFT;
    if (trigger.mods.super) mods |= user32.MOD_WIN;

    switch (trigger.key) {
        .catch_all => return null,
        .physical => |key| {
            const native = nativeFor(key) orelse return null;
            const vk = user32.MapVirtualKeyExW(native, user32.MAPVK_VSC_TO_VK_EX, layout);
            if (vk == 0) return null;
            return .{ .mods = mods, .vk = @intCast(vk) };
        },
        .unicode => |cp| {
            if (cp > 0xFFFF) return null;
            const r = user32.VkKeyScanExW(@intCast(cp), layout);
            if (r == -1) return null;
            const bits: u16 = @bitCast(r);
            const states: u8 = @intCast(bits >> 8);
            // Ctrl and Alt states (AltGr) and Hankaku have no hotkey form.
            if (states & ~@as(u8, 1) != 0) return null;
            if (states & 1 != 0) mods |= user32.MOD_SHIFT;
            return .{ .mods = mods, .vk = bits & 0xFF };
        },
    }
}

/// The Windows scancode of `key`, with the E0 prefix when it has one.
fn nativeFor(key: input.Key) ?u32 {
    for (input.keycodes.entries) |entry| {
        if (entry.key != key or entry.native == 0) continue;
        if (entry.native < 0x100 or entry.native & 0xFF00 == 0xE000) return entry.native;
    }
    return null;
}

fn leafHash(value: Leaf) u64 {
    var hasher = std.hash.Wyhash.init(0);
    switch (value) {
        .leader => {},
        .leaf => |l| {
            std.hash.autoHash(&hasher, l.action.hash());
            std.hash.autoHash(&hasher, l.flags);
        },
        .leaf_chained => |l| {
            for (l.actions.items) |act| std.hash.autoHash(&hasher, act.hash());
            std.hash.autoHash(&hasher, l.flags);
        },
    }
    return hasher.final();
}

/// Order-independent hash of the global binds of `set`.
fn signatureOf(set: *const Binding.Set) u64 {
    var sum: u64 = 0;
    var it = set.bindings.iterator();
    while (it.next()) |entry| {
        const global = switch (entry.value_ptr.*) {
            .leader => false,
            inline .leaf, .leaf_chained => |l| l.flags.global,
        };
        if (!global) continue;
        sum +%= entry.key_ptr.hash() *% 31 +% leafHash(entry.value_ptr.*);
    }
    return sum;
}

/// Registers every global leaf of `set`.
fn registerAll(state: *State, alloc: Allocator, set: *const Binding.Set, backend: Backend) void {
    state.signature = signatureOf(set);
    var it = set.bindings.iterator();
    while (it.next()) |entry| {
        const flags = switch (entry.value_ptr.*) {
            .leader => continue,
            inline .leaf, .leaf_chained => |l| l.flags,
        };
        if (!flags.global) continue;

        const chord = chordFor(entry.key_ptr.*, null) orelse {
            log.warn("global keybind has no hotkey form: {f}", .{entry.key_ptr.*});
            state.failed += 1;
            continue;
        };
        const id = state.next_id;
        if (!backend.register(backend.ctx, id, chord)) {
            log.warn("global hotkey is taken: {f} mods={x} vk={x} err={}", .{ entry.key_ptr.*, chord.mods, chord.vk, win32.kernel32.GetLastError() });
            state.failed += 1;
            continue;
        }
        state.ids.put(alloc, id, entry.value_ptr.*) catch {
            backend.unregister(backend.ctx, id);
            state.failed += 1;
            continue;
        };
        state.triggers.put(alloc, id, entry.key_ptr.*) catch {
            _ = state.ids.remove(id);
            backend.unregister(backend.ctx, id);
            state.failed += 1;
            continue;
        };
        state.next_id += 1;
    }
}

/// When the global binds of `set` are the ones already registered, point
/// the stored leaves at `set` (the old config is about to be freed) and
/// return true; nothing is registered again.
fn refresh(state: *State, set: *const Binding.Set) bool {
    if (state.failed != 0 or state.signature != signatureOf(set)) return false;
    var it = state.triggers.iterator();
    while (it.next()) |entry| {
        const value = set.bindings.get(entry.value_ptr.*) orelse return false;
        state.ids.getPtr(entry.key_ptr.*).?.* = value;
    }
    return true;
}

fn unregisterAll(state: *State, alloc: Allocator, backend: Backend) void {
    var it = state.ids.keyIterator();
    while (it.next()) |id| backend.unregister(backend.ctx, id.*);
    state.ids.clearAndFree(alloc);
    state.triggers.clearAndFree(alloc);
    state.failed = 0;
    state.signature = 0;
}

/// Runs the actions bound to hotkey `id`; false when the id is not ours.
fn fire(state: *const State, id: i32, backend: Backend) bool {
    const leaf = state.ids.getPtr(id) orelse return false;
    switch (leaf.*) {
        .leader => return false,
        .leaf => |*l| backend.perform(backend.ctx, (&l.action)[0..1]),
        .leaf_chained => |*l| backend.perform(backend.ctx, l.actions.items),
    }
    return true;
}

fn osRegister(ctx: ?*anyopaque, id: i32, chord: Chord) bool {
    const app: *App = @ptrCast(@alignCast(ctx.?));
    return user32.RegisterHotKey(app.msg_hwnd, id, chord.mods | user32.MOD_NOREPEAT, chord.vk) != 0;
}

fn osUnregister(ctx: ?*anyopaque, id: i32) void {
    const app: *App = @ptrCast(@alignCast(ctx.?));
    _ = user32.UnregisterHotKey(app.msg_hwnd, id);
}

fn osPerform(ctx: ?*anyopaque, actions: []const Binding.Action) void {
    const app: *App = @ptrCast(@alignCast(ctx.?));
    app.core_app.performAllChainedAction(app, actions);
}

fn backendOf(app: *App) Backend {
    return .{ .ctx = app, .register = osRegister, .unregister = osUnregister, .perform = osPerform };
}

/// Registers every global keybind of the config.
pub fn appStarted(app: *App) void {
    registerAll(&app.hotkeys, app.core_app.alloc, &app.config.keybind.set, backendOf(app));
}

pub fn appStopping(app: *App) void {
    unregisterAll(&app.hotkeys, app.core_app.alloc, backendOf(app));
}

/// Runs before the old config is freed, so no id maps to freed memory.
pub fn configChanged(app: *App, config: *const configpkg.Config) void {
    const alloc = app.core_app.alloc;
    if (refresh(&app.hotkeys, &config.keybind.set)) return;
    unregisterAll(&app.hotkeys, alloc, backendOf(app));
    registerAll(&app.hotkeys, alloc, &config.keybind.set, backendOf(app));
}

/// `WM_HOTKEY` on the message window; null when the message is not ours.
pub fn message(
    app: *App,
    msg: u32,
    wparam: win32.foundation.WPARAM,
    lparam: win32.foundation.LPARAM,
) ?win32.foundation.LRESULT {
    _ = lparam;
    if (msg != user32.WM_HOTKEY) return null;
    const id: i32 = std.math.cast(i32, wparam) orelse return null;
    if (!fire(&app.hotkeys, id, backendOf(app))) return null;
    return 0;
}

pub fn testState(app: *App, jw: *std.json.Stringify) !void {
    try jw.beginObject();
    try jw.objectField("registered");
    try jw.write(app.hotkeys.ids.count());
    try jw.objectField("failed");
    try jw.write(app.hotkeys.failed);
    try jw.endObject();
}

// -- Tests ------------------------------------------------------------------

const testing = std.testing;

test "win32 hotkeys: chord from physical key" {
    const c = chordFor(try Binding.Trigger.parse("ctrl+alt+shift+f9"), null).?;
    try testing.expectEqual(@as(u32, user32.MOD_CONTROL | user32.MOD_ALT | user32.MOD_SHIFT), c.mods);
    try testing.expectEqual(@as(u16, user32.VK_F9), c.vk);

    const w = chordFor(try Binding.Trigger.parse("super+f10"), null).?;
    try testing.expectEqual(@as(u32, user32.MOD_WIN), w.mods);
    try testing.expectEqual(@as(u16, user32.VK_F10), w.vk);

    try testing.expect(chordFor(try Binding.Trigger.parse("catch_all"), null) == null);
}

/// Layouts a test loaded, so that exactly those are unloaded afterwards.
const TestLayouts = struct {
    before: [64]user32.HKL = undefined,
    before_len: usize = 0,

    fn init() TestLayouts {
        var self: TestLayouts = .{};
        self.before_len = list(&self.before);
        return self;
    }

    fn list(out: []user32.HKL) usize {
        const n = user32.GetKeyboardLayoutList(@intCast(out.len), out.ptr);
        return if (n < 0) 0 else @intCast(n);
    }

    fn load(klid: [:0]const u16) ?user32.HKL {
        return user32.LoadKeyboardLayoutW(klid, user32.KLF_NOTELLSHELL);
    }

    fn deinit(self: *TestLayouts) void {
        var now: [64]user32.HKL = undefined;
        const n = list(&now);
        for (now[0..n]) |hkl| {
            const known = for (self.before[0..self.before_len]) |b| {
                if (b == hkl) break true;
            } else false;
            if (!known) _ = user32.UnloadKeyboardLayout(hkl);
        }
    }
};

test "win32 hotkeys: chord from unicode under US and DE layouts" {
    var layouts = TestLayouts.init();
    defer layouts.deinit();
    const us = TestLayouts.load(std.unicode.utf8ToUtf16LeStringLiteral("00000409")) orelse
        return error.SkipZigTest;

    const grave: Binding.Trigger = .{ .key = .{ .unicode = '`' }, .mods = .{ .ctrl = true } };
    const c = chordFor(grave, @ptrCast(us)).?;
    try testing.expectEqual(@as(u32, user32.MOD_CONTROL), c.mods);
    try testing.expectEqual(@as(u16, user32.VK_OEM_3), c.vk);

    // `~` needs shift on US.
    const tilde: Binding.Trigger = .{ .key = .{ .unicode = '~' }, .mods = .{ .ctrl = true } };
    const s = chordFor(tilde, @ptrCast(us)).?;
    try testing.expectEqual(@as(u32, user32.MOD_CONTROL | user32.MOD_SHIFT), s.mods);
    try testing.expectEqual(@as(u16, user32.VK_OEM_3), s.vk);

    if (TestLayouts.load(std.unicode.utf8ToUtf16LeStringLiteral("00000407"))) |de| {
        // `@` is reached with AltGr on German: no hotkey form.
        const at: Binding.Trigger = .{ .key = .{ .unicode = '@' } };
        try testing.expect(chordFor(at, @ptrCast(de)) == null);
        // Letters follow the key's label, not its position: `z` is VK_Z on both.
        const z: Binding.Trigger = .{ .key = .{ .unicode = 'z' } };
        try testing.expectEqual(@as(u16, 'Z'), chordFor(z, @ptrCast(us)).?.vk);
        try testing.expectEqual(@as(u16, 'Z'), chordFor(z, @ptrCast(de)).?.vk);
    }
}

const FakeBackend = struct {
    registered: std.ArrayList(i32) = .empty,
    performed: std.ArrayList(Binding.Action) = .empty,

    fn backend(self: *FakeBackend) Backend {
        return .{ .ctx = self, .register = register, .unregister = unregister, .perform = perform };
    }

    fn register(ctx: ?*anyopaque, id: i32, chord: Chord) bool {
        _ = chord;
        const self: *FakeBackend = @ptrCast(@alignCast(ctx.?));
        self.registered.append(testing.allocator, id) catch return false;
        return true;
    }

    fn unregister(ctx: ?*anyopaque, id: i32) void {
        const self: *FakeBackend = @ptrCast(@alignCast(ctx.?));
        for (self.registered.items, 0..) |r, i| if (r == id) {
            _ = self.registered.swapRemove(i);
            return;
        };
    }

    fn perform(ctx: ?*anyopaque, actions: []const Binding.Action) void {
        const self: *FakeBackend = @ptrCast(@alignCast(ctx.?));
        for (actions) |a| self.performed.append(testing.allocator, a) catch {};
    }

    fn deinit(self: *FakeBackend) void {
        self.registered.deinit(testing.allocator);
        self.performed.deinit(testing.allocator);
    }
};

/// The system calls on a message window of the test instead of the app's.
const WindowBackend = struct {
    hwnd: win32.foundation.HWND,

    fn backend(self: *WindowBackend) Backend {
        return .{ .ctx = self, .register = register, .unregister = unregister, .perform = FakeBackend.perform };
    }

    fn register(ctx: ?*anyopaque, id: i32, chord: Chord) bool {
        const self: *WindowBackend = @ptrCast(@alignCast(ctx.?));
        return user32.RegisterHotKey(self.hwnd, id, chord.mods | user32.MOD_NOREPEAT, chord.vk) != 0;
    }

    fn unregister(ctx: ?*anyopaque, id: i32) void {
        const self: *WindowBackend = @ptrCast(@alignCast(ctx.?));
        _ = user32.UnregisterHotKey(self.hwnd, id);
    }
};

test "win32 hotkeys: register and unregister on a message window" {
    const class_name = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyWin32TestHotkeys");
    const instance = win32.kernel32.GetModuleHandleW(null);
    const class: user32.WNDCLASSEXW = .{
        .lpfnWndProc = user32.DefWindowProcW,
        .hInstance = instance,
        .lpszClassName = class_name,
    };
    try testing.expect(user32.RegisterClassExW(&class) != 0);
    defer _ = user32.UnregisterClassW(class_name, instance);
    const hwnd = user32.CreateWindowExW(0, class_name, null, 0, 0, 0, 0, 0, user32.HWND_MESSAGE, null, instance, null) orelse
        return error.CreateWindowFailed;
    defer _ = user32.DestroyWindow(hwnd);

    var set: Binding.Set = .{};
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // F24 with Ctrl+Alt+Shift+Win: no real binding of the owner uses it.
    try set.parseAndPut(arena.allocator(), "global:ctrl+alt+shift+super+f24=new_window");

    var wb: WindowBackend = .{ .hwnd = hwnd };
    var state: State = .{};
    defer unregisterAll(&state, testing.allocator, wb.backend());
    registerAll(&state, testing.allocator, &set, wb.backend());
    try testing.expectEqual(@as(u32, 0), state.failed);
    try testing.expectEqual(@as(u32, 1), state.ids.count());

    // The chord is held, so a second registration of it is refused.
    const mods = user32.MOD_CONTROL | user32.MOD_ALT | user32.MOD_SHIFT | user32.MOD_WIN;
    try testing.expectEqual(@as(win32.foundation.BOOL, 0), user32.RegisterHotKey(hwnd, 999, mods, user32.VK_F24));

    unregisterAll(&state, testing.allocator, wb.backend());
    try testing.expectEqual(@as(u32, 0), state.ids.count());
    try testing.expect(user32.RegisterHotKey(hwnd, 999, mods, user32.VK_F24) != 0);
    _ = user32.UnregisterHotKey(hwnd, 999);
}

test "win32 hotkeys: chained global bind runs every action" {
    var set: Binding.Set = .{};
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try set.parseAndPut(arena.allocator(), "global:ctrl+alt+shift+f23=new_window");
    try set.parseAndPut(arena.allocator(), "chain=toggle_visibility");

    var fake: FakeBackend = .{};
    defer fake.deinit();
    var state: State = .{};
    defer unregisterAll(&state, testing.allocator, fake.backend());
    registerAll(&state, testing.allocator, &set, fake.backend());
    try testing.expectEqual(@as(usize, 1), fake.registered.items.len);

    try testing.expect(fire(&state, fake.registered.items[0], fake.backend()));
    try testing.expectEqual(@as(usize, 2), fake.performed.items.len);
    try testing.expect(!fire(&state, 12345, fake.backend()));
}

test "win32 hotkeys: unchanged global binds are not registered again" {
    var set_a: Binding.Set = .{};
    var set_b: Binding.Set = .{};
    var set_c: Binding.Set = .{};
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try set_a.parseAndPut(a, "global:ctrl+alt+shift+f23=new_window");
    try set_b.parseAndPut(a, "global:ctrl+alt+shift+f23=new_window");
    try set_c.parseAndPut(a, "global:ctrl+alt+shift+f23=toggle_visibility");

    var fake: FakeBackend = .{};
    defer fake.deinit();
    var state: State = .{};
    defer unregisterAll(&state, testing.allocator, fake.backend());
    registerAll(&state, testing.allocator, &set_a, fake.backend());
    try testing.expect(refresh(&state, &set_b));
    try testing.expect(!refresh(&state, &set_c));
    try testing.expectEqual(@as(usize, 1), fake.registered.items.len);
}
