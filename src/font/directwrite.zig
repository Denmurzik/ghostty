//! DirectWrite font discovery and `MapCharacters` fallback for the Windows
//! backend. DirectWrite only resolves which file holds a face; the face is
//! then opened through FreeType from a UTF-16 mapped view like every other
//! Windows face (see `WindowsFontFile`). Fonts whose file loader is not
//! local (cloud or remote fonts) are skipped.
const std = @import("std");
const Allocator = std.mem.Allocator;
const win32 = @import("win32");
const com = win32.com;
const dwrite = win32.dwrite;
const WindowsFontFile = @import("WindowsFontFile.zig");
const font = @import("main.zig");
const global = @import("../global.zig");
const Descriptor = font.discovery.Descriptor;
const DeferredFace = font.DeferredFace;
const Face = font.Face;
const Library = font.Library;

const log = std.log.scoped(.directwrite);

const Font = dwrite.IDWriteFont;

/// LOCALE_NAME_MAX_LENGTH, including the terminator.
const locale_name_max = 85;

pub const DirectWrite = struct {
    factory: *dwrite.IDWriteFactory,
    collection: *dwrite.IDWriteFontCollection,

    /// Null when the OS predates IDWriteFactory2 (before Windows 8.1).
    system_fallback: ?*dwrite.IDWriteFontFallback,

    /// The user's locale, which steers Han unification in fallback.
    locale: [locale_name_max + 1:0]u16,

    /// The shared factory and the system collection. Null when DirectWrite
    /// is unusable, in which case the caller falls back to the file index.
    pub fn init() ?DirectWrite {
        const factory = dwrite.createFactory() catch |err| {
            log.warn("cannot create the DirectWrite factory err={}", .{err});
            return null;
        };
        const collection = dwrite.getSystemFontCollection(factory) catch |err| {
            log.warn("cannot get the system font collection err={}", .{err});
            com.release(factory);
            return null;
        };

        var system_fallback: ?*dwrite.IDWriteFontFallback = null;
        if (com.queryInterface(factory, dwrite.IDWriteFactory2)) |f2| {
            defer com.release(f2);
            system_fallback = f2.getSystemFontFallback() catch null;
        } else |_| {}

        var locale: [locale_name_max + 1:0]u16 = @splat(0);
        const n = win32.kernel32.GetUserDefaultLocaleName(&locale, locale_name_max);
        if (n <= 0) {
            for ("en-us", 0..) |c, i| locale[i] = c;
            locale[5] = 0;
        }

        return .{
            .factory = factory,
            .collection = collection,
            .system_fallback = system_fallback,
            .locale = locale,
        };
    }

    pub fn deinit(self: *DirectWrite) void {
        com.release(self.system_fallback);
        com.release(self.collection);
        com.release(self.factory);
        self.* = undefined;
    }

    /// Faces of `desc.family` (localized or full name), best match first;
    /// without a family every installed face, filtered by `monospace`.
    /// Only faces with `desc.codepoint` are returned.
    pub fn discover(
        self: *const DirectWrite,
        alloc: Allocator,
        lib: Library,
        desc: Descriptor,
    ) !Iterator {
        const family = desc.family orelse
            return Iterator.initWalk(self.collection, alloc, lib, desc);

        var fonts: std.ArrayList(*Font) = .empty;
        errdefer releaseAll(alloc, &fonts);

        if (!try self.collectFamily(alloc, &fonts, family, desc)) {
            try self.collectFullName(alloc, &fonts, family);
        }
        return Iterator.initList(alloc, lib, desc, try fonts.toOwnedSlice(alloc));
    }

    /// The font the system picks for `desc.codepoint`, unless the request
    /// is for emoji presentation (which is resolved from the emoji
    /// families, not the text fallback).
    pub fn fallback(
        self: *const DirectWrite,
        alloc: Allocator,
        lib: Library,
        base_family: ?[]const u8,
        desc: Descriptor,
    ) !Iterator {
        var fonts: std.ArrayList(*Font) = .empty;
        errdefer releaseAll(alloc, &fonts);

        if (desc.presentation != .emoji) try self.mapCharacter(alloc, &fonts, base_family, desc);
        return Iterator.initList(alloc, lib, desc, try fonts.toOwnedSlice(alloc));
    }

    /// The best face of each of `families` that exists, in list order.
    pub fn discoverFamilies(
        self: *const DirectWrite,
        alloc: Allocator,
        lib: Library,
        families: []const []const u8,
        desc: Descriptor,
    ) !Iterator {
        var fonts: std.ArrayList(*Font) = .empty;
        errdefer releaseAll(alloc, &fonts);

        for (families) |name| {
            const name_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, name);
            defer alloc.free(name_w);
            const idx = (self.collection.findFamilyName(name_w) catch null) orelse continue;
            const fam = self.collection.getFontFamily(idx) catch continue;
            defer com.release(fam);
            const f = fam.getFirstMatchingFont(
                if (desc.bold) .BOLD else .NORMAL,
                .NORMAL,
                if (desc.italic) .ITALIC else .NORMAL,
            ) catch continue;
            fonts.append(alloc, f) catch |err| {
                com.release(f);
                return err;
            };
        }
        return Iterator.initList(alloc, lib, desc, try fonts.toOwnedSlice(alloc));
    }

    fn releaseAll(alloc: Allocator, fonts: *std.ArrayList(*Font)) void {
        for (fonts.items) |f| com.release(f);
        fonts.deinit(alloc);
    }

    /// Append the fonts of the family called `name`, ranked for `desc`.
    /// False if the collection has no such family.
    fn collectFamily(
        self: *const DirectWrite,
        alloc: Allocator,
        fonts: *std.ArrayList(*Font),
        name: []const u8,
        desc: Descriptor,
    ) !bool {
        const name_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, name);
        defer alloc.free(name_w);
        const idx = (self.collection.findFamilyName(name_w) catch null) orelse return false;
        const fam = self.collection.getFontFamily(idx) catch return false;
        defer com.release(fam);

        const Ranked = struct { font: *Font, key: [4]u32 };
        var ranked: std.ArrayList(Ranked) = .empty;
        defer ranked.deinit(alloc);
        errdefer for (ranked.items) |r| com.release(r.font);

        for (0..fam.getFontCount()) |i| {
            const f = fam.getFont(@intCast(i)) catch continue;
            ranked.append(alloc, .{ .font = f, .key = rankKey(f, desc) }) catch |err| {
                com.release(f);
                return err;
            };
        }
        std.sort.block(Ranked, ranked.items, {}, struct {
            fn lessThan(_: void, a: Ranked, b: Ranked) bool {
                return std.mem.order(u32, &a.key, &b.key) == .lt;
            }
        }.lessThan);

        try fonts.ensureUnusedCapacity(alloc, ranked.items.len);
        for (ranked.items) |r| fonts.appendAssumeCapacity(r.font);
        ranked.clearRetainingCapacity();
        return true;
    }

    /// An exact style name match first, then the closest weight, then the
    /// requested slant, then normal stretch, then monospace.
    fn rankKey(f: *Font, desc: Descriptor) [4]u32 {
        const target: i32 = if (desc.bold) 700 else 400;
        const style_exact = if (desc.style) |s| style: {
            const names = f.getFaceNames() catch break :style false;
            defer com.release(names);
            break :style anyStringEquals(names, s);
        } else false;
        const italic = f.getStyle() != .NORMAL;
        return .{
            @intFromBool(!style_exact),
            @abs(@as(i32, @intCast(f.getWeight())) - target),
            @as(u32, @intFromBool(italic != desc.italic)) * 2 +
                @intFromBool(f.getStretch() != 5),
            @intFromBool(desc.monospace and !isMonospace(f)),
        };
    }

    /// Append the one font whose full name ("Consolas Bold") is `name`.
    fn collectFullName(
        self: *const DirectWrite,
        alloc: Allocator,
        fonts: *std.ArrayList(*Font),
        name: []const u8,
    ) !void {
        for (0..self.collection.getFontFamilyCount()) |fi| {
            const fam = self.collection.getFontFamily(@intCast(fi)) catch continue;
            defer com.release(fam);
            for (0..fam.getFontCount()) |i| {
                const f = fam.getFont(@intCast(i)) catch continue;
                const names = (f.getInformationalStrings(.FULL_NAME) catch null) orelse {
                    com.release(f);
                    continue;
                };
                defer com.release(names);
                if (!anyStringEquals(names, name)) {
                    com.release(f);
                    continue;
                }
                fonts.append(alloc, f) catch |err| {
                    com.release(f);
                    return err;
                };
                return;
            }
        }
    }

    fn mapCharacter(
        self: *const DirectWrite,
        alloc: Allocator,
        fonts: *std.ArrayList(*Font),
        base_family: ?[]const u8,
        desc: Descriptor,
    ) !void {
        const fb = self.system_fallback orelse return;
        const cp = desc.codepoint;
        if (cp == 0 or cp > 0x10FFFF or (cp >= 0xD800 and cp <= 0xDFFF)) return;

        var source: TextSource = .init(cp, &self.locale);
        const base_w: ?[:0]u16 = if (base_family) |b|
            try std.unicode.utf8ToUtf16LeAllocZ(alloc, b)
        else
            null;
        defer if (base_w) |b| alloc.free(b);

        const mapped = fb.mapCharacters(
            @ptrCast(&source),
            0,
            source.len,
            if (base_w) |b| b.ptr else null,
            if (desc.bold) .BOLD else .NORMAL,
            if (desc.italic) .ITALIC else .NORMAL,
            .NORMAL,
        ) catch |err| {
            log.debug("MapCharacters failed cp={X} err={}", .{ cp, err });
            return;
        };
        const f = mapped.font orelse return;
        logMapped(f, cp);
        fonts.append(alloc, f) catch |err| {
            com.release(f);
            return err;
        };
    }

    pub const Iterator = struct {
        alloc: Allocator,
        lib: Library,
        codepoint: u32,
        variations: []const font.face.Variation,
        monospace_only: bool,

        /// Owned references to the remaining candidates, `fonts[pos..]`.
        fonts: []*Font,
        pos: usize = 0,

        /// Set instead of `fonts` when walking every family.
        walk: ?Walk = null,

        const Walk = struct {
            collection: *dwrite.IDWriteFontCollection,
            family_count: u32,
            family_index: u32 = 0,
            family: ?*dwrite.IDWriteFontFamily = null,
            font_index: u32 = 0,
            font_count: u32 = 0,
        };

        fn initList(alloc: Allocator, lib: Library, desc: Descriptor, fonts: []*Font) Iterator {
            return .{
                .alloc = alloc,
                .lib = lib,
                .codepoint = desc.codepoint,
                .variations = desc.variations,
                .monospace_only = false,
                .fonts = fonts,
            };
        }

        fn initWalk(
            collection: *dwrite.IDWriteFontCollection,
            alloc: Allocator,
            lib: Library,
            desc: Descriptor,
        ) Iterator {
            return .{
                .alloc = alloc,
                .lib = lib,
                .codepoint = desc.codepoint,
                .variations = desc.variations,
                // Without a family a monospace request is a filter.
                .monospace_only = desc.monospace,
                .fonts = &.{},
                .walk = .{
                    .collection = collection,
                    .family_count = collection.getFontFamilyCount(),
                },
            };
        }

        pub fn deinit(self: *Iterator) void {
            for (self.fonts[self.pos..]) |f| com.release(f);
            self.alloc.free(self.fonts);
            if (self.walk) |w| com.release(w.family);
            self.* = undefined;
        }

        pub fn next(self: *Iterator) !?DeferredFace {
            while (self.nextFont()) |f| {
                defer com.release(f);
                if (try self.open(f)) |face| return face;
            }
            return null;
        }

        /// The next candidate; the caller releases it.
        fn nextFont(self: *Iterator) ?*Font {
            if (self.walk) |*w| {
                while (true) {
                    if (w.family) |fam| {
                        if (w.font_index < w.font_count) {
                            const i = w.font_index;
                            w.font_index += 1;
                            return fam.getFont(i) catch continue;
                        }
                        com.release(fam);
                        w.family = null;
                    }
                    if (w.family_index >= w.family_count) return null;
                    const i = w.family_index;
                    w.family_index += 1;
                    const fam = w.collection.getFontFamily(i) catch continue;
                    w.family = fam;
                    w.font_index = 0;
                    w.font_count = fam.getFontCount();
                }
            }

            if (self.pos >= self.fonts.len) return null;
            defer self.pos += 1;
            return self.fonts[self.pos];
        }

        /// Open a candidate and check that it covers the requested
        /// codepoint. Unreadable and non-local fonts are skipped.
        fn open(self: *Iterator, f: *Font) !?DeferredFace {
            if (self.codepoint != 0) {
                if (!(f.hasCharacter(self.codepoint) catch false)) return null;
            }
            if (self.monospace_only and !isMonospace(f)) return null;

            const location = try fileLocation(self.alloc, f) orelse return null;
            errdefer self.alloc.free(location.path);

            const file = WindowsFontFile.open(location.path) catch return null;
            var face = Face.initMapped(
                self.lib,
                file,
                location.face_index,
                .{ .size = .{ .points = 12 } },
            ) catch return null;
            errdefer face.deinit();

            if (self.codepoint != 0 and face.glyphIndex(self.codepoint) == null) {
                face.deinit();
                self.alloc.free(location.path);
                return null;
            }

            return .{ .win = .{
                .path = location.path,
                .face_index = location.face_index,
                .variations = self.variations,
                .peek = face,
                .presentation = if (face.hasColor()) .emoji else .text,
                .alloc = self.alloc,
            } };
        }
    };
};

