//! The clipboard as a set of MIME-typed representations: which MIME types
//! it offers (`list`, metadata only), one representation of it (`readMime`)
//! and a write of several at once (`plan` + `writePlan`, one clipboard
//! transaction). The mapping between a MIME type and the formats Windows
//! programs use is design-5522 section 3; the byte-level conversions live
//! in `clipboard_html.zig`, `clipboard_image.zig` and `clipboard_mime.zig`.
//!
//! Everything another program put on the clipboard is untrusted: sizes are
//! capped before a byte is copied, and a request is only ever answered
//! from formats named in the table, never from an arbitrary format.
const std = @import("std");
const Allocator = std.mem.Allocator;
const win32 = @import("win32");
const apprt = @import("../../apprt.zig");
const terminal = @import("../../terminal/main.zig");
const clipboard = @import("clipboard.zig");
const drop = @import("drop.zig");
const global = @import("../../global.zig");
const html = @import("clipboard_html.zig");
const image = @import("clipboard_image.zig");
const mime_names = @import("clipboard_mime.zig");

const log = std.log.scoped(.win32_clipboard);

// Standard formats not declared by the user32 bindings.
const cf_bitmap = 2;
const cf_text = win32.user32.CF_TEXT;
const cf_oemtext = 7;
const cf_dib = 8;
const cf_unicodetext = win32.user32.CF_UNICODETEXT;
const cf_hdrop = win32.ole32.CF_HDROP;
const cf_dibv5 = 17;

/// First id of a registered (named) format.
const registered_first = 0xC000;

// Names under which Windows programs register the formats we map.
const name_html = "HTML Format";
const name_png = "PNG";
const name_jpeg = "JFIF";
const name_gif = "GIF";
const name_rtf = "Rich Text Format";

/// Most MIME types a listing returns (the kitty protocol's limit).
pub const max_listing = 16;

/// Most formats looked at when a clipboard is enumerated; a source with
/// more offers the rest to nobody.
const max_formats = 256;

/// Biggest block copied off the clipboard (a DIB of the largest image).
const max_block_bytes: usize = image.max_rgba_bytes;

extern "user32" fn GetClipboardFormatNameW(format: u32, buf: [*]u16, max: i32) callconv(.winapi) i32;

/// One format found on the clipboard. `name` is set for registered formats
/// whose name is of interest (a mapped one or MIME-shaped).
pub const Format = struct {
    id: u32,
    name: ?[]const u8 = null,
};

/// Storage for the names a listing refers to.
pub const NameBuf = struct {
    bytes: [4096]u8 = undefined,
    len: usize = 0,

    fn add(self: *NameBuf, name: []const u8) ?[]const u8 {
        if (self.len + name.len > self.bytes.len) return null;
        const dst = self.bytes[self.len..][0..name.len];
        @memcpy(dst, name);
        self.len += name.len;
        return dst;
    }
};

fn nameIs(f: Format, name: []const u8) bool {
    const n = f.name orelse return false;
    return std.ascii.eqlIgnoreCase(n, name);
}

