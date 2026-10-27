const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const assert = @import("../quirks.zig").inlineAssert;
const fontconfig = @import("fontconfig");
const freetype = @import("freetype");
const macos = @import("macos");
const opentype = @import("opentype.zig");
const options = @import("main.zig").options;
const Collection = @import("main.zig").Collection;
const DeferredFace = @import("main.zig").DeferredFace;
const Face = @import("main.zig").Face;
const Library = @import("main.zig").Library;
const Presentation = @import("main.zig").Presentation;
const Variation = @import("main.zig").face.Variation;
const WindowsFontFile = @import("WindowsFontFile.zig");
const DirectWrite = if (options.backend == .freetype_windows)
    @import("directwrite.zig").DirectWrite
else
    void;
const global = @import("../global.zig");

const log = std.log.scoped(.discovery);

/// Discover implementation for the compile options.
pub const Discover = switch (options.backend) {
    .freetype => void, // no discovery
    .freetype_windows => Windows,
    .fontconfig_freetype => Fontconfig,
    .web_canvas => void, // no discovery
    .coretext,
    .coretext_freetype,
    .coretext_harfbuzz,
    .coretext_noshape,
    => CoreText,
};

/// Descriptor is used to search for fonts. The only required field
/// is "family". The rest are ignored unless they're set to a non-zero
/// value.
pub const Descriptor = struct {
    /// Font family to search for. This can be a fully qualified font
    /// name such as "Fira Code", "monospace", "serif", etc. Memory is
    /// owned by the caller and should be freed when this descriptor
    /// is no longer in use. The discovery structs will never store the
    /// descriptor.
    ///
    /// On systems that use fontconfig (Linux), this can be a full
    /// fontconfig pattern, such as "Fira Code-14:bold".
    family: ?[:0]const u8 = null,

    /// Specific font style to search for. This will filter the style
    /// string the font advertises. The "bold/italic" booleans later in this
    /// struct filter by the style trait the font has, not the string, so
    /// these can be used in conjunction or not.
    style: ?[:0]const u8 = null,

    /// A codepoint that this font must be able to render.
    codepoint: u32 = 0,

    /// Font size in points that the font should support. For conversion
    /// to pixels, we will use 72 DPI for Mac and 96 DPI for everything else.
    /// (If pixel conversion is necessary, i.e. emoji fonts)
    size: f32 = 0,

    /// True if we want to search specifically for a font that supports
    /// specific styles.
    bold: bool = false,
    italic: bool = false,
    monospace: bool = false,

    /// Variation axes to apply to the font. This also impacts searching
    /// for fonts since fonts with the ability to set these variations
    /// will be preferred, but not guaranteed.
    variations: []const Variation = &.{},

    /// Hash the descriptor with the given hasher.
    pub fn hash(self: Descriptor, hasher: anytype) void {
        const autoHash = std.hash.autoHash;
        const autoHashStrat = std.hash.autoHashStrat;
        autoHashStrat(hasher, self.family, .Deep);
        autoHashStrat(hasher, self.style, .Deep);
        autoHash(hasher, self.codepoint);
        autoHash(hasher, @as(u32, @bitCast(self.size)));
        autoHash(hasher, self.bold);
        autoHash(hasher, self.italic);
        autoHash(hasher, self.monospace);
        autoHash(hasher, self.variations.len);
        for (self.variations) |variation| {
            autoHash(hasher, variation.id);

            // This is not correct, but we don't currently depend on the
            // hash value being different based on decimal values of variations.
            autoHash(hasher, @as(i64, @intFromFloat(variation.value)));
        }
    }

    /// Returns a hash code that can be used to uniquely identify this
    /// action.
    pub fn hashcode(self: Descriptor) u64 {
        var hasher = std.hash.Wyhash.init(0);
        self.hash(&hasher);
        return hasher.final();
    }

    /// Deep copy of the struct. The given allocator is expected to
    /// be an arena allocator of some sort since the descriptor
    /// itself doesn't support fine-grained deallocation of fields.
    pub fn clone(self: *const Descriptor, alloc: Allocator) !Descriptor {
        // We can't do any errdefer cleanup in here. As documented we
        // expect the allocator to be an arena so any errors should be
        // cleaned up somewhere else.

        var copy = self.*;
        copy.family = if (self.family) |src| try alloc.dupeSentinel(u8, src, 0) else null;
        copy.style = if (self.style) |src| try alloc.dupeSentinel(u8, src, 0) else null;
        copy.variations = try alloc.dupe(Variation, self.variations);
        return copy;
    }

    /// Convert to Fontconfig pattern to use for lookup. The pattern does
    /// not have defaults filled/substituted (Fontconfig thing) so callers
    /// must still do this.
    pub fn toFcPattern(self: Descriptor) *fontconfig.Pattern {
        const pat = fontconfig.Pattern.create();
        if (self.family) |family| {
            assert(pat.add(.family, .{ .string = family }, false));
        }
        if (self.style) |style| {
            assert(pat.add(.style, .{ .string = style }, false));
        }
        if (self.codepoint > 0) {
            const cs = fontconfig.CharSet.create();
            defer cs.destroy();
            assert(cs.addChar(self.codepoint));
            assert(pat.add(.charset, .{ .char_set = cs }, false));
        }
        if (self.size > 0) assert(pat.add(
            .size,
            .{ .integer = @intFromFloat(@round(self.size)) },
            false,
        ));
        if (self.bold) assert(pat.add(
            .weight,
            .{ .integer = @backingInt(fontconfig.Weight.bold) },
            false,
        ));
        if (self.italic) assert(pat.add(
            .slant,
            .{ .integer = @backingInt(fontconfig.Slant.italic) },
            false,
        ));

        // For fontconfig, we always add monospace in the pattern. Since
        // fontconfig sorts by closeness to the pattern, this doesn't fully
        // exclude non-monospace but helps prefer it.
        assert(pat.add(
            .spacing,
            .{ .integer = @backingInt(fontconfig.Spacing.mono) },
            false,
        ));

        return pat;
    }

    /// Convert to Core Text font descriptor to use for lookup or
    /// conversion to a specific font.
    pub fn toCoreTextDescriptor(self: Descriptor) !*macos.text.FontDescriptor {
        const attrs = try macos.foundation.MutableDictionary.create(0);
        defer attrs.release();

        // Family
        if (self.family) |family_bytes| {
            const family = try macos.foundation.String.createWithBytes(family_bytes, .utf8, false);
            defer family.release();
            attrs.setValue(
                macos.text.FontAttribute.family_name.key(),
                family,
            );
        }

        // Style
        if (self.style) |style_bytes| {
            const style = try macos.foundation.String.createWithBytes(style_bytes, .utf8, false);
            defer style.release();
            attrs.setValue(
                macos.text.FontAttribute.style_name.key(),
                style,
            );
        }

        // Codepoint support
        if (self.codepoint > 0) {
            const cs = try macos.foundation.CharacterSet.createWithCharactersInRange(.{
                .location = self.codepoint,
                .length = 1,
            });
            defer cs.release();
            attrs.setValue(
                macos.text.FontAttribute.character_set.key(),
                cs,
            );
        }

        // Set our size attribute if set
        if (self.size > 0) {
            const size32: i32 = @intFromFloat(@round(self.size));
            const size = try macos.foundation.Number.create(
                .sint32,
                &size32,
            );
            defer size.release();
            attrs.setValue(
                macos.text.FontAttribute.size.key(),
                size,
            );
        }

        // Build our traits. If we set any, then we store it in the attributes
        // otherwise we do nothing. We determine this by setting up the packed
        // struct, converting to an int, and checking if it is non-zero.
        const traits: macos.text.FontSymbolicTraits = .{
            .bold = self.bold,
            .italic = self.italic,
            .monospace = self.monospace,
        };
        const traits_cval: u32 = @bitCast(traits);
        if (traits_cval > 0) {
            // Setting traits is a pain. We have to create a nested dictionary
            // of the symbolic traits value, and set that in our attributes.
            const traits_num = try macos.foundation.Number.create(
                .sint32,
                @as(*const i32, @ptrCast(&traits_cval)),
            );
            defer traits_num.release();

            const traits_dict = try macos.foundation.MutableDictionary.create(0);
            defer traits_dict.release();
            traits_dict.setValue(
                macos.text.FontTraitKey.symbolic.key(),
                traits_num,
            );

            attrs.setValue(
                macos.text.FontAttribute.traits.key(),
                traits_dict,
            );
        }

        return try macos.text.FontDescriptor.createWithAttributes(@ptrCast(attrs));
    }
};