const Location = struct {
    /// WTF-8, owned by the caller.
    path: [:0]u8,
    face_index: i32,
};

/// The file and face index behind `f`, or null for fonts without a single
/// local file.
fn fileLocation(alloc: Allocator, f: *Font) !?Location {
    const face = f.createFontFace() catch return null;
    defer com.release(face);

    const count = face.getFileCount() catch return null;
    if (count != 1) return null;
    var files: [1]?*dwrite.IDWriteFontFile = .{null};
    face.getFiles(&files) catch return null;
    const file = files[0] orelse return null;
    defer com.release(file);

    const loader = file.getLoader() catch return null;
    defer com.release(loader);
    const local = com.queryInterface(loader, dwrite.IDWriteLocalFontFileLoader) catch {
        log.debug("skipping a font without a local file loader", .{});
        return null;
    };
    defer com.release(local);

    const key = file.getReferenceKey() catch return null;
    const len = local.getFilePathLengthFromKey(key.key, key.size) catch return null;
    const wide = try alloc.alloc(u16, len + 1);
    defer alloc.free(wide);
    local.getFilePathFromKey(key.key, key.size, wide) catch return null;

    return .{
        .path = try std.unicode.wtf16LeToWtf8AllocZ(alloc, wide[0..len]),
        .face_index = std.math.cast(i32, face.getIndex()) orelse return null,
    };
}