/// The MIME types offered by `formats`, in the order of design-5522
/// section 3: `text/plain`, `text/html`, `image/png`, `image/jpeg`,
/// `image/gif`, `text/rtf`, `text/uri-list`, then every other MIME-named
/// format as enumerated. No duplicates; at most `buf.len` (and
/// `max_listing`). The result borrows `buf` and the names of `formats`.
pub fn mimesFor(formats: []const Format, buf: [][]const u8) []const []const u8 {
    const cap = @min(buf.len, max_listing);
    var n: usize = 0;

    var has_text = false;
    var has_html = false;
    var has_png = false;
    var has_jpeg = false;
    var has_gif = false;
    var has_rtf = false;
    var has_uri = false;
    for (formats) |f| {
        switch (f.id) {
            cf_unicodetext, cf_text, cf_oemtext => has_text = true,
            cf_dibv5, cf_dib, cf_bitmap => has_png = true,
            cf_hdrop => has_uri = true,
            else => {},
        }
        if (nameIs(f, name_html)) has_html = true;
        if (nameIs(f, name_png) or nameIs(f, "image/png")) has_png = true;
        if (nameIs(f, name_jpeg)) has_jpeg = true;
        if (nameIs(f, name_gif)) has_gif = true;
        if (nameIs(f, name_rtf)) has_rtf = true;
    }

    const fixed = [_]struct { on: bool, mime: []const u8 }{
        .{ .on = has_text, .mime = "text/plain" },
        .{ .on = has_html, .mime = "text/html" },
        .{ .on = has_png, .mime = "image/png" },
        .{ .on = has_jpeg, .mime = "image/jpeg" },
        .{ .on = has_gif, .mime = "image/gif" },
        .{ .on = has_rtf, .mime = "text/rtf" },
        .{ .on = has_uri, .mime = "text/uri-list" },
    };
    for (fixed) |e| {
        if (n >= cap) return buf[0..n];
        if (e.on) {
            buf[n] = e.mime;
            n += 1;
        }
    }

    for (formats) |f| {
        const name = f.name orelse continue;
        if (!mime_names.isMimeName(name)) continue;
        // `text/plain` is the text formats' name; a registered format of
        // that name is not served by `readMime`.
        if (std.ascii.eqlIgnoreCase(name, "text/plain")) continue;
        var dup = false;
        for (buf[0..n]) |have| {
            if (std.ascii.eqlIgnoreCase(have, name)) {
                dup = true;
                break;
            }
        }
        if (dup) continue;
        if (n >= cap) break;
        buf[n] = name;
        n += 1;
    }
    return buf[0..n];
}

fn isKnownName(name: []const u8) bool {
    const known = [_][]const u8{ name_html, name_png, name_jpeg, name_gif, name_rtf };
    for (known) |k| if (std.ascii.eqlIgnoreCase(name, k)) return true;
    return false;
}

/// The name of registered format `id` when it is a mapped or MIME-shaped
/// one (stored in `names`), else null. Metadata only.
fn nameOf(id: u32, names: *NameBuf) ?[]const u8 {
    var wide: [300]u16 = undefined;
    const got = GetClipboardFormatNameW(id, &wide, wide.len);
    if (got <= 0) return null;
    var utf8: [900]u8 = undefined;
    const n = std.unicode.utf16LeToUtf8(&utf8, wide[0..@intCast(got)]) catch return null;
    const name = utf8[0..n];
    if (!isKnownName(name) and !mime_names.isMimeName(name)) return null;
    return names.add(name);
}

/// Enumerates the open clipboard into `out`. Never asks for data.
fn collect(out: []Format, names: *NameBuf) []Format {
    var n: usize = 0;
    var id: u32 = 0;
    while (n < out.len) {
        id = win32.user32.EnumClipboardFormats(id);
        if (id == 0) break;
        out[n] = .{
            .id = id,
            .name = if (id >= registered_first and id <= 0xFFFF) nameOf(id, names) else null,
        };
        n += 1;
    }
    return out[0..n];
}

/// The MIME types the clipboard offers. Opens the clipboard for the length
/// of an enumeration and never calls `GetClipboardData`, so a source that
/// renders its data on demand is not asked to. The result borrows `buf`
/// and `names`.
pub fn list(
    hwnd: win32.foundation.HWND,
    buf: *[max_listing][]const u8,
    names: *NameBuf,
) ![]const []const u8 {
    try clipboard.openClipboard(hwnd);
    var formats: [max_formats]Format = undefined;
    const found = collect(&formats, names);
    _ = win32.user32.CloseClipboard();
    return mimesFor(found, buf);
}

// --- reading ---------------------------------------------------------------------------

fn baseMime(mime: []const u8) []const u8 {
    const semi = std.mem.indexOfScalar(u8, mime, ';') orelse mime.len;
    return std.mem.trim(u8, mime[0..semi], " \t");
}

fn isPlainMime(mime: []const u8) bool {
    return terminal.clipboard.isTextMime(mime) or
        std.ascii.eqlIgnoreCase(baseMime(mime), "text/plain");
}

fn idOf(formats: []const Format, name: []const u8) ?u32 {
    for (formats) |f| if (nameIs(f, name)) return f.id;
    return null;
}

fn hasId(formats: []const Format, id: u32) bool {
    for (formats) |f| if (f.id == id) return true;
    return false;
}

