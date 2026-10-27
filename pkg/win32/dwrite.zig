//! DirectWrite bindings (dwrite.h of SDK 10.0.26100): the factory, text
//! formats, text layouts and inline objects behind the tab-strip chrome
//! painter. Full slot lists; slots become typed as consumers need them.
const foundation = @import("foundation.zig");
const com = @import("com.zig");
const GUID = foundation.GUID;
const HRESULT = foundation.HRESULT;
const Error = foundation.Error;
const check = foundation.check;
const IUnknown = com.IUnknown;

/// DWRITE_FACTORY_TYPE
pub const FactoryType = enum(u32) {
    SHARED = 0,
    ISOLATED = 1,
};

/// DWRITE_FONT_WEIGHT. Non-exhaustive; any 1..999 value is valid.
pub const FontWeight = enum(u32) {
    THIN = 100,
    LIGHT = 300,
    NORMAL = 400,
    MEDIUM = 500,
    SEMI_BOLD = 600,
    BOLD = 700,
    _,
};

/// DWRITE_FONT_STYLE
pub const FontStyle = enum(u32) {
    NORMAL = 0,
    OBLIQUE = 1,
    ITALIC = 2,
};

/// DWRITE_FONT_STRETCH
pub const FontStretch = enum(u32) {
    UNDEFINED = 0,
    CONDENSED = 3,
    NORMAL = 5,
    EXPANDED = 7,
    _,
};

/// DWRITE_TEXT_ALIGNMENT
pub const TextAlignment = enum(u32) {
    LEADING = 0,
    TRAILING = 1,
    CENTER = 2,
    JUSTIFIED = 3,
};

/// DWRITE_PARAGRAPH_ALIGNMENT
pub const ParagraphAlignment = enum(u32) {
    NEAR = 0,
    FAR = 1,
    CENTER = 2,
};

/// DWRITE_WORD_WRAPPING
pub const WordWrapping = enum(u32) {
    WRAP = 0,
    NO_WRAP = 1,
    EMERGENCY_BREAK = 2,
    WHOLE_WORD = 3,
    CHARACTER = 4,
};

/// DWRITE_TRIMMING_GRANULARITY
pub const TrimmingGranularity = enum(u32) {
    NONE = 0,
    CHARACTER = 1,
    WORD = 2,
};

/// DWRITE_TRIMMING
pub const DWRITE_TRIMMING = extern struct {
    granularity: TrimmingGranularity,
    delimiter: u32 = 0,
    delimiterCount: u32 = 0,
};

/// DWRITE_TEXT_METRICS
pub const DWRITE_TEXT_METRICS = extern struct {
    left: f32,
    top: f32,
    width: f32,
    widthIncludingTrailingWhitespace: f32,
    height: f32,
    layoutWidth: f32,
    layoutHeight: f32,
    maxBidiReorderingDepth: u32,
    lineCount: u32,
};

extern "dwrite" fn DWriteCreateFactory(
    factoryType: FactoryType,
    riid: *const GUID,
    factory: *?*anyopaque,
) callconv(.winapi) HRESULT;

/// Creates the process-shared DirectWrite factory.
pub fn createFactory() Error!*IDWriteFactory {
    var out: ?*anyopaque = null;
    try check(DWriteCreateFactory(.SHARED, &IDWriteFactory.iid, &out));
    return @ptrCast(@alignCast(out orelse return error.ComFailure));
}

pub const IDWriteInlineObject = extern struct {
    vtable: *const VTable,

    pub const iid = GUID.parse("8339fde3-106f-47ab-8373-1c6295eb10b3");

    pub const VTable = extern struct {
        base: IUnknown.VTable,
        Draw: *const anyopaque,
        GetMetrics: *const anyopaque,
        GetOverhangMetrics: *const anyopaque,
        GetBreakConditions: *const anyopaque,
    };
};