/// The family DirectWrite chose for `cp`, for the fallback trail in the log.
fn logMapped(f: *Font, cp: u32) void {
    const fam = f.getFontFamily() catch return;
    defer com.release(fam);
    const names = fam.getFamilyNames() catch return;
    defer com.release(names);
    var wide: [256]u16 = undefined;
    var utf8: [768]u8 = undefined;
    const en = std.unicode.utf8ToUtf16LeStringLiteral("en-us");
    const idx = (names.findLocaleName(en) catch null) orelse 0;
    const w = names.getString(idx, &wide) catch return;
    const n = std.unicode.utf16LeToUtf8(&utf8, w) catch return;
    log.info("directwrite fallback family={s} cp={X}", .{ utf8[0..n], cp });
}

fn isMonospace(f: *Font) bool {
    const f1 = com.queryInterface(f, dwrite.IDWriteFont1) catch return false;
    defer com.release(f1);
    return f1.isMonospacedFont();
}

/// Whether any locale of `strings` equals `needle`, ASCII case-insensitive.
fn anyStringEquals(strings: *dwrite.IDWriteLocalizedStrings, needle: []const u8) bool {
    var wide: [256]u16 = undefined;
    var utf8: [768]u8 = undefined;
    for (0..strings.getCount()) |i| {
        const w = strings.getString(@intCast(i), &wide) catch continue;
        const n = std.unicode.utf16LeToUtf8(&utf8, w) catch continue;
        if (std.ascii.eqlIgnoreCase(utf8[0..n], needle)) return true;
    }
    return false;
}

