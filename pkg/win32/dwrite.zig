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
        GetSystemFontCollection: *const anyopaque,
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
