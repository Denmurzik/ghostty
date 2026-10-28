//! Bell feedback: tab and window title decoration, taskbar flash, system
//! beep and audio, and the border the renderer draws around the surface.
const std = @import("std");
const Allocator = std.mem.Allocator;
const win32 = @import("win32");

const App = @import("App.zig");
const Chrome = @import("Chrome.zig");
const decor = @import("decor.zig");
const Surface = @import("Surface.zig");
const Tab = @import("Tab.zig");
const theme = @import("theme.zig");
const util = @import("util.zig");
const global = @import("../../global.zig");

const log = std.log.scoped(.win32_bell);

/// The bell emoji and a space, put before the caption while a bell rings.
const caption_prefix = "\u{1F514} ";

/// Ring the bell of `surface` as the config's `bell-features` ask. The
/// audio plays asynchronously, so this never blocks the UI thread.
pub fn ring(surface: *Surface) bool {
    const window = surface.window;
    const features = window.app.config.@"bell-features";
    const foreground = theme.windowActive(window);

    // A focused surface needs no reminder of what it just did.
    const focused = foreground and win32.user32.GetFocus() == surface.hwnd;

    if (features.title) {
        if (!focused and !surface.bell_ringing) {
            surface.bell_ringing = true;
            if (window.activeTab() == surface.tab) window.refreshTitle();
            Chrome.invalidate(window);
        }
    }

    if (features.border) decor.showBellBorder(surface);

    if (features.attention and !foreground) {
        var info: win32.user32.FLASHWINFO = .{
            .hwnd = window.hwnd,
            .dwFlags = win32.user32.FLASHW_TRAY | win32.user32.FLASHW_TIMERNOFG,
        };
        _ = win32.user32.FlashWindowEx(&info);
    }

    if (features.system) _ = win32.user32.MessageBeep(win32.user32.MB_OK);

    if (features.audio) playAudio(window.app);

    return true;
}

/// Playing sound buffer (`SND_MEMORY` needs it alive while the async play
/// runs). Replaced, and freed, by the next ring. UI thread only.
var playing: ?[]u8 = null;

/// WAV files only. `bell-audio-volume` scales the 8/16-bit PCM samples in
/// memory (other sample formats play at full volume); 0 is silent.
fn playAudio(app: *App) void {
    const path = app.config.@"bell-audio-path" orelse return;
    const volume = std.math.clamp(app.config.@"bell-audio-volume", 0.0, 1.0);
    if (volume <= 0) return;
    const alloc = app.core_app.alloc;
    const utf8 = switch (path) {
        inline else => |p| p,
    };

    if (volume < 1.0) {
        if (playScaled(alloc, utf8, volume)) return;
    }

    const wide = util.utf16z(alloc, utf8) catch |err| {
        log.warn("unable to convert bell audio path err={}", .{err});
        return;
    };
    defer alloc.free(wide);
    const flags = win32.winmm.SND_ASYNC | win32.winmm.SND_FILENAME | win32.winmm.SND_NODEFAULT;
    if (win32.winmm.PlaySoundW(wide, null, flags) == 0)
        log.warn("unable to play bell audio", .{});
}

/// Read the WAV, scale it and play it from memory. False when the file
/// cannot be read or scaled, so the caller plays the file unscaled.
fn playScaled(alloc: Allocator, path: []const u8, volume: f64) bool {
    const data = std.Io.Dir.cwd().readFileAlloc(global.io(), path, alloc, .limited(16 * 1024 * 1024)) catch |err| {
        log.warn("unable to read bell audio err={}", .{err});
        return false;
    };
    if (!scaleWav(data, volume)) {
        alloc.free(data);
        return false;
    }
    const flags = win32.winmm.SND_ASYNC | win32.winmm.SND_MEMORY | win32.winmm.SND_NODEFAULT;
    if (win32.winmm.PlaySoundW(@ptrCast(data.ptr), null, flags) == 0) {
        log.warn("unable to play bell audio", .{});
        alloc.free(data);
        return true;
    }
    // The new sound replaced the old one, which is no longer read.
    if (playing) |old| alloc.free(old);
    playing = data;
    return true;
}