pub const IDWriteTextFormat = extern struct {
    vtable: *const VTable,

    pub const iid = GUID.parse("9c906818-31d7-4fd3-a151-7c5e225db55a");

    pub const VTable = extern struct {
        base: IUnknown.VTable,
        SetTextAlignment: *const fn (*IDWriteTextFormat, TextAlignment) callconv(.winapi) HRESULT,
        SetParagraphAlignment: *const fn (*IDWriteTextFormat, ParagraphAlignment) callconv(.winapi) HRESULT,
        SetWordWrapping: *const fn (*IDWriteTextFormat, WordWrapping) callconv(.winapi) HRESULT,
        SetReadingDirection: *const anyopaque,
        SetFlowDirection: *const anyopaque,
        SetIncrementalTabStop: *const anyopaque,
        SetTrimming: *const fn (*IDWriteTextFormat, *const DWRITE_TRIMMING, ?*IDWriteInlineObject) callconv(.winapi) HRESULT,
        SetLineSpacing: *const anyopaque,
        GetTextAlignment: *const anyopaque,
        GetParagraphAlignment: *const anyopaque,
        GetWordWrapping: *const anyopaque,
        GetReadingDirection: *const anyopaque,
        GetFlowDirection: *const anyopaque,
        GetIncrementalTabStop: *const anyopaque,
        GetTrimming: *const anyopaque,
        GetLineSpacing: *const anyopaque,
        GetFontCollection: *const anyopaque,
        GetFontFamilyNameLength: *const anyopaque,
        GetFontFamilyName: *const anyopaque,
        GetFontWeight: *const anyopaque,
        GetFontStyle: *const anyopaque,
        GetFontStretch: *const anyopaque,
        GetFontSize: *const anyopaque,
        GetLocaleNameLength: *const anyopaque,
        GetLocaleName: *const anyopaque,
    };

    pub inline fn setTextAlignment(self: *IDWriteTextFormat, alignment: TextAlignment) Error!void {
        try check(self.vtable.SetTextAlignment(self, alignment));
    }

    pub inline fn setParagraphAlignment(self: *IDWriteTextFormat, alignment: ParagraphAlignment) Error!void {
        try check(self.vtable.SetParagraphAlignment(self, alignment));
    }

    pub inline fn setWordWrapping(self: *IDWriteTextFormat, wrapping: WordWrapping) Error!void {
        try check(self.vtable.SetWordWrapping(self, wrapping));
    }

    /// `sign` is typically from `IDWriteFactory.createEllipsisTrimmingSign`.
    pub inline fn setTrimming(self: *IDWriteTextFormat, trimming: DWRITE_TRIMMING, sign: ?*IDWriteInlineObject) Error!void {
        try check(self.vtable.SetTrimming(self, &trimming, sign));
    }
};

pub const IDWriteTextLayout = extern struct {
    vtable: *const VTable,

    pub const iid = GUID.parse("53737037-6d14-410b-9bfe-0b182bb70961");

    pub const VTable = extern struct {
        base: IDWriteTextFormat.VTable,
        SetMaxWidth: *const fn (*IDWriteTextLayout, f32) callconv(.winapi) HRESULT,
        SetMaxHeight: *const anyopaque,
        SetFontCollection: *const anyopaque,
        SetFontFamilyName: *const anyopaque,
        SetFontWeight: *const anyopaque,
        SetFontStyle: *const anyopaque,
        SetFontStretch: *const anyopaque,
        SetFontSize: *const anyopaque,
        SetUnderline: *const anyopaque,
        SetStrikethrough: *const anyopaque,
        SetDrawingEffect: *const anyopaque,
        SetInlineObject: *const anyopaque,
        SetTypography: *const anyopaque,
        SetLocaleName: *const anyopaque,
        GetMaxWidth: *const anyopaque,
        GetMaxHeight: *const anyopaque,
        GetFontCollection: *const anyopaque,
        GetFontFamilyNameLength: *const anyopaque,
        GetFontFamilyName: *const anyopaque,
        GetFontWeight: *const anyopaque,
        GetFontStyle: *const anyopaque,
        GetFontStretch: *const anyopaque,
        GetFontSize: *const anyopaque,
        GetUnderline: *const anyopaque,
        GetStrikethrough: *const anyopaque,
        GetDrawingEffect: *const anyopaque,
        GetInlineObject: *const anyopaque,
        GetTypography: *const anyopaque,
        GetLocaleNameLength: *const anyopaque,
        GetLocaleName: *const anyopaque,
        Draw: *const anyopaque,
        GetLineMetrics: *const anyopaque,
        GetMetrics: *const fn (*IDWriteTextLayout, *DWRITE_TEXT_METRICS) callconv(.winapi) HRESULT,
        GetOverhangMetrics: *const anyopaque,
        GetClusterMetrics: *const anyopaque,
        DetermineMinWidth: *const anyopaque,
        HitTestPoint: *const anyopaque,
        HitTestTextPosition: *const anyopaque,
        HitTestTextRange: *const anyopaque,
    };

    pub inline fn asFormat(self: *IDWriteTextLayout) *IDWriteTextFormat {
        return @ptrCast(self);
    }

    pub inline fn getMetrics(self: *IDWriteTextLayout) Error!DWRITE_TEXT_METRICS {
        var metrics: DWRITE_TEXT_METRICS = undefined;
        try check(self.vtable.GetMetrics(self, &metrics));
        return metrics;
    }

    pub inline fn setMaxWidth(self: *IDWriteTextLayout, width: f32) Error!void {
        try check(self.vtable.SetMaxWidth(self, width));
    }
};