pub const Fontconfig = struct {
    fc_config: *fontconfig.Config,

    pub fn init(lib: Library) Fontconfig {
        _ = lib;
        // safe to call multiple times and concurrently
        _ = fontconfig.init();
        return .{ .fc_config = fontconfig.initLoadConfigAndFonts() };
    }

    pub fn deinit(self: *Fontconfig) void {
        self.fc_config.destroy();
    }

    /// Discover fonts from a descriptor. This returns an iterator that can
    /// be used to build up the deferred fonts.
    pub fn discover(
        self: *const Fontconfig,
        alloc: Allocator,
        desc: Descriptor,
    ) !DiscoverIterator {
        _ = alloc;

        // Build our pattern that we'll search for
        const pat = desc.toFcPattern();
        errdefer pat.destroy();
        assert(self.fc_config.substituteWithPat(pat, .pattern));
        pat.defaultSubstitute();

        // Search
        const res = self.fc_config.fontSort(pat, false, null);
        if (res.result != .match) return error.FontConfigFailed;
        errdefer res.fs.destroy();

        return .{
            .config = self.fc_config,
            .pattern = pat,
            .set = res.fs,
            .fonts = res.fs.fonts(),
            .variations = desc.variations,
            .i = 0,
        };
    }

    pub fn discoverFallback(
        self: *const Fontconfig,
        alloc: Allocator,
        collection: *Collection,
        desc: Descriptor,
    ) !DiscoverIterator {
        _ = collection;
        return try self.discover(alloc, desc);
    }

    pub const DiscoverIterator = struct {
        config: *fontconfig.Config,
        pattern: *fontconfig.Pattern,
        set: *fontconfig.FontSet,
        fonts: []*fontconfig.Pattern,
        variations: []const Variation,
        i: usize,

        pub fn deinit(self: *DiscoverIterator) void {
            self.set.destroy();
            self.pattern.destroy();
            self.* = undefined;
        }

        pub fn next(self: *DiscoverIterator) fontconfig.Error!?DeferredFace {
            if (self.i >= self.fonts.len) return null;

            // Get the copied pattern from our fontset that has the
            // attributes configured for rendering.
            const font_pattern = try self.config.fontRenderPrepare(
                self.pattern,
                self.fonts[self.i],
            );
            errdefer font_pattern.destroy();

            // Increment after we return
            defer self.i += 1;

            return DeferredFace{
                .fc = .{
                    .pattern = font_pattern,
                    .charset = (try font_pattern.get(.charset, 0)).char_set,
                    .langset = (try font_pattern.get(.lang, 0)).lang_set,
                    .variations = self.variations,
                },
            };
        }
    };
};