/// IDWriteTextAnalysisSource over one codepoint, implemented here. It lives
/// on the caller's stack for the duration of `MapCharacters`; DirectWrite
/// does not keep it, so the reference count only has to be honoured, never
/// to free anything.
const TextSource = extern struct {
    /// Must stay first: DirectWrite sees this struct as the interface.
    vtable: *const dwrite.IDWriteTextAnalysisSource.VTable,
    refs: u32,
    text: [2]u16,
    len: u32,
    locale: [*:0]const u16,

    const vtable_impl: dwrite.IDWriteTextAnalysisSource.VTable = .{
        .base = .{
            .QueryInterface = queryInterface,
            .AddRef = addRef,
            .Release = release,
        },
        .GetTextAtPosition = getTextAtPosition,
        .GetTextBeforePosition = getTextBeforePosition,
        .GetParagraphReadingDirection = getParagraphReadingDirection,
        .GetLocaleName = getLocaleName,
        .GetNumberSubstitution = getNumberSubstitution,
    };

    fn init(cp: u32, locale: [*:0]const u16) TextSource {
        var self: TextSource = .{
            .vtable = &vtable_impl,
            .refs = 1,
            .text = .{ 0, 0 },
            .len = 1,
            .locale = locale,
        };
        if (cp < 0x10000) {
            self.text[0] = @intCast(cp);
        } else {
            const c = cp - 0x10000;
            self.text[0] = @intCast(0xD800 + (c >> 10));
            self.text[1] = @intCast(0xDC00 + (c & 0x3FF));
            self.len = 2;
        }
        return self;
    }

    fn from(p: *dwrite.IDWriteTextAnalysisSource) *TextSource {
        return @ptrCast(@alignCast(p));
    }

    fn queryInterface(
        p: *com.IUnknown,
        riid: *const win32.foundation.GUID,
        out: *?*anyopaque,
    ) callconv(.winapi) win32.foundation.HRESULT {
        const wanted = std.mem.asBytes(riid);
        if (std.mem.eql(u8, wanted, std.mem.asBytes(&com.IUnknown.iid)) or
            std.mem.eql(u8, wanted, std.mem.asBytes(&dwrite.IDWriteTextAnalysisSource.iid)))
        {
            out.* = p;
            _ = addRef(p);
            return win32.foundation.S_OK;
        }
        out.* = null;
        return win32.ole32.E_NOINTERFACE;
    }

    fn addRef(p: *com.IUnknown) callconv(.winapi) u32 {
        const self = from(@ptrCast(p));
        return @atomicRmw(u32, &self.refs, .Add, 1, .monotonic) + 1;
    }

    fn release(p: *com.IUnknown) callconv(.winapi) u32 {
        const self = from(@ptrCast(p));
        return @atomicRmw(u32, &self.refs, .Sub, 1, .monotonic) - 1;
    }

    fn getTextAtPosition(
        p: *dwrite.IDWriteTextAnalysisSource,
        position: u32,
        text: *?[*]const u16,
        len: *u32,
    ) callconv(.winapi) win32.foundation.HRESULT {
        const self = from(p);
        if (position >= self.len) {
            text.* = null;
            len.* = 0;
        } else {
            text.* = self.text[position..].ptr;
            len.* = self.len - position;
        }
        return win32.foundation.S_OK;
    }

    fn getTextBeforePosition(
        p: *dwrite.IDWriteTextAnalysisSource,
        position: u32,
        text: *?[*]const u16,
        len: *u32,
    ) callconv(.winapi) win32.foundation.HRESULT {
        const self = from(p);
        if (position == 0 or position > self.len) {
            text.* = null;
            len.* = 0;
        } else {
            text.* = &self.text;
            len.* = position;
        }
        return win32.foundation.S_OK;
    }

    fn getParagraphReadingDirection(
        p: *dwrite.IDWriteTextAnalysisSource,
    ) callconv(.winapi) dwrite.ReadingDirection {
        _ = p;
        return .LEFT_TO_RIGHT;
    }

    fn getLocaleName(
        p: *dwrite.IDWriteTextAnalysisSource,
        position: u32,
        len: *u32,
        locale: *?[*:0]const u16,
    ) callconv(.winapi) win32.foundation.HRESULT {
        const self = from(p);
        len.* = self.len -| position;
        locale.* = self.locale;
        return win32.foundation.S_OK;
    }

    fn getNumberSubstitution(
        p: *dwrite.IDWriteTextAnalysisSource,
        position: u32,
        len: *u32,
        substitution: *?*anyopaque,
    ) callconv(.winapi) win32.foundation.HRESULT {
        const self = from(p);
        len.* = self.len -| position;
        substitution.* = null;
        return win32.foundation.S_OK;
    }
};