pub const IDWriteFactory = extern struct {
    vtable: *const VTable,

    pub const iid = GUID.parse("b859ee5a-d838-4b5b-a2e8-1adc7d93db48");

    pub const VTable = extern struct {
        base: IUnknown.VTable,
        GetSystemFontCollection: *const fn (*IDWriteFactory, *?*IDWriteFontCollection, foundation.BOOL) callconv(.winapi) HRESULT,
        CreateCustomFontCollection: *const anyopaque,
        RegisterFontCollectionLoader: *const anyopaque,
        UnregisterFontCollectionLoader: *const anyopaque,
        CreateFontFileReference: *const anyopaque,
        CreateCustomFontFileReference: *const anyopaque,
        CreateFontFace: *const anyopaque,
        CreateRenderingParams: *const anyopaque,
        CreateMonitorRenderingParams: *const anyopaque,
        CreateCustomRenderingParams: *const anyopaque,
        RegisterFontFileLoader: *const anyopaque,
        UnregisterFontFileLoader: *const anyopaque,
        CreateTextFormat: *const fn (*IDWriteFactory, [*:0]const u16, ?*anyopaque, FontWeight, FontStyle, FontStretch, f32, [*:0]const u16, *?*IDWriteTextFormat) callconv(.winapi) HRESULT,
        CreateTypography: *const anyopaque,
        GetGdiInterop: *const anyopaque,
        CreateTextLayout: *const fn (*IDWriteFactory, [*]const u16, u32, *IDWriteTextFormat, f32, f32, *?*IDWriteTextLayout) callconv(.winapi) HRESULT,
        CreateGdiCompatibleTextLayout: *const anyopaque,
        CreateEllipsisTrimmingSign: *const fn (*IDWriteFactory, *IDWriteTextFormat, *?*IDWriteInlineObject) callconv(.winapi) HRESULT,
        CreateTextAnalyzer: *const anyopaque,
        CreateNumberSubstitution: *const anyopaque,
        CreateGlyphRunAnalysis: *const anyopaque,
    };

    /// Uses the system font collection. `locale` is e.g. `L"en-us"`.
    pub inline fn createTextFormat(
        self: *IDWriteFactory,
        family: [*:0]const u16,
        weight: FontWeight,
        style: FontStyle,
        stretch: FontStretch,
        size: f32,
        locale: [*:0]const u16,
    ) Error!*IDWriteTextFormat {
        var out: ?*IDWriteTextFormat = null;
        try check(self.vtable.CreateTextFormat(self, family, null, weight, style, stretch, size, locale, &out));
        return out orelse error.ComFailure;
    }

    pub inline fn createTextLayout(
        self: *IDWriteFactory,
        text: []const u16,
        format: *IDWriteTextFormat,
        max_width: f32,
        max_height: f32,
    ) Error!*IDWriteTextLayout {
        var out: ?*IDWriteTextLayout = null;
        try check(self.vtable.CreateTextLayout(self, text.ptr, @intCast(text.len), format, max_width, max_height, &out));
        return out orelse error.ComFailure;
    }

    pub inline fn createEllipsisTrimmingSign(self: *IDWriteFactory, format: *IDWriteTextFormat) Error!*IDWriteInlineObject {
        var out: ?*IDWriteInlineObject = null;
        try check(self.vtable.CreateEllipsisTrimmingSign(self, format, &out));
        return out orelse error.ComFailure;
    }
};