/// A copy of format `id` of the open clipboard, null when it has no data
/// or the block is over `max_block_bytes`.
fn copyBlock(alloc: Allocator, id: u32) !?[]u8 {
    const h = win32.user32.GetClipboardData(id) orelse return null;
    const size = win32.kernel32.GlobalSize(h);
    if (size == 0) return null;
    if (size > max_block_bytes) {
        log.warn("clipboard format {} is {} bytes, not read", .{ id, size });
        return null;
    }
    const ptr = win32.kernel32.GlobalLock(h) orelse return error.LockFailed;
    defer _ = win32.kernel32.GlobalUnlock(h);
    const src: [*]const u8 = @ptrCast(ptr);
    return try alloc.dupe(u8, src[0..size]);
}

/// How the bytes `readMime` copied are turned into the answer.
const Kind = enum { raw, html, dib, hdrop };

const Source = struct { id: u32, kind: Kind };

/// Picks the format to copy for `mime`, from the enumerated `formats`.
fn sourceFor(formats: []const Format, mime: []const u8) ?Source {
    const base = baseMime(mime);
    const eql = std.ascii.eqlIgnoreCase;

    if (eql(base, "text/html")) {
        if (idOf(formats, name_html)) |id| return .{ .id = id, .kind = .html };
    } else if (eql(base, "image/png")) {
        if (idOf(formats, name_png)) |id| return .{ .id = id, .kind = .raw };
        if (idOf(formats, "image/png")) |id| return .{ .id = id, .kind = .raw };
        if (hasId(formats, cf_dibv5)) return .{ .id = cf_dibv5, .kind = .dib };
        if (hasId(formats, cf_dib)) return .{ .id = cf_dib, .kind = .dib };
        return null;
    } else if (eql(base, "image/jpeg")) {
        if (idOf(formats, name_jpeg)) |id| return .{ .id = id, .kind = .raw };
    } else if (eql(base, "image/gif")) {
        if (idOf(formats, name_gif)) |id| return .{ .id = id, .kind = .raw };
    } else if (eql(base, "text/rtf") or eql(base, "application/rtf")) {
        if (idOf(formats, name_rtf)) |id| return .{ .id = id, .kind = .raw };
    } else if (eql(base, "text/uri-list")) {
        if (hasId(formats, cf_hdrop)) return .{ .id = cf_hdrop, .kind = .hdrop };
    }

    // A format registered under exactly this MIME name.
    if (mime_names.isMimeName(mime)) {
        if (idOf(formats, mime)) |id| return .{ .id = id, .kind = .raw };
    }
    return null;
}

/// One representation of the clipboard as `mime`, or null when it has none.
/// Text comes from `CF_UNICODETEXT` only (never from a copied file list),
/// as UTF-8 with LF line ends. The caller owns the result.
pub fn readMime(alloc: Allocator, hwnd: win32.foundation.HWND, mime: []const u8) !?[]u8 {
    if (isPlainMime(mime)) {
        const text = (try clipboard.read(alloc, hwnd)) orelse return null;
        defer alloc.free(text);
        return try alloc.dupe(u8, text);
    }

    var names: NameBuf = .{};
    var formats: [max_formats]Format = undefined;
    var found: []Format = undefined;
    var src: Source = undefined;
    var block: ?[]u8 = null;
    {
        try clipboard.openClipboard(hwnd);
        defer _ = win32.user32.CloseClipboard();
        found = collect(&formats, &names);
        src = sourceFor(found, mime) orelse return null;
        block = try copyBlock(alloc, src.id);
    }
    const bytes = block orelse return null;
    defer alloc.free(bytes);

    switch (src.kind) {
        .raw => return try alloc.dupe(u8, bytes),
        .html => {
            // A NUL ends the block (the clipboard string is terminated).
            const frag = html.fragment(bytes) orelse return null;
            return try alloc.dupe(u8, frag);
        },
        .hdrop => return try uriListFromDrop(alloc, bytes),
        .dib => {
            if (try pngFromDib(alloc, bytes)) |png| return png;
            // The synthesised CF_DIB may succeed where the V5 header did not.
            if (src.id != cf_dibv5 or !hasId(found, cf_dib)) return null;
            const second = blk: {
                try clipboard.openClipboard(hwnd);
                defer _ = win32.user32.CloseClipboard();
                break :blk try copyBlock(alloc, cf_dib);
            } orelse return null;
            defer alloc.free(second);
            return try pngFromDib(alloc, second);
        },
    }
}