pub const CoreText = struct {
    pub fn init(lib: Library) CoreText {
        _ = lib;
        // Required for the "interface" but does nothing for CoreText.
        return .{};
    }

    pub fn deinit(self: *CoreText) void {
        _ = self;
    }

    /// Warm up the system font registry.
    ///
    /// The first CoreText query in a process initializes the system font
    /// database, which takes multiple milliseconds, while subsequent
    /// queries are microseconds.
    pub fn warmup() void {
        const name = macos.foundation.String.createWithBytes(
            "AppleColorEmoji",
            .utf8,
            false,
        ) catch return;
        defer name.release();
        const ct_font = macos.text.Font.createWithName(name, 12) catch return;
        ct_font.release();
    }

    /// Discover fonts from a descriptor. This returns an iterator that can
    /// be used to build up the deferred fonts.
    pub fn discover(self: *const CoreText, alloc: Allocator, desc: Descriptor) !DiscoverIterator {
        _ = self;

        // Build our pattern that we'll search for
        const ct_desc = try desc.toCoreTextDescriptor();
        defer ct_desc.release();

        // Our descriptors have to be in an array
        var ct_desc_arr = [_]*const macos.text.FontDescriptor{ct_desc};
        const desc_arr = try macos.foundation.Array.create(macos.text.FontDescriptor, &ct_desc_arr);
        defer desc_arr.release();

        // Build our collection
        const set = try macos.text.FontCollection.createWithFontDescriptors(desc_arr);
        defer set.release();
        const list = set.createMatchingFontDescriptors();
        defer list.release();

        // Sort our descriptors
        const zig_list = try copyMatchingDescriptors(alloc, list);
        errdefer alloc.free(zig_list);
        sortMatchingDescriptors(&desc, zig_list);

        return DiscoverIterator{
            .alloc = alloc,
            .list = zig_list,
            .variations = desc.variations,
            .i = 0,
        };
    }

    /// Discover a font by its exact name (family, full, or PostScript
    /// name). This is significantly faster than `discover` because it
    /// avoids the system-wide font matching that CTFontCollection does
    /// (which takes multiple milliseconds). This should be preferred
    /// when the desired font is known exactly, e.g. system fonts such
    /// as Apple Color Emoji.
    ///
    /// Returns null if no font with this exact family name exists;
    /// CoreText fallback fonts are never returned.
    pub fn discoverExactFamily(
        self: *const CoreText,
        family: []const u8,
    ) !?DeferredFace {
        _ = self;

        const family_str = try macos.foundation.String.createWithBytes(
            family,
            .utf8,
            false,
        );
        defer family_str.release();

        // Create our font. We need a size to initialize it so we use size
        // 12 but we will alter the size later (same as DiscoverIterator).
        const ct_font = try macos.text.Font.createWithName(family_str, 12);

        // CTFontCreateWithName never returns null: if the requested font
        // isn't installed it returns a substitute font. Verify we got
        // the family we asked for, otherwise report not found.
        const found: bool = found: {
            const actual = ct_font.copyFamilyName();
            defer actual.release();
            var buf: [256]u8 = undefined;
            const actual_slice = actual.cstring(&buf, .utf8) orelse
                break :found false;
            break :found std.mem.eql(u8, actual_slice, family);
        };
        if (!found) {
            ct_font.release();
            return null;
        }

        return .{ .ct = .{
            .font = ct_font,
            .variations = &.{},
        } };
    }

    pub fn discoverFallback(
        self: *const CoreText,
        alloc: Allocator,
        collection: *Collection,
        desc: Descriptor,
    ) !DiscoverIterator {
        // If we have a codepoint within the CJK unified ideographs block
        // then we fallback to macOS to find a font that supports it because
        // there isn't a better way manually with CoreText that I can find that
        // properly takes into account system locale.
        //
        // References:
        // - http://unicode.org/charts/PDF/U4E00.pdf
        // - https://chromium.googlesource.com/chromium/src/+/main/third_party/blink/renderer/platform/fonts/LocaleInFonts.md#unified-han-ideographs
        if (desc.codepoint >= 0x4E00 and
            desc.codepoint <= 0x9FFF)
        han: {
            const han = try self.discoverCodepoint(
                collection,
                desc,
            ) orelse break :han;

            // This is silly but our discover iterator needs a slice so
            // we allocate here. This isn't a performance bottleneck but
            // this is something we can optimize very easily...
            const list = try alloc.alloc(*macos.text.FontDescriptor, 1);
            errdefer alloc.free(list);
            list[0] = han;

            return DiscoverIterator{
                .alloc = alloc,
                .list = list,
                .variations = desc.variations,
                .i = 0,
            };
        }

        const it = try self.discover(alloc, desc);

        // If our normal discovery doesn't find anything and we have a specific
        // codepoint, then fallback to using CTFontCreateForString to find a
        // matching font CoreText wants to use. See:
        // https://github.com/ghostty-org/ghostty/issues/2499
        if (it.list.len == 0 and desc.codepoint > 0) codepoint: {
            const ct_desc = try self.discoverCodepoint(
                collection,
                desc,
            ) orelse break :codepoint;

            const list = try alloc.alloc(*macos.text.FontDescriptor, 1);
            errdefer alloc.free(list);
            list[0] = ct_desc;

            return DiscoverIterator{
                .alloc = alloc,
                .list = list,
                .variations = desc.variations,
                .i = 0,
            };
        }

        return it;
    }

    /// Discover a font for a specific codepoint using the CoreText
    /// CTFontCreateForString API.
    fn discoverCodepoint(
        self: *const CoreText,
        collection: *Collection,
        desc: Descriptor,
    ) !?*macos.text.FontDescriptor {
        _ = self;

        if (comptime options.backend.hasFreetype()) {
            // If we have freetype, we can't use CoreText to find a font
            // that supports a specific codepoint because we need to
            // have a CoreText font to be able to do so.
            return null;
        }

        assert(desc.codepoint > 0);

        // Get our original font. This is dependent on the requested style
        // from the descriptor.
        const original = original: {
            // In all the styles below, we try to match it but if we don't
            // we always fall back to some other option. The order matters
            // here.

            if (desc.bold and desc.italic) {
                const entries = collection.faces.get(.bold_italic);
                if (entries.count() > 0) {
                    break :original try collection.getFace(.{ .style = .bold_italic });
                }
            }

            if (desc.bold) {
                const entries = collection.faces.get(.bold);
                if (entries.count() > 0) {
                    break :original try collection.getFace(.{ .style = .bold });
                }
            }

            if (desc.italic) {
                const entries = collection.faces.get(.italic);
                if (entries.count() > 0) {
                    break :original try collection.getFace(.{ .style = .italic });
                }
            }

            break :original try collection.getFace(.{ .style = .regular });
        };

        // We need it in utf8 format
        var buf: [4]u8 = undefined;
        const len = try std.unicode.utf8Encode(
            @intCast(desc.codepoint),
            &buf,
        );

        // We need a CFString
        const str = try macos.foundation.String.createWithBytes(
            buf[0..len],
            .utf8,
            false,
        );
        defer str.release();

        // Get our range length for CTFontCreateForString. It looks like
        // the range uses UTF-16 codepoints and not UTF-32 codepoints.
        const range_len: usize = range_len: {
            var unichars: [2]u16 = undefined;
            const pair = macos.foundation.stringGetSurrogatePairForLongCharacter(
                desc.codepoint,
                &unichars,
            );
            break :range_len if (pair) 2 else 1;
        };

        // Get our font
        const font = original.font.createForString(
            str,
            macos.foundation.Range.init(0, range_len),
        ) orelse return null;
        defer font.release();

        // Do not allow the last resort font to go through. This is the
        // last font used by CoreText if it can't find anything else and
        // only contains replacement characters.
        last_resort: {
            const name_str = font.copyPostScriptName();
            defer name_str.release();

            // If the name doesn't fit in our buffer, then it can't
            // be the last resort font so we break out.
            var name_buf: [64]u8 = undefined;
            const name: []const u8 = name_str.cstring(&name_buf, .utf8) orelse
                break :last_resort;

            // If the name is "LastResort" then we don't want to use it.
            if (std.mem.eql(u8, "LastResort", name)) return null;
        }

        // Get the descriptor
        return font.copyDescriptor();
    }

    fn copyMatchingDescriptors(
        alloc: Allocator,
        list: *macos.foundation.Array,
    ) ![]*macos.text.FontDescriptor {
        var result = try alloc.alloc(*macos.text.FontDescriptor, list.getCount());
        errdefer alloc.free(result);
        for (0..result.len) |i| {
            result[i] = list.getValueAtIndex(macos.text.FontDescriptor, i);

            // We need to retain because once the list is freed it will
            // release all its members.
            result[i].retain();
        }
        return result;
    }

    fn sortMatchingDescriptors(
        desc: *const Descriptor,
        list: []*macos.text.FontDescriptor,
    ) void {
        std.mem.sortUnstable(*macos.text.FontDescriptor, list, desc, struct {
            fn lessThan(
                desc_inner: *const Descriptor,
                lhs: *macos.text.FontDescriptor,
                rhs: *macos.text.FontDescriptor,
            ) bool {
                const lhs_score: Score = .score(desc_inner, lhs);
                const rhs_score: Score = .score(desc_inner, rhs);
                // Higher score is "less" (earlier)
                return lhs_score.int() > rhs_score.int();
            }
        }.lessThan);
    }

    /// We represent our sorting score as a packed struct so that we
    /// can compare scores numerically but build scores symbolically.
    ///
    /// Note that packed structs store their fields from least to most
    /// significant, so the fields here are defined in increasing order
    /// of precedence.
    const Score = packed struct {
        const Backing = @typeInfo(@This()).@"struct".backing_integer.?;

        /// Number of glyphs in the font, if two fonts have identical
        /// scores otherwise then we prefer the one with more glyphs.
        ///
        /// (Number of glyphs clamped at u16 intmax)
        glyph_count: u16 = 0,
        /// A fuzzy match on the style string, less important than
        /// an exact match, and less important than trait matches.
        fuzzy_style: u8 = 0,
        /// Whether the bold-ness of the font matches the descriptor.
        /// This is less important than italic because a font that's italic
        /// when it shouldn't be or not italic when it should be is a bigger
        /// problem (subjectively) than being the wrong weight.
        bold: bool = false,
        /// Whether the italic-ness of the font matches the descriptor.
        /// This is less important than an exact match on the style string
        /// because we want users to be allowed to override trait matching
        /// for the bold/italic/bold italic styles if they want.
        italic: bool = false,
        /// An exact (case-insensitive) match on the style string.
        exact_style: bool = false,
        /// Whether the font is monospace, this is more important than any of
        /// the other fields unless we're looking for a specific codepoint,
        /// in which case that is the most important thing.
        monospace: bool = false,
        /// If we're looking for a codepoint, whether this font has it.
        codepoint: bool = false,

        pub fn int(self: Score) Backing {
            return @bitCast(self);
        }

        fn score(desc: *const Descriptor, ct_desc: *const macos.text.FontDescriptor) Score {
            var self: Score = .{};

            // We always load the font if we can since some things can only be
            // inspected on the font itself. Fonts that can't be loaded score
            // 0 automatically because we don't want a font we can't load.
            const font: *macos.text.Font = macos.text.Font.createWithFontDescriptor(
                ct_desc,
                12,
            ) catch return self;
            defer font.release();

            // We prefer fonts with more glyphs, all else being equal.
            {
                const Type = @TypeOf(self.glyph_count);
                self.glyph_count = std.math.cast(
                    Type,
                    font.getGlyphCount(),
                ) orelse std.math.maxInt(Type);
            }

            // If we're searching for a codepoint, then we
            // prioritize fonts that have that codepoint.
            if (desc.codepoint > 0) {
                // Turn UTF-32 into UTF-16 for CT API
                var unichars: [2]u16 = undefined;
                const pair = macos.foundation.stringGetSurrogatePairForLongCharacter(
                    desc.codepoint,
                    &unichars,
                );
                const len: usize = if (pair) 2 else 1;

                // Get our glyphs
                var glyphs = [2]macos.graphics.Glyph{ 0, 0 };
                self.codepoint = font.getGlyphsForCharacters(
                    unichars[0..len],
                    glyphs[0..len],
                );
            }

            // Get our symbolic traits for the descriptor so we can
            // compare boolean attributes like bold, monospace, etc.
            const symbolic_traits: macos.text.FontSymbolicTraits = traits: {
                const traits = ct_desc.copyAttribute(.traits) orelse break :traits .{};
                defer traits.release();

                const key = macos.text.FontTraitKey.symbolic.key();
                const symbolic = traits.getValue(macos.foundation.Number, key) orelse
                    break :traits .{};

                break :traits macos.text.FontSymbolicTraits.init(symbolic);
            };

            self.monospace = symbolic_traits.monospace;

            // We try to derived data from the font itself, which is generally
            // more reliable than only using the symbolic traits for this.
            const is_bold: bool, const is_italic: bool = derived: {
                // We start with initial guesses based on the symbolic traits,
                // but refine these with more information if we can get it.
                var is_italic = symbolic_traits.italic;
                var is_bold = symbolic_traits.bold;

                // Read the 'head' table out of the font data if it's available.
                if (head: {
                    const tag = macos.text.FontTableTag.init("head");
                    const data = font.copyTable(tag) orelse break :head null;
                    defer data.release();
                    const ptr = data.getPointer();
                    const len = data.getLength();
                    break :head opentype.Head.init(ptr[0..len]) catch |err| {
                        log.warn("error parsing head table: {}", .{err});
                        break :head null;
                    };
                }) |head_| {
                    const head: opentype.Head = head_;
                    is_bold = is_bold or (head.macStyle & 1 == 1);
                    is_italic = is_italic or (head.macStyle & 2 == 2);
                }

                // Read the 'OS/2' table out of the font data if it's available.
                if (os2: {
                    const tag = macos.text.FontTableTag.init("OS/2");
                    const data = font.copyTable(tag) orelse break :os2 null;
                    defer data.release();
                    const ptr = data.getPointer();
                    const len = data.getLength();
                    break :os2 opentype.OS2.init(ptr[0..len]) catch |err| {
                        log.warn("error parsing OS/2 table: {}", .{err});
                        break :os2 null;
                    };
                }) |os2| {
                    is_bold = is_bold or os2.fsSelection.bold;
                    is_italic = is_italic or os2.fsSelection.italic;
                }

                // Check if we have variation axes in our descriptor, if we
                // do then we can derive weight italic-ness or both from them.
                if (font.copyAttribute(.variation_axes)) |axes| variations: {
                    defer axes.release();

                    // Copy the variation values for this instance of the font.
                    // if there are none then we just break out immediately.
                    const values: *macos.foundation.Dictionary =
                        font.copyAttribute(.variation) orelse break :variations;
                    defer values.release();

                    var buf: [1024]u8 = undefined;

                    // If we see the 'ital' value then we ignore 'slnt'.
                    var ital_seen = false;

                    const len = axes.getCount();
                    for (0..len) |i| {
                        const dict = axes.getValueAtIndex(macos.foundation.Dictionary, i);
                        const Key = macos.text.FontVariationAxisKey;
                        const cf_id = dict.getValue(Key.identifier.Value(), Key.identifier.key()).?;
                        const cf_name = dict.getValue(Key.name.Value(), Key.name.key()).?;
                        const cf_def = dict.getValue(Key.default_value.Value(), Key.default_value.key()).?;

                        const name_str = cf_name.cstring(&buf, .utf8) orelse "";

                        // Default value
                        var def: f64 = 0;
                        _ = cf_def.getValue(.double, &def);
                        // Value in this font
                        var val: f64 = def;
                        if (values.getValue(
                            macos.foundation.Number,
                            cf_id,
                        )) |cf_val| _ = cf_val.getValue(.double, &val);

                        if (std.mem.eql(u8, "wght", name_str)) {
                            // Somewhat subjective threshold, we consider fonts
                            // bold if they have a 'wght' set greater than 600.
                            is_bold = val > 600;
                            continue;
                        }
                        if (std.mem.eql(u8, "ital", name_str)) {
                            is_italic = val > 0.5;
                            ital_seen = true;
                            continue;
                        }
                        if (!ital_seen and std.mem.eql(u8, "slnt", name_str)) {
                            // Arbitrary threshold of anything more than a 5
                            // degree clockwise slant is considered italic.
                            is_italic = val <= -5.0;
                            continue;
                        }
                    }
                }

                break :derived .{ is_bold, is_italic };
            };

            self.bold = desc.bold == is_bold;
            self.italic = desc.italic == is_italic;

            // Get the style string from the font.
            var style_str_buf: [128]u8 = undefined;
            const style_str: []const u8 = style_str: {
                const style = ct_desc.copyAttribute(.style_name) orelse
                    break :style_str "";
                defer style.release();

                break :style_str style.cstring(&style_str_buf, .utf8) orelse "";
            };

            // The first string in this slice will be used for the exact match,
            // and for the fuzzy match, all matching substrings will increase
            // the rank.
            const desired_styles: []const [:0]const u8 = desired: {
                if (desc.style) |s| break :desired &.{s};

                // If we don't have an explicitly desired style name, we base
                // it on the bold and italic properties, this isn't ideal since
                // fonts may use style names other than these, but it helps in
                // some edge cases.
                if (desc.bold) {
                    if (desc.italic) break :desired &.{ "bold italic", "bold", "italic", "oblique" };
                    break :desired &.{ "bold", "upright" };
                } else if (desc.italic) {
                    break :desired &.{ "italic", "regular", "oblique" };
                }
                break :desired &.{ "regular", "upright" };
            };

            self.exact_style = std.ascii.eqlIgnoreCase(
                style_str,
                desired_styles[0],
            );
            // Our "fuzzy match" score is 0 if the desired style isn't present
            // in the string, otherwise we give higher priority for styles that
            // have fewer characters not in the desired_styles list.
            const fuzzy_type = @TypeOf(self.fuzzy_style);
            self.fuzzy_style = @intCast(style_str.len);
            for (desired_styles) |s| {
                if (std.ascii.findIgnoreCase(style_str, s) != null) {
                    self.fuzzy_style -|= @intCast(s.len);
                }
            }
            self.fuzzy_style = std.math.maxInt(fuzzy_type) -| self.fuzzy_style;

            return self;
        }
    };

    pub const DiscoverIterator = struct {
        alloc: Allocator,
        list: []const *macos.text.FontDescriptor,
        variations: []const Variation,
        i: usize,

        pub fn deinit(self: *DiscoverIterator) void {
            for (self.list) |desc| {
                desc.release();
            }
            self.alloc.free(self.list);
            self.* = undefined;
        }

        pub fn next(self: *DiscoverIterator) !?DeferredFace {
            if (self.i >= self.list.len) return null;

            // Get our descriptor. We need to remove the character set
            // limitation because we may have used that to filter but we
            // don't want it anymore because it'll restrict the characters
            // available.
            const desc = desc: {
                // We create a copy, overwriting the character set attribute.
                const attrs = try macos.foundation.MutableDictionary.create(0);
                defer attrs.release();

                attrs.setValue(
                    macos.text.FontAttribute.character_set.key(),
                    macos.c.kCFNull,
                );

                break :desc try macos.text.FontDescriptor.createCopyWithAttributes(
                    self.list[self.i],
                    @ptrCast(attrs),
                );
            };
            defer desc.release();

            // Create our font. We need a size to initialize it so we use size
            // 12 but we will alter the size later.
            const font = try macos.text.Font.createWithFontDescriptor(desc, 12);
            errdefer font.release();

            // Increment after we return
            defer self.i += 1;

            return DeferredFace{
                .ct = .{
                    .font = font,
                    .variations = self.variations,
                },
            };
        }
    };
};