pub const IDWriteFontCollection = extern struct {
    vtable: *const VTable,

    pub const iid = GUID.parse("a84cee02-3eea-4eee-a827-87c1a02a0fcc");

    pub const VTable = extern struct {
        base: IUnknown.VTable,
        GetFontFamilyCount: *const fn (*IDWriteFontCollection) callconv(.winapi) u32,
        GetFontFamily: *const fn (*IDWriteFontCollection, u32, *?*IDWriteFontFamily) callconv(.winapi) HRESULT,
        FindFamilyName: *const fn (*IDWriteFontCollection, [*:0]const u16, *u32, *foundation.BOOL) callconv(.winapi) HRESULT,
        GetFontFromFontFace: *const anyopaque,
    };

    pub inline fn getFontFamilyCount(self: *IDWriteFontCollection) u32 {
        return self.vtable.GetFontFamilyCount(self);
    }

    /// The family at `index`; the caller releases it.
    pub inline fn getFontFamily(self: *IDWriteFontCollection, index: u32) Error!*IDWriteFontFamily {
        var out: ?*IDWriteFontFamily = null;
        try check(self.vtable.GetFontFamily(self, index, &out));
        return out orelse error.ComFailure;
    }

    /// Index of the family called `name` (case-insensitive, any locale), or null.
    pub inline fn findFamilyName(self: *IDWriteFontCollection, name: [*:0]const u16) Error!?u32 {
        var index: u32 = 0;
        var exists: foundation.BOOL = 0;
        try check(self.vtable.FindFamilyName(self, name, &index, &exists));
        return if (exists != 0) index else null;
    }

    /// Whether the collection has a family called `name`.
    pub inline fn hasFamily(self: *IDWriteFontCollection, name: [*:0]const u16) Error!bool {
        var index: u32 = 0;
        var exists: foundation.BOOL = 0;
        try check(self.vtable.FindFamilyName(self, name, &index, &exists));
        return exists != 0;
    }
};

/// The system font collection; the caller releases it.
pub inline fn getSystemFontCollection(factory: *IDWriteFactory) Error!*IDWriteFontCollection {
    var out: ?*IDWriteFontCollection = null;
    try check(factory.vtable.GetSystemFontCollection(factory, &out, 0));
    return out orelse error.ComFailure;
}

/// DWRITE_INFORMATIONAL_STRING_ID (the subset consumers need).
pub const InformationalStringId = enum(u32) {
    WIN32_FAMILY_NAMES = 11,
    WIN32_SUBFAMILY_NAMES = 12,
    TYPOGRAPHIC_FAMILY_NAMES = 13,
    TYPOGRAPHIC_SUBFAMILY_NAMES = 14,
    FULL_NAME = 16,
    POSTSCRIPT_NAME = 17,
    _,
};

pub const DWRITE_INFORMATIONAL_STRING_FULL_NAME = InformationalStringId.FULL_NAME;

/// DWRITE_READING_DIRECTION
pub const ReadingDirection = enum(u32) {
    LEFT_TO_RIGHT = 0,
    RIGHT_TO_LEFT = 1,
};

pub const IID_IDWriteLocalFontFileLoader = IDWriteLocalFontFileLoader.iid;

/// IDWriteFactory1 adds two slots, IDWriteFactory2 five more.
pub const IDWriteFactory2 = extern struct {
    vtable: *const VTable,

    pub const iid = GUID.parse("0439fc60-ca44-4994-8dee-3a9af7b732ec");

    pub const VTable = extern struct {
        base: IDWriteFactory.VTable,
        // IDWriteFactory1
        GetEudcFontCollection: *const anyopaque,
        CreateCustomRenderingParams1: *const anyopaque,
        // IDWriteFactory2
        GetSystemFontFallback: *const fn (*IDWriteFactory2, *?*IDWriteFontFallback) callconv(.winapi) HRESULT,
        CreateFontFallbackBuilder: *const anyopaque,
        TranslateColorGlyphRun: *const anyopaque,
        CreateCustomRenderingParams2: *const anyopaque,
        CreateGlyphRunAnalysis: *const anyopaque,
    };

    /// The system font fallback; the caller releases it.
    pub inline fn getSystemFontFallback(self: *IDWriteFactory2) Error!*IDWriteFontFallback {
        var out: ?*IDWriteFontFallback = null;
        try check(self.vtable.GetSystemFontFallback(self, &out));
        return out orelse error.ComFailure;
    }
};