fn pngFromDib(alloc: Allocator, block: []const u8) !?[]u8 {
    var img = image.fromDib(alloc, block) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            log.warn("clipboard image not readable err={}", .{err});
            return null;
        },
    };
    defer img.deinit(alloc);
    return image.encodePng(alloc, img) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            log.warn("clipboard image not encodable err={}", .{err});
            return null;
        },
    };
}

fn uriListFromDrop(alloc: Allocator, block: []const u8) !?[]u8 {
    const paths = drop.pathsFromDropFiles(alloc, block) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    defer drop.freePaths(alloc, paths);

    const wide = try alloc.alloc([]const u16, paths.len);
    defer alloc.free(wide);
    var made: usize = 0;
    defer for (wide[0..made]) |w| alloc.free(w);
    for (paths) |p| {
        wide[made] = try std.unicode.utf8ToUtf16LeAlloc(alloc, p);
        made += 1;
    }
    const out = mime_names.uriList(alloc, wide) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidUtf16 => return null,
    };
    if (out.len == 0) {
        alloc.free(out);
        return null;
    }
    return out;
}

// --- writing ---------------------------------------------------------------------------

/// A clipboard format: a standard id or a name to register.
pub const FormatRef = union(enum) {
    standard: u32,
    /// Borrowed: a literal or the MIME of the contents the plan was made from.
    registered: []const u8,
};

/// One format a write sets, with the exact bytes of its block (a terminating
/// NUL included where the format has one).
pub const Entry = struct {
    format: FormatRef,
    bytes: []u8,
};

/// What a write sets. Owns the bytes of its entries.
pub const Plan = struct {
    entries: []Entry,
    /// No representation has any content: the write clears the clipboard.
    cleared: bool,

    pub fn deinit(self: *Plan, alloc: Allocator) void {
        for (self.entries) |e| alloc.free(e.bytes);
        alloc.free(self.entries);
        self.* = undefined;
    }
};

/// `text_utf8` as the bytes of a `CF_UNICODETEXT` block: invalid UTF-8
/// replaced, ended at a NUL, lone LF turned into CRLF, NUL terminated.
fn textBlock(alloc: Allocator, text_utf8: []const u8) ![]u8 {
    const clean = try clipboard.sanitize(alloc, text_utf8);
    defer alloc.free(clean);
    const wide = try std.unicode.utf8ToUtf16LeAlloc(alloc, clean);
    defer alloc.free(wide);

    var lone_lf: usize = 0;
    for (wide, 0..) |c, i| {
        if (c == '\n' and (i == 0 or wide[i - 1] != '\r')) lone_lf += 1;
    }

    const out = try alloc.alloc(u8, (wide.len + lone_lf + 1) * @sizeOf(u16));
    var n: usize = 0;
    const put = struct {
        fn f(dst: []u8, at: *usize, unit: u16) void {
            std.mem.writeInt(u16, dst[at.*..][0..2], unit, .little);
            at.* += 2;
        }
    }.f;
    for (wide, 0..) |c, i| {
        if (c == '\n' and (i == 0 or wide[i - 1] != '\r')) put(out, &n, '\r');
        put(out, &n, c);
    }
    put(out, &n, 0);
    std.debug.assert(n == out.len);
    return out;
}