// Tests run against the real system fonts and need a stock Windows install.

fn testFirstFileName(iter: *DirectWrite.Iterator, buf: []u8) !?[]const u8 {
    var face = (try iter.next()) orelse return null;
    defer face.deinit();
    return std.ascii.lowerString(buf, std.fs.path.basenameWindows(face.win.?.path));
}

fn testResolves(desc: Descriptor, expected: []const u8) !void {
    var lib: Library = try .init(std.testing.allocator);
    defer lib.deinit();
    var dw = DirectWrite.init() orelse return error.SkipZigTest;
    defer dw.deinit();
    var iter = try dw.discover(std.testing.allocator, lib, desc);
    defer iter.deinit();

    var buf: [256]u8 = undefined;
    const name = (try testFirstFileName(&iter, &buf)) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(expected, name);
}

test "windows directwrite: Consolas styles map to their files" {
    try testResolves(.{ .family = "Consolas" }, "consola.ttf");
    try testResolves(.{ .family = "consolas", .bold = true }, "consolab.ttf");
    try testResolves(.{ .family = "Consolas", .italic = true }, "consolai.ttf");
    try testResolves(.{ .family = "Consolas", .bold = true, .italic = true }, "consolaz.ttf");
    try testResolves(.{ .family = "Consolas", .style = "Bold Italic" }, "consolaz.ttf");
}

