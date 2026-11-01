//! The in-process selection clipboard: what `copy-on-select = primary|both`
//! copies and what `middle-click-action = primary-paste` pastes. As on macOS
//! (its private selection pasteboard) nothing leaves the process: the store
//! belongs to the `App`, is shared by every window and never touches the
//! Windows clipboard. UI thread only.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Store = @This();

/// One representation, as the terminal core hands it over.
pub const Content = struct {
    mime: []const u8,
    data: []const u8,
};

/// The most representations kept (a listing holds at most this many names).
pub const max_contents = 16;

/// Owns every byte of `contents`; null while the store is empty.
arena: ?std.heap.ArenaAllocator = null,

contents: []const Content = &.{},

/// Replace the store with a deep copy of `new`. Representations the store
/// has no use for (no data, no name, past `max_contents`) are dropped. On
/// failure the previous contents stay.
pub fn set(self: *Store, alloc: Allocator, new: []const Content) Allocator.Error!void {
    var arena = std.heap.ArenaAllocator.init(alloc);
    errdefer arena.deinit();
    const a = arena.allocator();

    const kept = @min(new.len, max_contents);
    const out = try a.alloc(Content, kept);
    for (new[0..kept], out) |src, *dst| {
        dst.* = .{
            .mime = try a.dupe(u8, src.mime),
            .data = try a.dupe(u8, src.data),
        };
    }

    self.clear();
    self.arena = arena;
    self.contents = out;
}

/// Whether anything is stored.
pub fn isEmpty(self: *const Store) bool {
    return self.contents.len == 0;
}

/// The data stored as `mime`, or null. Every text alias (`text/plain`,
/// `UTF8_STRING`, ...) names the first text representation. Valid until the
/// next `set`, `clear` or `deinit`.
pub fn get(self: *const Store, mime: []const u8) ?[]const u8 {
    const want_text = isTextMime(mime);
    for (self.contents) |c| {
        if (want_text) {
            if (isTextMime(c.mime)) return c.data;
        } else if (std.mem.eql(u8, c.mime, mime)) return c.data;
    }
    return null;
}

/// The stored MIME types in stored order, written to `buf` (at most
/// `buf.len`). The names are borrowed from the store.
pub fn mimes(self: *const Store, buf: [][]const u8) []const []const u8 {
    const n = @min(self.contents.len, buf.len);
    for (self.contents[0..n], buf[0..n]) |c, *slot| slot.* = c.mime;
    return buf[0..n];
}

/// Forget everything.
pub fn clear(self: *Store) void {
    if (self.arena) |*a| a.deinit();
    self.arena = null;
    self.contents = &.{};
}

pub fn deinit(self: *Store) void {
    self.clear();
}

/// The same set of names `terminal.clipboard.isTextMime` accepts; kept here
/// so the store has no dependency on the terminal package.
fn isTextMime(mime: []const u8) bool {
    const names: []const []const u8 = &.{
        "text/plain",
        "text/plain;charset=utf-8",
        "UTF8_STRING",
        "TEXT",
        "STRING",
    };
    for (names) |n| if (std.mem.eql(u8, mime, n)) return true;
    return false;
}

test "win32 selection store: set replaces and owns" {
    const alloc = std.testing.allocator;
    var store: Store = .{};
    defer store.deinit();
    try std.testing.expect(store.isEmpty());

    // The caller's buffers are gone after `set`.
    {
        const text = try alloc.dupe(u8, "first");
        const html = try alloc.dupe(u8, "<b>first</b>");
        defer alloc.free(text);
        defer alloc.free(html);
        try store.set(alloc, &.{
            .{ .mime = "text/plain", .data = text },
            .{ .mime = "text/html", .data = html },
        });
    }
    try std.testing.expectEqualStrings("first", store.get("text/plain").?);
    try std.testing.expectEqualStrings("<b>first</b>", store.get("text/html").?);
    try std.testing.expect(store.get("image/png") == null);

    // A second `set` replaces everything.
    try store.set(alloc, &.{.{ .mime = "text/plain", .data = "second" }});
    try std.testing.expectEqualStrings("second", store.get("text/plain").?);
    try std.testing.expect(store.get("text/html") == null);
    try std.testing.expectEqual(@as(usize, 1), store.contents.len);

    store.clear();
    try std.testing.expect(store.isEmpty());
    try std.testing.expect(store.get("text/plain") == null);
}

test "win32 selection store: a failed set keeps the old contents" {
    var store: Store = .{};
    defer store.deinit();
    try store.set(std.testing.allocator, &.{.{ .mime = "text/plain", .data = "keep" }});

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.OutOfMemory,
        store.set(failing.allocator(), &.{.{ .mime = "text/plain", .data = "lost" }}),
    );
    try std.testing.expectEqualStrings("keep", store.get("text/plain").?);
}

test "win32 selection store: text aliases and listing" {
    const alloc = std.testing.allocator;
    var store: Store = .{};
    defer store.deinit();
    try store.set(alloc, &.{
        .{ .mime = "text/html", .data = "<i>a</i>" },
        .{ .mime = "text/plain", .data = "a" },
        .{ .mime = "image/png", .data = "PNG" },
    });

    try std.testing.expectEqualStrings("a", store.get("UTF8_STRING").?);
    try std.testing.expectEqualStrings("a", store.get("text/plain;charset=utf-8").?);
    try std.testing.expectEqualStrings("a", store.get("STRING").?);
    try std.testing.expectEqualStrings("PNG", store.get("image/png").?);

    var buf: [8][]const u8 = undefined;
    const listed = store.mimes(&buf);
    try std.testing.expectEqual(@as(usize, 3), listed.len);
    try std.testing.expectEqualStrings("text/html", listed[0]);
    try std.testing.expectEqualStrings("text/plain", listed[1]);
    try std.testing.expectEqualStrings("image/png", listed[2]);

    var small: [2][]const u8 = undefined;
    try std.testing.expectEqual(@as(usize, 2), store.mimes(&small).len);
}