/// Accumulates the entries of a plan.
const Builder = struct {
    alloc: Allocator,
    list: std.ArrayList(Entry) = .empty,
    any_content: bool = false,

    fn deinit(self: *Builder) void {
        for (self.list.items) |e| self.alloc.free(e.bytes);
        self.list.deinit(self.alloc);
    }

    fn has(self: *const Builder, format: FormatRef) bool {
        for (self.list.items) |e| {
            switch (format) {
                .standard => |id| switch (e.format) {
                    .standard => |have| if (have == id) return true,
                    .registered => {},
                },
                .registered => |name| switch (e.format) {
                    .registered => |have| if (std.ascii.eqlIgnoreCase(have, name)) return true,
                    .standard => {},
                },
            }
        }
        return false;
    }

    /// Takes ownership of `bytes`.
    fn add(self: *Builder, format: FormatRef, bytes: []u8) !void {
        errdefer self.alloc.free(bytes);
        try self.list.append(self.alloc, .{ .format = format, .bytes = bytes });
    }

    /// A raw block, copied, with `terminator` bytes of NUL after it.
    fn addCopy(self: *Builder, format: FormatRef, data: []const u8, nul: bool) !void {
        const bytes = try self.alloc.alloc(u8, data.len + @intFromBool(nul));
        @memcpy(bytes[0..data.len], data);
        if (nul) bytes[data.len] = 0;
        try self.add(format, bytes);
    }

    /// The DIB form of an image, for programs that read no PNG. Failure
    /// leaves the plan with the encoded form only.
    fn addDib(self: *Builder, mime: []const u8, data: []const u8) !void {
        const dib: FormatRef = .{ .standard = cf_dibv5 };
        if (self.has(dib)) return;
        var img = image.decode(self.alloc, mime, data) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                log.warn("clipboard image not decodable, kept as {s} only err={}", .{ mime, err });
                return;
            },
        };
        defer img.deinit(self.alloc);
        const block = image.toDibV5(self.alloc, img) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                log.warn("clipboard image has no DIB form err={}", .{err});
                return;
            },
        };
        try self.add(dib, block);
    }
};

/// What a write of `contents` sets on the clipboard (design-5522
/// section 3): the first text representation as `CF_UNICODETEXT`, HTML as
/// `HTML Format`, images as their encoded format plus a `CF_DIBV5`, the rest
/// by name when it is MIME-shaped. A representation of an unknown or
/// native-looking name is skipped. Pure: no clipboard access. The plan's
/// registered names borrow from `contents`.
pub fn plan(alloc: Allocator, contents: []const apprt.ClipboardContent) !Plan {
    var b: Builder = .{ .alloc = alloc };
    errdefer b.deinit();
    const eql = std.ascii.eqlIgnoreCase;
    const text_ref: FormatRef = .{ .standard = cf_unicodetext };

    for (contents) |c| {
        const data: []const u8 = c.data;
        if (terminal.clipboard.isTextMime(c.mime)) {
            if (b.has(text_ref)) continue;
            const block = try textBlock(alloc, data);
            // The block holds at least its terminator.
            if (block.len > 2) b.any_content = true;
            try b.add(text_ref, block);
            continue;
        }

        const base = baseMime(c.mime);
        // An empty representation other than text carries nothing.
        if (data.len == 0) continue;

        if (eql(base, "text/html")) {
            const ref: FormatRef = .{ .registered = name_html };
            if (b.has(ref)) continue;
            const block = html.wrap(alloc, data) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.TooLarge => {
                    log.warn("clipboard html too large for CF_HTML, skipped", .{});
                    continue;
                },
            };
            // CF_HTML is NUL terminated on the clipboard.
            defer alloc.free(block);
            try b.addCopy(ref, block, true);
            b.any_content = true;
        } else if (eql(base, "image/png")) {
            const ref: FormatRef = .{ .registered = name_png };
            if (b.has(ref)) continue;
            try b.addCopy(ref, data, false);
            b.any_content = true;
            try b.addDib("image/png", data);
        } else if (eql(base, "image/jpeg")) {
            const ref: FormatRef = .{ .registered = name_jpeg };
            if (b.has(ref)) continue;
            try b.addCopy(ref, data, false);
            b.any_content = true;
            try b.addDib("image/jpeg", data);
        } else if (eql(base, "image/gif")) {
            const ref: FormatRef = .{ .registered = name_gif };
            if (b.has(ref)) continue;
            try b.addCopy(ref, data, false);
            b.any_content = true;
        } else if (eql(base, "text/rtf") or eql(base, "application/rtf")) {
            const ref: FormatRef = .{ .registered = name_rtf };
            if (b.has(ref)) continue;
            try b.addCopy(ref, data, false);
            b.any_content = true;
        } else if (mime_names.isMimeName(c.mime)) {
            const ref: FormatRef = .{ .registered = c.mime };
            if (b.has(ref)) continue;
            try b.addCopy(ref, data, false);
            b.any_content = true;
        } else {
            log.debug("clipboard write skips representation {s}", .{c.mime});
        }
    }

    return .{
        .entries = try b.list.toOwnedSlice(alloc),
        .cleared = !b.any_content,
    };
}