test "windows directwrite: unknown family yields nothing" {
    var lib: Library = try .init(std.testing.allocator);
    defer lib.deinit();
    var dw = DirectWrite.init() orelse return error.SkipZigTest;
    defer dw.deinit();
    var iter = try dw.discover(std.testing.allocator, lib, .{ .family = "No Such Family 7f3a" });
    defer iter.deinit();
    try std.testing.expect((try iter.next()) == null);
}

test "windows directwrite: full name lookup" {
    try testResolves(.{ .family = "Consolas Bold" }, "consolab.ttf");
}

test "windows directwrite: CJK fallback picks a Japanese face" {
    var lib: Library = try .init(std.testing.allocator);
    defer lib.deinit();
    var dw = DirectWrite.init() orelse return error.SkipZigTest;
    defer dw.deinit();
    var iter = try dw.fallback(std.testing.allocator, lib, null, .{ .codepoint = 0x3042 });
    defer iter.deinit();

    var face = (try iter.next()) orelse return error.TestUnexpectedResult;
    defer face.deinit();
    var buf: [256]u8 = undefined;
    const family = try face.familyName(&buf);
    const allowed = [_][]const u8{
        "Yu Gothic", "Yu Gothic UI", "Meiryo", "MS Gothic", "Microsoft YaHei",
    };
    for (allowed) |a| if (std.mem.eql(u8, a, family)) return;
    std.debug.print("unexpected CJK fallback family: {s}\n", .{family});
    return error.TestUnexpectedResult;
}

test "windows directwrite: emoji presentation is not routed" {
    var lib: Library = try .init(std.testing.allocator);
    defer lib.deinit();
    var dw = DirectWrite.init() orelse return error.SkipZigTest;
    defer dw.deinit();
    var iter = try dw.fallback(std.testing.allocator, lib, null, .{
        .codepoint = 0x1F600,
        .presentation = .emoji,
    });
    defer iter.deinit();
    try std.testing.expect((try iter.next()) == null);
}