/// Windows font discovery. DirectWrite resolves families, styles and
/// `MapCharacters` fallback to font files; the files are opened with
/// FreeType through a UTF-16 mapped view.
///
/// If DirectWrite cannot be initialized, a process-wide index of the
/// system and per-user font files (family, style, OS/2 weight, italic,
/// monospace, path, face index) is built once on first use by opening each
/// file with FreeType. Queries then filter and rank that index instead of
/// touching the disk; only the candidates that are actually returned (or
/// probed for a codepoint) are opened.
pub const Windows = struct {
    lib: Library,

    /// Null when DirectWrite is unusable; the file index is used instead.
    dw: ?DirectWrite,

    /// Families tried first by `discoverFallback`, in order (SPEC section 9).
    const fallback_families = [_][]const u8{
        "Segoe UI Emoji",
        "Segoe UI Symbol",
        "Cascadia Mono",
        "Consolas",
        "Yu Gothic",
        "Malgun Gothic",
        "Microsoft YaHei",
        "SimSun",
    };

    pub fn init(lib: Library) Windows {
        return .{ .lib = lib, .dw = DirectWrite.init() };
    }

    pub fn deinit(self: *Windows) void {
        if (self.dw) |*dw| dw.deinit();
    }

    pub fn discover(
        self: *const Windows,
        alloc: Allocator,
        desc: Descriptor,
    ) !DiscoverIterator {
        if (self.dw) |dw| return .{ .dw = .{
            .stages = .{ try dw.discover(alloc, self.lib, desc), null, null },
        } };

        const index = try Index.get(self.lib);
        return .{ .index = try IndexIterator.init(self.lib, alloc, index, desc, false) };
    }

    /// Like `discover`, but when no family is requested the system's
    /// `MapCharacters` choice comes first, then the fixed list of
    /// well-known fallback families.
    pub fn discoverFallback(
        self: *const Windows,
        alloc: Allocator,
        collection: *Collection,
        desc: Descriptor,
    ) !DiscoverIterator {
        if (self.dw) |dw| {
            if (desc.family != null) return self.discover(alloc, desc);

            // The system's choice, then the well-known families, then any
            // installed face that covers the codepoint (user fonts).
            var buf: [256]u8 = undefined;
            var first = try dw.fallback(alloc, self.lib, primaryFamily(collection, &buf), desc);
            errdefer first.deinit();
            var second = try dw.discoverFamilies(alloc, self.lib, &fallback_families, desc);
            errdefer second.deinit();
            var walk_desc = desc;
            walk_desc.monospace = false;
            const third = try dw.walk(alloc, self.lib, walk_desc);
            return .{ .dw = .{ .stages = .{ first, second, third } } };
        }

        const index = try Index.get(self.lib);
        return .{ .index = try IndexIterator.init(
            self.lib,
            alloc,
            index,
            desc,
            desc.family == null,
        ) };
    }

    /// Family name of the primary regular face, a hint for the system
    /// fallback. Null for an empty collection.
    fn primaryFamily(collection: *Collection, buf: []u8) ?[]const u8 {
        const entry = collection.getEntry(.{}) catch return null;
        return switch (entry.face) {
            .deferred => |d| d.familyName(buf),
            .loaded => |*face| face.name(buf),
        } catch null;
    }

    /// One face of one font file.
    const Entry = struct {
        /// FreeType's family name (the typographic family when the font
        /// has one, e.g. "Segoe UI" for "Segoe UI Semibold").
        family: [:0]const u8,

        /// The legacy (name ID 1) family, if it differs from `family`.
        legacy_family: ?[:0]const u8,

        style: [:0]const u8,

        /// OS/2 usWeightClass (400 regular, 700 bold).
        weight: u16,
        italic: bool,
        monospace: bool,

        path: [:0]const u8,
        face_index: i32,

        fn matchesFamily(self: Entry, family: []const u8) bool {
            if (std.ascii.eqlIgnoreCase(self.family, family)) return true;
            const legacy = self.legacy_family orelse return false;
            return std.ascii.eqlIgnoreCase(legacy, family);
        }
    };

    /// The process-wide font index. Immutable once built and never freed.
    const Index = struct {
        arena: std.heap.ArenaAllocator,
        entries: []const Entry,

        var mutex: std.Io.Mutex = .init;
        var instance: ?Index = null;

        /// How many times the index was built. Tests assert this stays 1.
        var builds: u32 = 0;

        fn get(lib: Library) !*const Index {
            mutex.lockUncancelable(global.io());
            defer mutex.unlock(global.io());
            if (instance) |*i| return i;
            instance = try build(lib);
            builds += 1;
            return &instance.?;
        }

        fn build(lib: Library) !Index {
            var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
            errdefer arena.deinit();

            var entries: std.ArrayList(Entry) = .empty;

            const dirs = [_]struct { env: [:0]const u8, suffix: []const u8 }{
                .{ .env = "SYSTEMROOT", .suffix = "\\Fonts" },
                .{ .env = "LOCALAPPDATA", .suffix = "\\Microsoft\\Windows\\Fonts" },
            };
            for (dirs) |d| {
                const base = global.environ().getAlloc(
                    std.heap.page_allocator,
                    d.env,
                ) catch continue;
                defer std.heap.page_allocator.free(base);
                const dir_path = std.fmt.allocPrint(
                    std.heap.page_allocator,
                    "{s}{s}",
                    .{ base, d.suffix },
                ) catch continue;
                defer std.heap.page_allocator.free(dir_path);
                try scanDir(lib, arena.allocator(), &entries, dir_path);
            }

            // Directory order is unspecified; keep ties deterministic.
            std.sort.block(Entry, entries.items, {}, struct {
                fn lessThan(_: void, a: Entry, b: Entry) bool {
                    const order = std.ascii.orderIgnoreCase(a.path, b.path);
                    if (order != .eq) return order == .lt;
                    return a.face_index < b.face_index;
                }
            }.lessThan);

            log.debug("windows font index: {} faces", .{entries.items.len});
            return .{ .arena = arena, .entries = entries.items };
        }

        fn scanDir(
            lib: Library,
            alloc: Allocator,
            entries: *std.ArrayList(Entry),
            dir_path: []const u8,
        ) !void {
            var dir = std.Io.Dir.openDirAbsolute(
                global.io(),
                dir_path,
                .{ .iterate = true },
            ) catch return;
            defer dir.close(global.io());

            var it = dir.iterate();
            while (it.next(global.io()) catch null) |entry| {
                if (entry.kind != .file) continue;
                if (!isFontFile(entry.name)) continue;
                const path = try std.fmt.allocPrintSentinel(
                    alloc,
                    "{s}\\{s}",
                    .{ dir_path, entry.name },
                    0,
                );
                try addFile(lib, alloc, entries, path);
            }
        }

        /// Index every face of one file. Unreadable fonts are skipped.
        fn addFile(
            lib: Library,
            alloc: Allocator,
            entries: *std.ArrayList(Entry),
            path: [:0]const u8,
        ) !void {
            var file = WindowsFontFile.open(path) catch return;
            defer file.close();

            var face_index: i32 = 0;
            var num_faces: i32 = 1;
            while (face_index < @min(num_faces, max_faces_per_file)) : (face_index += 1) {
                lib.mutex.lockUncancelable(global.io());
                defer lib.mutex.unlock(global.io());

                const ft = lib.lib.initMemoryFace(file.bytes(), face_index) catch continue;
                defer ft.deinit();
                if (face_index == 0) {
                    num_faces = std.math.cast(i32, ft.handle.*.num_faces) orelse 1;
                }
                const entry = try makeEntry(alloc, ft, path, face_index) orelse continue;
                try entries.append(alloc, entry);
            }
        }

        fn makeEntry(
            alloc: Allocator,
            ft: freetype.Face,
            path: [:0]const u8,
            face_index: i32,
        ) !?Entry {
            const handle = ft.handle.*;
            const family_ptr = handle.family_name orelse return null;
            const family = try alloc.dupeSentinel(u8, std.mem.span(family_ptr), 0);
            const style = if (handle.style_name) |s|
                try alloc.dupeSentinel(u8, std.mem.span(s), 0)
            else
                try alloc.dupeSentinel(u8, "", 0);

            const os2 = ft.getSfntTable(.os2);
            var weight: u16 = if (os2) |o| o.usWeightClass else 0;
            if (weight == 0) {
                weight = if (handle.style_flags & freetype.c.FT_STYLE_FLAG_BOLD != 0) 700 else 400;
            }

            // fsSelection bit 0 is italic, bit 9 is oblique.
            const italic = handle.style_flags & freetype.c.FT_STYLE_FLAG_ITALIC != 0 or
                (if (os2) |o| o.fsSelection & ((1 << 0) | (1 << 9)) != 0 else false);

            var legacy = try legacyFamily(alloc, ft);
            if (legacy) |l| {
                if (std.ascii.eqlIgnoreCase(l, family)) {
                    alloc.free(l);
                    legacy = null;
                }
            }

            return .{
                .family = family,
                .legacy_family = legacy,
                .style = style,
                .weight = weight,
                .italic = italic,
                .monospace = handle.face_flags & freetype.c.FT_FACE_FLAG_FIXED_WIDTH != 0,
                .path = path,
                .face_index = face_index,
            };
        }

        /// The SFNT name ID 1 family from the Microsoft platform records,
        /// preferring US English.
        fn legacyFamily(alloc: Allocator, ft: freetype.Face) !?[:0]const u8 {
            var found: ?freetype.c.FT_SfntName = null;
            for (0..ft.getSfntNameCount()) |i| {
                const name = ft.getSfntName(i) catch continue;
                if (name.name_id != freetype.c.TT_NAME_ID_FONT_FAMILY) continue;
                if (name.platform_id != freetype.c.TT_PLATFORM_MICROSOFT) continue;
                if (name.encoding_id != freetype.c.TT_MS_ID_UNICODE_CS) continue;
                if (found == null) found = name;
                if (name.language_id == 0x409) {
                    found = name;
                    break;
                }
            }

            const name = found orelse return null;
            const raw = name.string[0..name.string_len];
            var utf16: [256]u16 = undefined;
            const units = raw.len / 2;
            if (units == 0 or units > utf16.len) return null;
            for (0..units) |i| {
                utf16[i] = std.mem.readInt(u16, raw[i * 2 ..][0..2], .big);
            }
            var utf8: [1024]u8 = undefined;
            const len = std.unicode.utf16LeToUtf8(&utf8, utf16[0..units]) catch return null;
            return try alloc.dupeSentinel(u8, utf8[0..len], 0);
        }
    };

    /// Upper bound on faces indexed from a single collection file.
    const max_faces_per_file = 64;

    /// The faces found by `discover` and `discoverFallback`.
    pub const DiscoverIterator = union(enum) {
        index: IndexIterator,
        dw: DirectWriteIterator,

        pub fn deinit(self: *DiscoverIterator) void {
            switch (self.*) {
                inline else => |*it| it.deinit(),
            }
        }

        pub fn next(self: *DiscoverIterator) !?DeferredFace {
            return switch (self.*) {
                inline else => |*it| try it.next(),
            };
        }
    };

    /// DirectWrite result lists read one after the other.
    const DirectWriteIterator = struct {
        stages: [3]?DirectWrite.Iterator,
        pos: usize = 0,

        fn deinit(self: *DirectWriteIterator) void {
            for (&self.stages) |*s| if (s.*) |*it| it.deinit();
        }

        fn next(self: *DirectWriteIterator) !?DeferredFace {
            while (self.pos < self.stages.len) : (self.pos += 1) {
                const it = if (self.stages[self.pos]) |*it| it else continue;
                if (try it.next()) |face| return face;
            }
            return null;
        }
    };

    const IndexIterator = struct {
        lib: Library,
        alloc: Allocator,
        index: *const Index,
        codepoint: u32,
        variations: []const Variation,

        /// Indexes into `index.entries` in the order they are returned.
        order: []u32,
        pos: usize = 0,

        fn init(
            lib: Library,
            alloc: Allocator,
            index: *const Index,
            desc: Descriptor,
            fallback: bool,
        ) !IndexIterator {
            var order: std.ArrayList(u32) = .empty;
            errdefer order.deinit(alloc);

            const rank: Rank = .{ .desc = desc, .entries = index.entries };
            for (index.entries, 0..) |entry, i| {
                if (rank.accepts(entry)) try order.append(alloc, @intCast(i));
            }
            std.sort.block(u32, order.items, rank, Rank.lessThan);

            if (fallback) try promoteFallbacks(alloc, index, &order);

            return .{
                .lib = lib,
                .alloc = alloc,
                .index = index,
                .codepoint = desc.codepoint,
                .variations = desc.variations,
                .order = try order.toOwnedSlice(alloc),
            };
        }

        /// Stable-move the entries of the well-known fallback families to
        /// the front, in list order.
        fn promoteFallbacks(
            alloc: Allocator,
            index: *const Index,
            order: *std.ArrayList(u32),
        ) !void {
            var result: std.ArrayList(u32) = try .initCapacity(alloc, order.items.len);
            errdefer result.deinit(alloc);
            const taken = try alloc.alloc(bool, order.items.len);
            defer alloc.free(taken);
            @memset(taken, false);

            for (fallback_families) |family| {
                for (order.items, 0..) |i, pos| {
                    if (taken[pos]) continue;
                    if (!index.entries[i].matchesFamily(family)) continue;
                    taken[pos] = true;
                    result.appendAssumeCapacity(i);
                }
            }
            for (order.items, 0..) |i, pos| {
                if (!taken[pos]) result.appendAssumeCapacity(i);
            }

            order.deinit(alloc);
            order.* = result;
        }

        pub fn deinit(self: *IndexIterator) void {
            self.alloc.free(self.order);
            self.* = undefined;
        }

        pub fn next(self: *IndexIterator) !?DeferredFace {
            while (self.pos < self.order.len) {
                const entry = self.index.entries[self.order[self.pos]];
                self.pos += 1;
                if (try self.open(entry)) |face| return face;
            }
            return null;
        }

        /// Open a candidate and check that it covers the requested
        /// codepoint. Files that vanished or fail to parse are skipped.
        fn open(self: *IndexIterator, entry: Entry) !?DeferredFace {
            const file = WindowsFontFile.open(entry.path) catch return null;
            var face = Face.initMapped(
                self.lib,
                file,
                entry.face_index,
                .{ .size = .{ .points = 12 } },
            ) catch return null;
            errdefer face.deinit();

            if (self.codepoint != 0 and face.glyphIndex(self.codepoint) == null) {
                face.deinit();
                return null;
            }

            const path_owned = try self.alloc.dupeSentinel(u8, entry.path, 0);
            errdefer self.alloc.free(path_owned);

            return .{ .win = .{
                .path = path_owned,
                .face_index = entry.face_index,
                .variations = self.variations,
                .peek = face,
                .presentation = if (face.hasColor()) .emoji else .text,
                .alloc = self.alloc,
            } };
        }
    };

    /// Filter and ordering for a descriptor: an exact style name match
    /// first, then the closest weight, then the requested slant, then
    /// monospace.
    const Rank = struct {
        desc: Descriptor,
        entries: []const Entry,

        fn accepts(self: Rank, entry: Entry) bool {
            if (self.desc.family) |family| return entry.matchesFamily(family);
            // Without a family a monospace request is a filter, with one
            // it is only a preference.
            if (self.desc.monospace) return entry.monospace;
            return true;
        }

        fn key(self: Rank, entry: Entry) [4]u32 {
            const target: i32 = if (self.desc.bold) 700 else 400;
            const style_exact = if (self.desc.style) |s|
                std.ascii.eqlIgnoreCase(entry.style, s)
            else
                false;
            return .{
                @intFromBool(!style_exact),
                @abs(@as(i32, entry.weight) - target),
                @intFromBool(entry.italic != self.desc.italic),
                @intFromBool(self.desc.monospace and !entry.monospace),
            };
        }

        fn lessThan(self: Rank, a: u32, b: u32) bool {
            const ka = self.key(self.entries[a]);
            const kb = self.key(self.entries[b]);
            return std.mem.order(u32, &ka, &kb) == .lt;
        }
    };

    fn isFontFile(name: []const u8) bool {
        return std.ascii.endsWithIgnoreCase(name, ".ttf") or
            std.ascii.endsWithIgnoreCase(name, ".ttc") or
            std.ascii.endsWithIgnoreCase(name, ".otf") or
            std.ascii.endsWithIgnoreCase(name, ".otc");
    }
};