/// A plan of one text representation. `write` in `clipboard.zig` is this.
pub fn textPlan(alloc: Allocator, text_utf8: []const u8) !Plan {
    var entries = try alloc.alloc(Entry, 1);
    errdefer alloc.free(entries);
    entries[0] = .{
        .format = .{ .standard = cf_unicodetext },
        .bytes = try textBlock(alloc, text_utf8),
    };
    return .{ .entries = entries, .cleared = entries[0].bytes.len <= 2 };
}

/// One block of movable memory holding `bytes`, ready for the clipboard.
fn globalFrom(bytes: []const u8) !win32.kernel32.HGLOBAL {
    const mem = win32.kernel32.GlobalAlloc(win32.kernel32.GMEM_MOVEABLE, @max(bytes.len, 1)) orelse
        return error.OutOfMemory;
    errdefer _ = win32.kernel32.GlobalFree(mem);
    const ptr = win32.kernel32.GlobalLock(mem) orelse return error.LockFailed;
    defer _ = win32.kernel32.GlobalUnlock(mem);
    const dst: [*]u8 = @ptrCast(ptr);
    @memcpy(dst[0..bytes.len], bytes);
    return mem;
}

/// Sets every entry of `p` in one transaction: the memory is allocated
/// first, so a failure there leaves the clipboard as it was; then the
/// clipboard is opened for `hwnd` (it must be a real window, the owner),
/// emptied and filled, and the exclusion markers of `secure` input go last.
/// An entry that cannot be set is skipped with a warning; none set at all is
/// an error.
pub fn writePlan(hwnd: win32.foundation.HWND, p: Plan, secure: bool) !void {
    const alloc = global.alloc();
    const ids = try alloc.alloc(u32, p.entries.len);
    defer alloc.free(ids);
    const mems = try alloc.alloc(?win32.kernel32.HGLOBAL, p.entries.len);
    defer alloc.free(mems);
    @memset(mems, null);
    // Whatever the clipboard did not take.
    defer for (mems) |m| if (m) |mem| {
        _ = win32.kernel32.GlobalFree(mem);
    };

    for (p.entries, 0..) |e, i| {
        ids[i] = switch (e.format) {
            .standard => |id| id,
            .registered => |name| try registerFormat(alloc, name),
        };
        mems[i] = try globalFrom(e.bytes);
    }

    try clipboard.openClipboard(hwnd);
    defer _ = win32.user32.CloseClipboard();
    if (win32.user32.EmptyClipboard() == 0) return error.EmptyClipboardFailed;

    var set: usize = 0;
    for (ids, mems) |id, *slot| {
        const mem = slot.* orelse continue;
        if (win32.user32.SetClipboardData(id, mem) == null) {
            log.warn("unable to set clipboard format {} err={}", .{ id, win32.kernel32.GetLastError() });
            continue;
        }
        // The clipboard owns the memory now.
        slot.* = null;
        set += 1;
    }
    if (set == 0 and p.entries.len > 0) return error.SetClipboardFailed;
    for (clipboard.extraFormats(secure)) |extra| clipboard.setExtraFormat(extra);
}

fn registerFormat(alloc: Allocator, name: []const u8) !u32 {
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(alloc, name);
    defer alloc.free(wide);
    const id = win32.user32.RegisterClipboardFormatW(wide.ptr);
    if (id == 0) {
        log.warn("unable to register a clipboard format err={}", .{win32.kernel32.GetLastError()});
        return error.RegisterFormatFailed;
    }
    return id;
}

// --- tests -----------------------------------------------------------------------------

fn expectMimes(want: []const []const u8, got: []const []const u8) !void {
    try std.testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try std.testing.expectEqualStrings(w, g);
}