const test_codepoints = [_]u32{ 0x3042, 0x6F22, 0xAC00, 0x2603, 0x2211, 0x2318, 0x1F600, 0x0416 };

fn testFallbackWorker(
    dw: *const DirectWrite,
    lib: Library,
    results: *[test_codepoints.len]u64,
) void {
    for (0..200) |i| {
        const cp = test_codepoints[i % test_codepoints.len];
        var iter = dw.fallback(std.heap.page_allocator, lib, null, .{ .codepoint = cp }) catch return;
        defer iter.deinit();
        var h: u64 = 0;
        for (iter.fonts) |f| {
            const loc = (fileLocation(std.heap.page_allocator, f) catch null) orelse continue;
            defer std.heap.page_allocator.free(loc.path);
            h = std.hash.Wyhash.hash(h, loc.path);
        }
        if (i < test_codepoints.len) results[i] = h else if (results[i % test_codepoints.len] != h) {
            results[i % test_codepoints.len] = std.math.maxInt(u64);
        }
    }
}

test "windows directwrite: fallback from two threads" {
    var lib: Library = try .init(std.testing.allocator);
    defer lib.deinit();
    var dw = DirectWrite.init() orelse return error.SkipZigTest;
    defer dw.deinit();

    var a: [test_codepoints.len]u64 = undefined;
    var b: [test_codepoints.len]u64 = undefined;
    var t1 = try std.Thread.spawn(.{}, testFallbackWorker, .{ &dw, lib, &a });
    var t2 = try std.Thread.spawn(.{}, testFallbackWorker, .{ &dw, lib, &b });
    t1.join();
    t2.join();

    // Same fonts on both threads, and stable across the 200 rounds.
    try std.testing.expectEqualSlices(u64, &a, &b);
    for (a) |h| try std.testing.expect(h != std.math.maxInt(u64));
}

test "windows directwrite: iterate all families for +list-fonts" {
    var lib: Library = try .init(std.testing.allocator);
    defer lib.deinit();
    var dw = DirectWrite.init() orelse return error.SkipZigTest;
    defer dw.deinit();
    var iter = try dw.discover(std.testing.allocator, lib, .{});
    defer iter.deinit();

    var count: usize = 0;
    while (count <= 50) : (count += 1) {
        var face = (try iter.next()) orelse break;
        face.deinit();
    }
    try std.testing.expect(count > 50);
}

test "windows directwrite: timings" {
    var lib: Library = try .init(std.testing.allocator);
    defer lib.deinit();
    const io = global.io();

    const t0 = std.Io.Timestamp.now(io, .awake);
    var dw = DirectWrite.init() orelse return error.SkipZigTest;
    defer dw.deinit();
    var first = try dw.discover(std.testing.allocator, lib, .{ .family = "Consolas" });
    var face = (try first.next()) orelse return error.TestUnexpectedResult;
    face.deinit();
    first.deinit();
    const t1 = std.Io.Timestamp.now(io, .awake);

    var total: i96 = 0;
    for (test_codepoints) |cp| {
        const a = std.Io.Timestamp.now(io, .awake);
        var iter = try dw.fallback(std.testing.allocator, lib, null, .{ .codepoint = cp });
        var f = (try iter.next()) orelse {
            iter.deinit();
            continue;
        };
        f.deinit();
        iter.deinit();
        total += a.durationTo(std.Io.Timestamp.now(io, .awake)).toNanoseconds();
    }

    const first_ms = @as(f64, @floatFromInt(t0.durationTo(t1).toNanoseconds())) / 1e6;
    const per_cp_ms = @as(f64, @floatFromInt(total)) / 1e6 / test_codepoints.len;
    if (global.environ().getAlloc(std.testing.allocator, "GHOSTTY_FONT_TIMING")) |v| {
        std.testing.allocator.free(v);
        std.debug.print("directwrite: first discover {d:.1} ms, fallback {d:.2} ms per codepoint\n", .{ first_ms, per_cp_ms });
    } else |_| {}
    try std.testing.expect(first_ms < 1000);
}