pub const IDWriteLocalizedStrings = extern struct {
    vtable: *const VTable,

    pub const iid = GUID.parse("08256209-099a-4b34-b86d-c22b110e7771");

    pub const VTable = extern struct {
        base: IUnknown.VTable,
        GetCount: *const fn (*IDWriteLocalizedStrings) callconv(.winapi) u32,
        FindLocaleName: *const fn (*IDWriteLocalizedStrings, [*:0]const u16, *u32, *foundation.BOOL) callconv(.winapi) HRESULT,
        GetLocaleNameLength: *const anyopaque,
        GetLocaleName: *const anyopaque,
        GetStringLength: *const fn (*IDWriteLocalizedStrings, u32, *u32) callconv(.winapi) HRESULT,
        GetString: *const fn (*IDWriteLocalizedStrings, u32, [*]u16, u32) callconv(.winapi) HRESULT,
    };

    pub inline fn getCount(self: *IDWriteLocalizedStrings) u32 {
        return self.vtable.GetCount(self);
    }

    /// Index of `locale`, or null when the set has no such locale.
    pub inline fn findLocaleName(self: *IDWriteLocalizedStrings, locale: [*:0]const u16) Error!?u32 {
        var index: u32 = 0;
        var exists: foundation.BOOL = 0;
        try check(self.vtable.FindLocaleName(self, locale, &index, &exists));
        return if (exists != 0) index else null;
    }

    /// Length in UTF-16 units, without the terminator.
    pub inline fn getStringLength(self: *IDWriteLocalizedStrings, index: u32) Error!u32 {
        var len: u32 = 0;
        try check(self.vtable.GetStringLength(self, index, &len));
        return len;
    }

    /// Copies string `index` and a NUL into `buf`; `buf.len` must exceed the
    /// string length. Returns the string without the terminator.
    pub inline fn getString(self: *IDWriteLocalizedStrings, index: u32, buf: []u16) Error![]const u16 {
        const len = try self.getStringLength(index);
        if (len >= buf.len) return error.InvalidArgument;
        try check(self.vtable.GetString(self, index, buf.ptr, @intCast(buf.len)));
        return buf[0..len];
    }
};

pub const IDWriteFontFileLoader = extern struct {
    vtable: *const VTable,

    pub const iid = GUID.parse("727cad4e-d6af-4c9e-8a08-d695b11caa49");

    pub const VTable = extern struct {
        base: IUnknown.VTable,
        CreateStreamFromKey: *const anyopaque,
    };
};

pub const IDWriteLocalFontFileLoader = extern struct {
    vtable: *const VTable,

    pub const iid = GUID.parse("b2d9f3ec-c9fe-4a11-a2ec-d86208f7c0a2");

    pub const VTable = extern struct {
        base: IDWriteFontFileLoader.VTable,
        GetFilePathLengthFromKey: *const fn (*IDWriteLocalFontFileLoader, *const anyopaque, u32, *u32) callconv(.winapi) HRESULT,
        GetFilePathFromKey: *const fn (*IDWriteLocalFontFileLoader, *const anyopaque, u32, [*]u16, u32) callconv(.winapi) HRESULT,
        GetLastWriteTimeFromKey: *const anyopaque,
    };

    /// Length in UTF-16 units of the path for `key`, without the terminator.
    pub inline fn getFilePathLengthFromKey(self: *IDWriteLocalFontFileLoader, key: *const anyopaque, key_size: u32) Error!u32 {
        var len: u32 = 0;
        try check(self.vtable.GetFilePathLengthFromKey(self, key, key_size, &len));
        return len;
    }

    /// Copies the path and a NUL into `buf`; `buf.len` must exceed the path.
    pub inline fn getFilePathFromKey(self: *IDWriteLocalFontFileLoader, key: *const anyopaque, key_size: u32, buf: []u16) Error!void {
        try check(self.vtable.GetFilePathFromKey(self, key, key_size, buf.ptr, @intCast(buf.len)));
    }
};