/// Lower-cased file name of the first face `iter` yields.
fn testFirstFileName(iter: *Windows.DiscoverIterator, buf: []u8) !?[]const u8 {
    var face = (try iter.next()) orelse return null;
    defer face.deinit();
    const base = std.fs.path.basenameWindows(face.win.?.path);
    return std.ascii.lowerString(buf, base);
}

fn testSystemFontPresent(name: []const u8) !void {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = global.environ().getAlloc(std.testing.allocator, "SYSTEMROOT") catch
        return error.SkipZigTest;
    defer std.testing.allocator.free(root);
    const path = std.fmt.bufPrint(&buf, "{s}\\Fonts\\{s}", .{ root, name }) catch
        return error.SkipZigTest;
    var file = WindowsFontFile.open(path) catch return error.SkipZigTest;
    file.close();
}

fn testResolves(desc: Descriptor, expected: []const u8) !void {
    if (options.backend != .freetype_windows) return error.SkipZigTest;
    try testSystemFontPresent(expected);

    var lib: Library = try .init(std.testing.allocator);
    defer lib.deinit();
    var disco: Windows = .init(lib);
    defer disco.deinit();
    var iter = try disco.discover(std.testing.allocator, desc);
    defer iter.deinit();

    var buf: [256]u8 = undefined;
    const name = (try testFirstFileName(&iter, &buf)) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(expected, name);
}