test "win32 clipboard formats: listing order and mapping" {
    const formats = [_]Format{
        .{ .id = cf_unicodetext },
        .{ .id = 16 }, // CF_LOCALE
        .{ .id = 0xC001, .name = "HTML Format" },
        .{ .id = cf_dib },
        .{ .id = 0xC002, .name = "PNG" },
        .{ .id = cf_hdrop },
        .{ .id = 0xC003, .name = "image/svg+xml" },
        // Not MIME-shaped, so not offered.
        .{ .id = 0xC004, .name = null },
        .{ .id = 0xC005, .name = "Rich Text Format" },
    };
    var buf: [max_listing][]const u8 = undefined;
    try expectMimes(
        &.{ "text/plain", "text/html", "image/png", "text/rtf", "text/uri-list", "image/svg+xml" },
        mimesFor(&formats, &buf),
    );

    // More MIME-named formats than a listing holds.
    var storage: [30][24]u8 = undefined;
    var many: [30]Format = undefined;
    for (&many, 0..) |*f, i| {
        const name = try std.fmt.bufPrint(&storage[i], "application/x-t{d}", .{i});
        f.* = .{ .id = 0xC100 + @as(u32, @intCast(i)), .name = name };
    }
    const capped = mimesFor(&many, &buf);
    try std.testing.expectEqual(@as(usize, 16), capped.len);
    try std.testing.expectEqualStrings("application/x-t0", capped[0]);
    try std.testing.expectEqualStrings("application/x-t15", capped[15]);

    // Registered names that are also mapped ones are listed once.
    const dup = [_]Format{
        .{ .id = 0xC200, .name = "image/png" },
        .{ .id = 0xC201, .name = "PNG" },
        .{ .id = 0xC202, .name = "text/plain" },
        .{ .id = 0xC203, .name = "application/x-a" },
        .{ .id = 0xC204, .name = "application/x-a" },
    };
    try expectMimes(&.{ "image/png", "application/x-a" }, mimesFor(&dup, &buf));

    // A native format with no MIME name is never offered.
    const native = [_]Format{
        .{ .id = 0xC300, .name = null },
        .{ .id = cf_unicodetext },
    };
    try expectMimes(&.{"text/plain"}, mimesFor(&native, &buf));
}

fn testPng2x2(alloc: Allocator) ![]u8 {
    var px = [_]u8{
        255, 0, 0,   255, 0,   255, 0,   255,
        0,   0, 255, 255, 255, 255, 255, 128,
    };
    return image.encodePng(alloc, .{ .width = 2, .height = 2, .pixels = &px });
}

fn entryFor(p: Plan, ref: FormatRef) ?Entry {
    for (p.entries) |e| {
        switch (ref) {
            .standard => |id| switch (e.format) {
                .standard => |have| if (have == id) return e,
                .registered => {},
            },
            .registered => |name| switch (e.format) {
                .registered => |have| if (std.ascii.eqlIgnoreCase(have, name)) return e,
                .standard => {},
            },
        }
    }
    return null;
}