/// Scale the samples of a PCM WAV in place. False when the layout is not
/// RIFF/WAVE PCM with 8 or 16 bits per sample.
pub fn scaleWav(data: []u8, volume: f64) bool {
    if (data.len < 12 or !std.mem.eql(u8, data[0..4], "RIFF") or !std.mem.eql(u8, data[8..12], "WAVE")) return false;
    var bits: u16 = 0;
    var pos: usize = 12;
    while (pos + 8 <= data.len) {
        const id = data[pos..][0..4];
        const size: usize = std.mem.readInt(u32, data[pos + 4 ..][0..4], .little);
        const body = pos + 8;
        if (std.mem.eql(u8, id, "fmt ")) {
            if (size < 16 or body + 16 > data.len) return false;
            const tag = std.mem.readInt(u16, data[body..][0..2], .little);
            if (tag != 1) return false;
            bits = std.mem.readInt(u16, data[body + 14 ..][0..2], .little);
        } else if (std.mem.eql(u8, id, "data")) {
            const end = @min(body + size, data.len);
            const samples = data[body..end];
            switch (bits) {
                16 => {
                    var i: usize = 0;
                    while (i + 2 <= samples.len) : (i += 2) {
                        const s = std.mem.readInt(i16, samples[i..][0..2], .little);
                        const v: f64 = @as(f64, @floatFromInt(s)) * volume;
                        std.mem.writeInt(i16, samples[i..][0..2], @intFromFloat(@round(v)), .little);
                    }
                },
                8 => for (samples) |*b| {
                    const v: f64 = (@as(f64, @floatFromInt(b.*)) - 128.0) * volume + 128.0;
                    b.* = @intFromFloat(@round(v));
                },
                else => return false,
            }
            return true;
        }
        pos = body + size + (size & 1);
    }
    return false;
}

/// `title` with the bell prefix when `ringing`.
pub fn bellTitle(alloc: Allocator, title: []const u8, ringing: bool) Allocator.Error![]u8 {
    if (!ringing) return alloc.dupe(u8, title);
    return std.mem.concat(alloc, u8, &.{ caption_prefix, title });
}

/// The caption for `tab`: its bell prefix when one of its surfaces rings
/// and `bell-features = title` is on.
pub fn decorateTitle(alloc: Allocator, title: []const u8, tab: *const Tab) ![:0]u8 {
    const ringing = tab.window.app.config.@"bell-features".title and tab.bellRinging();
    const decorated = try bellTitle(alloc, title, ringing);
    defer alloc.free(decorated);
    return alloc.dupeSentinel(u8, decorated, 0);
}

test "win32 bell: caption prefix" {
    const alloc = std.testing.allocator;

    const plain = try bellTitle(alloc, "shell", false);
    defer alloc.free(plain);
    try std.testing.expectEqualStrings("shell", plain);

    const ringing = try bellTitle(alloc, "shell", true);
    defer alloc.free(ringing);
    try std.testing.expectEqualStrings("\u{1F514} shell", ringing);
}

test "win32 bell: scaleWav halves 16-bit and 8-bit PCM" {
    var wav = [_]u8{
        'R',  'I',  'F', 'F', 0,    0,    0, 0, 'W',  'A',  'V',  'E',
        'f',  'm',  't', ' ', 16,   0,    0, 0, 1,    0,    1,    0,
        0x40, 0x1f, 0,   0,   0x80, 0x3e, 0, 0, 2,    0,    16,   0,
        'd',  'a',  't', 'a', 4,    0,    0, 0, 0x00, 0x10, 0x00, 0xf0,
    };
    try std.testing.expect(scaleWav(&wav, 0.5));
    try std.testing.expectEqual(@as(i16, 0x0800), std.mem.readInt(i16, wav[44..46], .little));
    try std.testing.expectEqual(@as(i16, -0x0800), std.mem.readInt(i16, wav[46..48], .little));

    var wav8 = wav;
    wav8[34] = 8;
    wav8[44] = 200;
    wav8[45] = 128;
    try std.testing.expect(scaleWav(&wav8, 0.5));
    try std.testing.expectEqual(@as(u8, 164), wav8[44]);
    try std.testing.expectEqual(@as(u8, 128), wav8[45]);

    var junk = [_]u8{ 1, 2, 3 };
    try std.testing.expect(!scaleWav(&junk, 0.5));
    var float_wav = wav;
    float_wav[20] = 3;
    try std.testing.expect(!scaleWav(&float_wav, 0.5));
}