test "windows font: Consolas regular resolves to consola.ttf" {
    try testResolves(.{ .family = "Consolas" }, "consola.ttf");
}

test "windows font: Consolas bold resolves to consolab.ttf" {
    try testResolves(.{ .family = "Consolas", .bold = true }, "consolab.ttf");
}

test "windows font: Consolas italic resolves to consolai.ttf" {
    try testResolves(.{ .family = "Consolas", .italic = true }, "consolai.ttf");
}

test "windows font: Consolas bold italic resolves to consolaz.ttf" {
    try testResolves(
        .{ .family = "Consolas", .bold = true, .italic = true },
        "consolaz.ttf",
    );
}

test "windows font: exact style name wins over bold and italic" {
    try testResolves(.{ .family = "consolas", .style = "Bold Italic" }, "consolaz.ttf");
}

test "windows font: monospace without a family only yields fixed-width faces" {
    if (options.backend != .freetype_windows) return error.SkipZigTest;

    var lib: Library = try .init(std.testing.allocator);
    defer lib.deinit();
    var disco: Windows = .init(lib);
    defer disco.deinit();
    var iter = try disco.discover(std.testing.allocator, .{
        .monospace = true,
        .codepoint = 'A',
    });
    defer iter.deinit();

    var face = (try iter.next()) orelse return error.SkipZigTest;
    defer face.deinit();
    const flags = face.win.?.peek.face.handle.*.face_flags;
    try std.testing.expect(flags & freetype.c.FT_FACE_FLAG_FIXED_WIDTH != 0);
}