test "win32 clipboard formats: write plan" {
    const alloc = std.testing.allocator;

    // Text and HTML.
    {
        var p = try plan(alloc, &.{
            .{ .mime = "text/plain", .data = "a\nb" },
            .{ .mime = "text/html", .data = "<b>a</b>" },
        });
        defer p.deinit(alloc);
        try std.testing.expectEqual(@as(usize, 2), p.entries.len);
        try std.testing.expect(!p.cleared);

        const text = entryFor(p, .{ .standard = cf_unicodetext }).?;
        const want: []const u16 = std.unicode.utf8ToUtf16LeStringLiteral("a\r\nb");
        try std.testing.expectEqual((want.len + 1) * 2, text.bytes.len);
        try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(want), text.bytes[0 .. want.len * 2]);
        try std.testing.expectEqualSlices(u8, &.{ 0, 0 }, text.bytes[want.len * 2 ..]);

        const h = entryFor(p, .{ .registered = "HTML Format" }).?;
        try std.testing.expectEqual(@as(u8, 0), h.bytes[h.bytes.len - 1]);
        try std.testing.expectEqualStrings("<b>a</b>", html.fragment(h.bytes).?);
    }

    // A PNG: the bytes as they are, plus a DIBV5.
    {
        const png = try testPng2x2(alloc);
        defer alloc.free(png);
        const png_z = try alloc.dupeSentinel(u8, png, 0);
        defer alloc.free(png_z);
        var p = try plan(alloc, &.{.{ .mime = "image/png", .data = png_z }});
        defer p.deinit(alloc);
        try std.testing.expectEqual(@as(usize, 2), p.entries.len);
        try std.testing.expect(!p.cleared);
        try std.testing.expectEqualSlices(u8, png, entryFor(p, .{ .registered = "PNG" }).?.bytes);
        var img = try image.fromDib(alloc, entryFor(p, .{ .standard = cf_dibv5 }).?.bytes);
        defer img.deinit(alloc);
        try std.testing.expectEqual(@as(u32, 2), img.width);
        try std.testing.expectEqual(@as(u32, 2), img.height);
    }

    // A PNG that does not decode is still offered as it is.
    {
        var p = try plan(alloc, &.{.{ .mime = "image/png", .data = "\x89PNG\r\n\x1a\nnot a png" }});
        defer p.deinit(alloc);
        try std.testing.expectEqual(@as(usize, 1), p.entries.len);
        try std.testing.expect(entryFor(p, .{ .registered = "PNG" }) != null);
    }

    // Names of native formats are never set.
    {
        var p = try plan(alloc, &.{
            .{ .mime = "FileGroupDescriptorW", .data = "x" },
            .{ .mime = "Shell IDList Array", .data = "x" },
            .{ .mime = "text/plain", .data = "ok" },
        });
        defer p.deinit(alloc);
        try std.testing.expectEqual(@as(usize, 1), p.entries.len);
    }

    // Two texts: the first wins.
    {
        var p = try plan(alloc, &.{
            .{ .mime = "text/plain", .data = "first" },
            .{ .mime = "UTF8_STRING", .data = "second" },
        });
        defer p.deinit(alloc);
        try std.testing.expectEqual(@as(usize, 1), p.entries.len);
        const want: []const u16 = std.unicode.utf8ToUtf16LeStringLiteral("first");
        try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(want), p.entries[0].bytes[0 .. want.len * 2]);
    }

    // An empty text clears: one empty CF_UNICODETEXT.
    {
        var p = try plan(alloc, &.{.{ .mime = "text/plain", .data = "" }});
        defer p.deinit(alloc);
        try std.testing.expectEqual(@as(usize, 1), p.entries.len);
        try std.testing.expectEqualSlices(u8, &.{ 0, 0 }, p.entries[0].bytes);
        try std.testing.expect(p.cleared);
    }

    // HTML or an image alone, other MIME-shaped data by its name.
    {
        var p = try plan(alloc, &.{
            .{ .mime = "text/html", .data = "<i>x</i>" },
            .{ .mime = "text/uri-list", .data = "file:///C:/a\r\n" },
            .{ .mime = "image/gif", .data = "GIF89a" },
            .{ .mime = "application/rtf", .data = "{\\rtf1}" },
        });
        defer p.deinit(alloc);
        try std.testing.expectEqual(@as(usize, 4), p.entries.len);
        try std.testing.expect(entryFor(p, .{ .registered = "text/uri-list" }) != null);
        try std.testing.expect(entryFor(p, .{ .registered = "GIF" }) != null);
        try std.testing.expect(entryFor(p, .{ .registered = "Rich Text Format" }) != null);
        try std.testing.expect(entryFor(p, .{ .standard = cf_unicodetext }) == null);
    }

    // Nothing usable: no entries.
    {
        var p = try plan(alloc, &.{.{ .mime = "FileGroupDescriptorW", .data = "x" }});
        defer p.deinit(alloc);
        try std.testing.expectEqual(@as(usize, 0), p.entries.len);
    }
}

test "win32 clipboard formats: text plan is the text a copy has always put" {
    const alloc = std.testing.allocator;
    var p = try textPlan(alloc, "copy Ж😀\nline2\r\nx\xff");
    defer p.deinit(alloc);
    const want: []const u16 = std.unicode.utf8ToUtf16LeStringLiteral("copy Ж😀\r\nline2\r\nx\u{FFFD}");
    try std.testing.expectEqual(@as(usize, 1), p.entries.len);
    try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(want), p.entries[0].bytes[0 .. want.len * 2]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0 }, p.entries[0].bytes[want.len * 2 ..]);
}