pub const IDWriteFontFile = extern struct {
    vtable: *const VTable,

    pub const iid = GUID.parse("739d886a-cef5-47dc-8769-1a8b41bebbb0");

    pub const VTable = extern struct {
        base: IUnknown.VTable,
        GetReferenceKey: *const fn (*IDWriteFontFile, *?*const anyopaque, *u32) callconv(.winapi) HRESULT,
        GetLoader: *const fn (*IDWriteFontFile, *?*IDWriteFontFileLoader) callconv(.winapi) HRESULT,
        Analyze: *const anyopaque,
    };

    pub const ReferenceKey = struct { key: *const anyopaque, size: u32 };

    /// The key is owned by the file and valid while it lives.
    pub inline fn getReferenceKey(self: *IDWriteFontFile) Error!ReferenceKey {
        var key: ?*const anyopaque = null;
        var size: u32 = 0;
        try check(self.vtable.GetReferenceKey(self, &key, &size));
        return .{ .key = key orelse return error.ComFailure, .size = size };
    }

    /// The loader; the caller releases it.
    pub inline fn getLoader(self: *IDWriteFontFile) Error!*IDWriteFontFileLoader {
        var out: ?*IDWriteFontFileLoader = null;
        try check(self.vtable.GetLoader(self, &out));
        return out orelse error.ComFailure;
    }
};

pub const IDWriteFontFace = extern struct {
    vtable: *const VTable,

    pub const iid = GUID.parse("5f49804d-7024-4d43-bfa9-d25984f53849");

    pub const VTable = extern struct {
        base: IUnknown.VTable,
        GetType: *const anyopaque,
        GetFiles: *const fn (*IDWriteFontFace, *u32, ?[*]?*IDWriteFontFile) callconv(.winapi) HRESULT,
        GetIndex: *const fn (*IDWriteFontFace) callconv(.winapi) u32,
        GetSimulations: *const anyopaque,
        IsSymbolFont: *const anyopaque,
        GetMetrics: *const anyopaque,
        GetGlyphCount: *const anyopaque,
        GetDesignGlyphMetrics: *const anyopaque,
        GetGlyphIndices: *const anyopaque,
        TryGetFontTable: *const anyopaque,
        ReleaseFontTable: *const anyopaque,
        GetGlyphRunOutline: *const anyopaque,
        GetRecommendedRenderingMode: *const anyopaque,
        GetGdiCompatibleMetrics: *const anyopaque,
        GetGdiCompatibleGlyphMetrics: *const anyopaque,
    };

    /// Number of files the face is made of.
    pub inline fn getFileCount(self: *IDWriteFontFace) Error!u32 {
        var n: u32 = 0;
        try check(self.vtable.GetFiles(self, &n, null));
        return n;
    }

    /// Fills `out` (sized by `getFileCount`); the caller releases each file.
    pub inline fn getFiles(self: *IDWriteFontFace, out: []?*IDWriteFontFile) Error!void {
        var n: u32 = @intCast(out.len);
        try check(self.vtable.GetFiles(self, &n, out.ptr));
    }

    pub inline fn getIndex(self: *IDWriteFontFace) u32 {
        return self.vtable.GetIndex(self);
    }
};