test "windows font: index is built once" {
    if (options.backend != .freetype_windows) return error.SkipZigTest;

    var lib: Library = try .init(std.testing.allocator);
    defer lib.deinit();
    // Without DirectWrite the file index answers every query.
    var disco: Windows = .{ .lib = lib, .dw = null };
    defer disco.deinit();

    for (0..3) |_| {
        var iter = try disco.discover(std.testing.allocator, .{ .family = "Consolas" });
        iter.deinit();
    }
    try std.testing.expectEqual(@as(u32, 1), Windows.Index.builds);
}

test "windows font: emoji fallback prefers Segoe UI Emoji" {
    if (options.backend != .freetype_windows) return error.SkipZigTest;
    try testSystemFontPresent("seguiemj.ttf");

    var lib: Library = try .init(std.testing.allocator);
    defer lib.deinit();
    var disco: Windows = .init(lib);
    defer disco.deinit();
    var collection: Collection = .init();
    var iter = try disco.discoverFallback(std.testing.allocator, &collection, .{
        .codepoint = 0x1F600,
    });
    defer iter.deinit();

    var buf: [256]u8 = undefined;
    const name = (try testFirstFileName(&iter, &buf)) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("seguiemj.ttf", name);
}

test "windows font: font in a non-ASCII directory loads" {
    if (options.backend != .freetype_windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const io = global.io();

    const root = global.environ().getAlloc(alloc, "SYSTEMROOT") catch
        return error.SkipZigTest;
    defer alloc.free(root);
    const src = try std.fmt.allocPrint(alloc, "{s}\\Fonts\\consola.ttf", .{root});
    defer alloc.free(src);
    var probe = WindowsFontFile.open(src) catch return error.SkipZigTest;
    probe.close();

    const temp = global.environ().getAlloc(alloc, "TEMP") catch return error.SkipZigTest;
    defer alloc.free(temp);
    const dir = try std.fmt.allocPrint(alloc, "{s}\\Шрифты Тест", .{temp});
    defer alloc.free(dir);
    const dst = try std.fmt.allocPrint(alloc, "{s}\\консоль.ttf", .{dir});
    defer alloc.free(dst);

    std.Io.Dir.createDirAbsolute(io, dir, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    defer std.Io.Dir.deleteDirAbsolute(io, dir) catch {};
    try std.Io.Dir.copyFileAbsolute(src, dst, io, .{});
    defer std.Io.Dir.deleteFileAbsolute(io, dst) catch {};

    var lib: Library = try .init(alloc);
    defer lib.deinit();

    const file = try WindowsFontFile.open(dst);
    var face = try Face.initMapped(lib, file, 0, .{ .size = .{ .points = 12 } });
    defer face.deinit();

    try std.testing.expectEqualStrings(
        "Consolas",
        std.mem.span(face.face.handle.*.family_name.?),
    );
    try std.testing.expect(face.glyphIndex('A') != null);
}

test "windows font: U+1F600 from Segoe UI Emoji renders as a colour glyph" {
    if (options.backend != .freetype_windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    try testSystemFontPresent("seguiemj.ttf");

    var lib: Library = try .init(alloc);
    defer lib.deinit();
    var disco: Windows = .init(lib);
    defer disco.deinit();
    var iter = try disco.discover(alloc, .{
        .family = "Segoe UI Emoji",
        .codepoint = 0x1F600,
    });
    defer iter.deinit();

    var deferred = (try iter.next()) orelse return error.SkipZigTest;
    defer deferred.deinit();
    var face = try deferred.load(lib, .{ .size = .{ .points = 12, .xdpi = 96, .ydpi = 96 } });
    defer face.deinit();

    const glyph_id = face.glyphIndex(0x1F600).?;
    try std.testing.expect(face.hasColor());
    try std.testing.expect(face.isColorGlyph(glyph_id));

    const font = @import("main.zig");
    var atlas = try font.Atlas.init(alloc, 512, .bgra);
    defer atlas.deinit(alloc);
    const glyph = try face.renderGlyph(alloc, &atlas, glyph_id, .{
        .grid_metrics = font.Metrics.calc(face.getMetrics()),
    });
    try std.testing.expect(glyph.width > 0 and glyph.height > 0);

    // With no constraint the glyph keeps the size FreeType composited, it
    // is not stretched into the metrics of the base outline.
    {
        face.ft_mutex.lockUncancelable(global.io());
        defer face.ft_mutex.unlock(global.io());
        try face.face.loadGlyph(glyph_id, .{ .color = true, .render = true, .no_svg = true });
        const bitmap = face.face.handle.*.glyph.*.bitmap;
        try std.testing.expectEqual(bitmap.width, glyph.width);
        try std.testing.expectEqual(bitmap.rows, glyph.height);
    }

    // At least one visible pixel must be non-gray (BGRA byte order), and
    // the visible pixels must span most of the glyph rect rather than a
    // sliver of it (a distorted or shifted glyph fails this).
    var coloured = false;
    var min_x: usize = std.math.maxInt(usize);
    var max_x: usize = 0;
    var min_y: usize = std.math.maxInt(usize);
    var max_y: usize = 0;
    for (0..glyph.height) |y| {
        for (0..glyph.width) |x| {
            const i = ((glyph.atlas_y + y) * atlas.size + glyph.atlas_x + x) * 4;
            const px = atlas.data[i..][0..4];
            if (px[3] == 0) continue;
            if (px[0] != px[1] or px[1] != px[2]) coloured = true;
            min_x = @min(min_x, x);
            max_x = @max(max_x, x);
            min_y = @min(min_y, y);
            max_y = @max(max_y, y);
        }
    }
    try std.testing.expect(coloured);
    try std.testing.expect((max_x - min_x + 1) * 2 >= glyph.width);
    try std.testing.expect((max_y - min_y + 1) * 2 >= glyph.height);

    // The glyph has to sit inside its cell vertically: offset_y is the
    // distance from the cell bottom to the glyph top.
    const metrics = font.Metrics.calc(face.getMetrics());
    const cell_h: i32 = @intCast(metrics.cell_height);
    const margin = @divTrunc(cell_h, 4);
    try std.testing.expect(glyph.offset_y > 0);
    try std.testing.expect(glyph.offset_y <= cell_h + margin);
    try std.testing.expect(glyph.offset_y - @as(i32, @intCast(glyph.height)) >= -margin);
}

test "descriptor hash" {
    const testing = std.testing;

    var d: Descriptor = .{};
    try testing.expect(d.hashcode() != 0);
}

test "descriptor hash family names" {
    const testing = std.testing;

    var d1: Descriptor = .{ .family = "A" };
    var d2: Descriptor = .{ .family = "B" };
    try testing.expect(d1.hashcode() != d2.hashcode());
}

test "fontconfig" {
    if (options.backend != .fontconfig_freetype) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;

    var lib = try Library.init(alloc);
    defer lib.deinit();

    var fc = Fontconfig.init(lib);
    defer fc.deinit();
    var it = try fc.discover(alloc, .{ .family = "monospace", .size = 12 });
    defer it.deinit();
}

test "fontconfig codepoint" {
    if (options.backend != .fontconfig_freetype) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;

    var lib = try Library.init(alloc);
    defer lib.deinit();

    var fc = Fontconfig.init(lib);
    defer fc.deinit();
    var it = try fc.discover(alloc, .{ .codepoint = 'A', .size = 12 });
    defer it.deinit();

    // The first result should have the codepoint. Later ones may not
    // because fontconfig returns all fonts sorted.
    var face = (try it.next()).?;
    defer face.deinit();
    try testing.expect(face.hasCodepoint('A', null));

    // Should have other codepoints too
    try testing.expect(face.hasCodepoint('B', null));
}

test "coretext" {
    if (options.backend != .coretext and options.backend != .coretext_freetype)
        return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;

    var lib = try Library.init(alloc);
    defer lib.deinit();

    var ct = CoreText.init(lib);
    defer ct.deinit();
    var it = try ct.discover(alloc, .{ .family = "Monaco", .size = 12 });
    defer it.deinit();
    var count: usize = 0;
    while (try it.next()) |_| {
        count += 1;
    }
    try testing.expect(count > 0);
}

test "coretext codepoint" {
    if (options.backend != .coretext and options.backend != .coretext_freetype)
        return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;

    var lib = try Library.init(alloc);
    defer lib.deinit();

    var ct = CoreText.init(lib);
    defer ct.deinit();
    var it = try ct.discover(alloc, .{ .codepoint = 'A', .size = 12 });
    defer it.deinit();

    // The first result should have the codepoint. Later ones may not
    // because fontconfig returns all fonts sorted.
    const face = (try it.next()).?;
    try testing.expect(face.hasCodepoint('A', null));

    // Should have other codepoints too
    try testing.expect(face.hasCodepoint('B', null));
}

test "coretext sorting" {
    if (options.backend != .coretext and options.backend != .coretext_freetype)
        return error.SkipZigTest;

    // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!//
    // FIXME: Disabled for now because SF Pro is not available in CI
    //        The solution likely involves directly testing that the
    //        `sortMatchingDescriptors` function sorts a bundled test
    //        font correctly, instead of relying on the system fonts.
    if (true) return error.SkipZigTest;
    // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!//

    const testing = std.testing;
    const alloc = testing.allocator;

    var lib = try Library.init(alloc);
    defer lib.deinit();

    var ct = CoreText.init(lib);
    defer ct.deinit();

    // We try to get a Regular, Italic, Bold, & Bold Italic version of SF Pro,
    // which should be installed on all Macs, and has many styles which makes
    // it a good test, since there will be many results for each discovery.

    // Regular
    {
        var it = try ct.discover(alloc, .{
            .family = "SF Pro",
            .size = 12,
        });
        defer it.deinit();
        const res = (try it.next()).?;
        var buf: [1024]u8 = undefined;
        const name = try res.name(&buf);
        try testing.expectEqualStrings("SF Pro Regular", name);
    }

    // Regular Italic
    //
    // NOTE: This makes sure that we don't accidentally prefer "Thin Italic",
    //       which we previously did, because it has a shorter name.
    {
        var it = try ct.discover(alloc, .{
            .family = "SF Pro",
            .size = 12,
            .italic = true,
        });
        defer it.deinit();
        const res = (try it.next()).?;
        var buf: [1024]u8 = undefined;
        const name = try res.name(&buf);
        try testing.expectEqualStrings("SF Pro Regular Italic", name);
    }

    // Bold
    {
        var it = try ct.discover(alloc, .{
            .family = "SF Pro",
            .size = 12,
            .bold = true,
        });
        defer it.deinit();
        const res = (try it.next()).?;
        var buf: [1024]u8 = undefined;
        const name = try res.name(&buf);
        try testing.expectEqualStrings("SF Pro Bold", name);
    }

    // Bold Italic
    {
        var it = try ct.discover(alloc, .{
            .family = "SF Pro",
            .size = 12,
            .bold = true,
            .italic = true,
        });
        defer it.deinit();
        const res = (try it.next()).?;
        var buf: [1024]u8 = undefined;
        const name = try res.name(&buf);
        try testing.expectEqualStrings("SF Pro Bold Italic", name);
    }
}

test "windows" {
    if (options.backend != .freetype_windows) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;

    var lib = try Library.init(alloc);
    defer lib.deinit();

    var win = Windows.init(lib);
    defer win.deinit();

    // Arial ships on every stock Windows install.
    var it = try win.discover(alloc, .{ .family = "Arial", .size = 12 });
    defer it.deinit();

    var face = (try it.next()) orelse return error.TestFontNotFound;
    defer face.deinit();
    try testing.expect(face.hasCodepoint('A', null));
}

test {
    if (options.backend == .freetype_windows) _ = @import("directwrite.zig");
}