pub const IDWriteFont = extern struct {
    vtable: *const VTable,

    pub const iid = GUID.parse("acd16696-8c14-4f5d-877e-fe3fc1d32737");

    pub const VTable = extern struct {
        base: IUnknown.VTable,
        GetFontFamily: *const fn (*IDWriteFont, *?*IDWriteFontFamily) callconv(.winapi) HRESULT,
        GetWeight: *const fn (*IDWriteFont) callconv(.winapi) u32,
        GetStretch: *const fn (*IDWriteFont) callconv(.winapi) u32,
        GetStyle: *const fn (*IDWriteFont) callconv(.winapi) u32,
        IsSymbolFont: *const anyopaque,
        GetFaceNames: *const fn (*IDWriteFont, *?*IDWriteLocalizedStrings) callconv(.winapi) HRESULT,
        GetInformationalStrings: *const fn (*IDWriteFont, InformationalStringId, *?*IDWriteLocalizedStrings, *foundation.BOOL) callconv(.winapi) HRESULT,
        GetSimulations: *const anyopaque,
        GetMetrics: *const anyopaque,
        HasCharacter: *const fn (*IDWriteFont, u32, *foundation.BOOL) callconv(.winapi) HRESULT,
        CreateFontFace: *const fn (*IDWriteFont, *?*IDWriteFontFace) callconv(.winapi) HRESULT,
    };

    pub inline fn getWeight(self: *IDWriteFont) u32 {
        return self.vtable.GetWeight(self);
    }

    pub inline fn getStretch(self: *IDWriteFont) u32 {
        return self.vtable.GetStretch(self);
    }

    pub inline fn getStyle(self: *IDWriteFont) FontStyle {
        return @fromBackingInt(@intCast(self.vtable.GetStyle(self)));
    }

    /// The family; the caller releases it.
    pub inline fn getFontFamily(self: *IDWriteFont) Error!*IDWriteFontFamily {
        var out: ?*IDWriteFontFamily = null;
        try check(self.vtable.GetFontFamily(self, &out));
        return out orelse error.ComFailure;
    }

    /// Style names such as "Bold Italic"; the caller releases them.
    pub inline fn getFaceNames(self: *IDWriteFont) Error!*IDWriteLocalizedStrings {
        var out: ?*IDWriteLocalizedStrings = null;
        try check(self.vtable.GetFaceNames(self, &out));
        return out orelse error.ComFailure;
    }

    /// Null when the font has no such string; the caller releases it.
    pub inline fn getInformationalStrings(self: *IDWriteFont, id: InformationalStringId) Error!?*IDWriteLocalizedStrings {
        var out: ?*IDWriteLocalizedStrings = null;
        var exists: foundation.BOOL = 0;
        try check(self.vtable.GetInformationalStrings(self, id, &out, &exists));
        return if (exists != 0) out else null;
    }

    pub inline fn hasCharacter(self: *IDWriteFont, codepoint: u32) Error!bool {
        var exists: foundation.BOOL = 0;
        try check(self.vtable.HasCharacter(self, codepoint, &exists));
        return exists != 0;
    }

    /// The face; the caller releases it.
    pub inline fn createFontFace(self: *IDWriteFont) Error!*IDWriteFontFace {
        var out: ?*IDWriteFontFace = null;
        try check(self.vtable.CreateFontFace(self, &out));
        return out orelse error.ComFailure;
    }
};

pub const IDWriteFont1 = extern struct {
    vtable: *const VTable,

    pub const iid = GUID.parse("acd16696-8c14-4f5d-877e-fe3fc1d32738");

    pub const VTable = extern struct {
        base: IDWriteFont.VTable,
        GetMetrics1: *const anyopaque,
        GetPanose: *const anyopaque,
        GetUnicodeRanges: *const anyopaque,
        IsMonospacedFont: *const fn (*IDWriteFont1) callconv(.winapi) foundation.BOOL,
    };

    pub inline fn isMonospacedFont(self: *IDWriteFont1) bool {
        return self.vtable.IsMonospacedFont(self) != 0;
    }
};

pub const IDWriteFontList = extern struct {
    vtable: *const VTable,

    pub const iid = GUID.parse("1a0d8438-1d97-4ec1-aef9-a2fb86ed6acb");

    pub const VTable = extern struct {
        base: IUnknown.VTable,
        GetFontCollection: *const anyopaque,
        GetFontCount: *const fn (*IDWriteFontList) callconv(.winapi) u32,
        GetFont: *const fn (*IDWriteFontList, u32, *?*IDWriteFont) callconv(.winapi) HRESULT,
    };
};

pub const IDWriteFontFamily = extern struct {
    vtable: *const VTable,

    pub const iid = GUID.parse("da20d8ef-812a-4c43-9802-62ec4abd7add");

    pub const VTable = extern struct {
        base: IDWriteFontList.VTable,
        GetFamilyNames: *const fn (*IDWriteFontFamily, *?*IDWriteLocalizedStrings) callconv(.winapi) HRESULT,
        GetFirstMatchingFont: *const fn (*IDWriteFontFamily, FontWeight, FontStretch, FontStyle, *?*IDWriteFont) callconv(.winapi) HRESULT,
        GetMatchingFonts: *const anyopaque,
    };

    pub inline fn getFontCount(self: *IDWriteFontFamily) u32 {
        return self.vtable.base.GetFontCount(@ptrCast(self));
    }

    /// The font at `index`; the caller releases it.
    pub inline fn getFont(self: *IDWriteFontFamily, index: u32) Error!*IDWriteFont {
        var out: ?*IDWriteFont = null;
        try check(self.vtable.base.GetFont(@ptrCast(self), index, &out));
        return out orelse error.ComFailure;
    }

    /// Family names per locale; the caller releases them.
    pub inline fn getFamilyNames(self: *IDWriteFontFamily) Error!*IDWriteLocalizedStrings {
        var out: ?*IDWriteLocalizedStrings = null;
        try check(self.vtable.GetFamilyNames(self, &out));
        return out orelse error.ComFailure;
    }

    /// The font closest to the request; the caller releases it.
    pub inline fn getFirstMatchingFont(self: *IDWriteFontFamily, weight: FontWeight, stretch: FontStretch, style: FontStyle) Error!*IDWriteFont {
        var out: ?*IDWriteFont = null;
        try check(self.vtable.GetFirstMatchingFont(self, weight, stretch, style, &out));
        return out orelse error.ComFailure;
    }
};

pub const IDWriteFontFallback = extern struct {
    vtable: *const VTable,

    pub const iid = GUID.parse("efa008f9-f7a1-48bf-b05c-f224713cc0ff");

    pub const VTable = extern struct {
        base: IUnknown.VTable,
        MapCharacters: *const fn (
            *IDWriteFontFallback,
            *IDWriteTextAnalysisSource,
            u32,
            u32,
            ?*IDWriteFontCollection,
            ?[*:0]const u16,
            FontWeight,
            FontStyle,
            FontStretch,
            *u32,
            *?*IDWriteFont,
            *f32,
        ) callconv(.winapi) HRESULT,
    };

    pub const Mapped = struct {
        /// Null when no installed font covers the range.
        font: ?*IDWriteFont,
        length: u32,
        scale: f32,
    };

    pub inline fn mapCharacters(
        self: *IDWriteFontFallback,
        source: *IDWriteTextAnalysisSource,
        position: u32,
        length: u32,
        base_family: ?[*:0]const u16,
        weight: FontWeight,
        style: FontStyle,
        stretch: FontStretch,
    ) Error!Mapped {
        var mapped_len: u32 = 0;
        var font: ?*IDWriteFont = null;
        var scale: f32 = 1;
        try check(self.vtable.MapCharacters(self, source, position, length, null, base_family, weight, style, stretch, &mapped_len, &font, &scale));
        return .{ .font = font, .length = mapped_len, .scale = scale };
    }
};

/// Vtable type for a text source implemented by the caller (an object whose
/// first field is a `*const IDWriteTextAnalysisSource.VTable`).
pub const IDWriteTextAnalysisSource = extern struct {
    vtable: *const VTable,

    pub const iid = GUID.parse("688e1a58-5094-47c8-adc8-fbcea60ae92b");

    pub const VTable = extern struct {
        base: IUnknown.VTable,
        GetTextAtPosition: *const fn (*IDWriteTextAnalysisSource, u32, *?[*]const u16, *u32) callconv(.winapi) HRESULT,
        GetTextBeforePosition: *const fn (*IDWriteTextAnalysisSource, u32, *?[*]const u16, *u32) callconv(.winapi) HRESULT,
        GetParagraphReadingDirection: *const fn (*IDWriteTextAnalysisSource) callconv(.winapi) ReadingDirection,
        GetLocaleName: *const fn (*IDWriteTextAnalysisSource, u32, *u32, *?[*:0]const u16) callconv(.winapi) HRESULT,
        GetNumberSubstitution: *const fn (*IDWriteTextAnalysisSource, u32, *u32, *?*anyopaque) callconv(.winapi) HRESULT,
    };
};
