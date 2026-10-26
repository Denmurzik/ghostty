//! Tests for the Direct2D/DirectWrite bindings: vtable layouts against the
//! SDK 10.0.26100 headers (d2d1.h, dwrite.h) and a headless draw into a
//! premultiplied DIB through a software DC render target.
const std = @import("std");
const win32 = @import("win32");
const com = win32.com;
const d2d1 = win32.d2d1;
const dwrite = win32.dwrite;
const gdi32 = win32.gdi32;

fn slots(comptime T: type) usize {
    return @sizeOf(T.VTable) / @sizeOf(usize);
}

fn slot(comptime T: type, comptime name: []const u8) usize {
    return @offsetOf(T.VTable, name) / @sizeOf(usize);
}

test "win32 d2d: vtable slot counts" {
    // Total slots including inherited ones, counted from the Windows SDK
    // 10.0.26100 headers (um/d2d1.h, um/dwrite.h).
    try std.testing.expectEqual(4, slots(d2d1.ID2D1Resource));
    try std.testing.expectEqual(8, slots(d2d1.ID2D1Brush));
    try std.testing.expectEqual(10, slots(d2d1.ID2D1SolidColorBrush));
    try std.testing.expectEqual(17, slots(d2d1.ID2D1Factory));
    try std.testing.expectEqual(57, slots(d2d1.ID2D1RenderTarget));
    try std.testing.expectEqual(60, slots(d2d1.ID2D1HwndRenderTarget));
    try std.testing.expectEqual(58, slots(d2d1.ID2D1DCRenderTarget));

    try std.testing.expectEqual(24, slots(dwrite.IDWriteFactory));
    try std.testing.expectEqual(28, slots(dwrite.IDWriteTextFormat));
    try std.testing.expectEqual(67, slots(dwrite.IDWriteTextLayout));
    try std.testing.expectEqual(7, slots(dwrite.IDWriteInlineObject));
    try std.testing.expectEqual(7, slots(dwrite.IDWriteFontCollection));
}

test "win32 d2d: typed slots sit at their header positions" {
    // 0-based position of each method in the header declaration order,
    // inherited slots first (ID2D1Resource has 4, ID2D1RenderTarget adds 53).
    try std.testing.expectEqual(8, slot(d2d1.ID2D1RenderTarget, "CreateSolidColorBrush"));
    try std.testing.expectEqual(15, slot(d2d1.ID2D1RenderTarget, "DrawLine"));
    try std.testing.expectEqual(17, slot(d2d1.ID2D1RenderTarget, "FillRectangle"));
    try std.testing.expectEqual(19, slot(d2d1.ID2D1RenderTarget, "FillRoundedRectangle"));
    try std.testing.expectEqual(28, slot(d2d1.ID2D1RenderTarget, "DrawTextLayout"));
    try std.testing.expectEqual(30, slot(d2d1.ID2D1RenderTarget, "SetTransform"));
    try std.testing.expectEqual(34, slot(d2d1.ID2D1RenderTarget, "SetTextAntialiasMode"));
    try std.testing.expectEqual(45, slot(d2d1.ID2D1RenderTarget, "PushAxisAlignedClip"));
    try std.testing.expectEqual(46, slot(d2d1.ID2D1RenderTarget, "PopAxisAlignedClip"));
    try std.testing.expectEqual(47, slot(d2d1.ID2D1RenderTarget, "Clear"));
    try std.testing.expectEqual(48, slot(d2d1.ID2D1RenderTarget, "BeginDraw"));
    try std.testing.expectEqual(49, slot(d2d1.ID2D1RenderTarget, "EndDraw"));
    try std.testing.expectEqual(58, slot(d2d1.ID2D1HwndRenderTarget, "Resize"));
    try std.testing.expectEqual(57, slot(d2d1.ID2D1DCRenderTarget, "BindDC"));
    try std.testing.expectEqual(8, slot(d2d1.ID2D1SolidColorBrush, "SetColor"));
    try std.testing.expectEqual(14, slot(d2d1.ID2D1Factory, "CreateHwndRenderTarget"));
    try std.testing.expectEqual(16, slot(d2d1.ID2D1Factory, "CreateDCRenderTarget"));

    try std.testing.expectEqual(3, slot(dwrite.IDWriteFactory, "GetSystemFontCollection"));
    try std.testing.expectEqual(5, slot(dwrite.IDWriteFontCollection, "FindFamilyName"));
    try std.testing.expectEqual(15, slot(dwrite.IDWriteFactory, "CreateTextFormat"));
    try std.testing.expectEqual(18, slot(dwrite.IDWriteFactory, "CreateTextLayout"));
    try std.testing.expectEqual(20, slot(dwrite.IDWriteFactory, "CreateEllipsisTrimmingSign"));
    try std.testing.expectEqual(3, slot(dwrite.IDWriteTextFormat, "SetTextAlignment"));
    try std.testing.expectEqual(4, slot(dwrite.IDWriteTextFormat, "SetParagraphAlignment"));
    try std.testing.expectEqual(5, slot(dwrite.IDWriteTextFormat, "SetWordWrapping"));
    try std.testing.expectEqual(9, slot(dwrite.IDWriteTextFormat, "SetTrimming"));
    try std.testing.expectEqual(28, slot(dwrite.IDWriteTextLayout, "SetMaxWidth"));
    try std.testing.expectEqual(60, slot(dwrite.IDWriteTextLayout, "GetMetrics"));
}

test "win32 d2d: struct layouts" {
    // sizeof values from a throwaway zig c++ program over the SDK headers.
    try std.testing.expectEqual(28, @sizeOf(d2d1.D2D1_RENDER_TARGET_PROPERTIES));
    try std.testing.expectEqual(24, @sizeOf(d2d1.D2D1_HWND_RENDER_TARGET_PROPERTIES));
    try std.testing.expectEqual(24, @sizeOf(d2d1.D2D1_ROUNDED_RECT));
    try std.testing.expectEqual(24, @sizeOf(d2d1.D2D1_MATRIX_3X2_F));
    try std.testing.expectEqual(16, @sizeOf(d2d1.D2D1_COLOR_F));
    try std.testing.expectEqual(8, @sizeOf(d2d1.D2D1_PIXEL_FORMAT));
    try std.testing.expectEqual(12, @sizeOf(dwrite.DWRITE_TRIMMING));
    try std.testing.expectEqual(36, @sizeOf(dwrite.DWRITE_TEXT_METRICS));
    try std.testing.expectEqual(32, @offsetOf(dwrite.DWRITE_TEXT_METRICS, "lineCount"));
}

test "win32 d2d: EndDraw maps RECREATE_TARGET to DeviceLost" {
    try std.testing.expectError(error.DeviceLost, d2d1.checkEndDraw(d2d1.D2DERR_RECREATE_TARGET));
    try d2d1.checkEndDraw(0);
}

test "win32 d2d: DC render target draws into a premultiplied DIB" {
    const width = 64;
    const height = 32;

    const factory = try d2d1.createFactory();
    defer com.release(factory);
    const dwrite_factory = try dwrite.createFactory();
    defer com.release(dwrite_factory);

    const dc = gdi32.CreateCompatibleDC(null) orelse return error.SkipZigTest;
    defer _ = gdi32.DeleteDC(dc);

    // Top-down 32bpp DIB.
    const info: gdi32.BITMAPINFO = .{ .bmiHeader = .{
        .biWidth = width,
        .biHeight = -height,
        .biBitCount = 32,
    } };
    var bits: ?*anyopaque = null;
    const bitmap = gdi32.CreateDIBSection(dc, &info, gdi32.DIB_RGB_COLORS, &bits, null, 0) orelse return error.SkipZigTest;
    defer _ = gdi32.DeleteObject(@ptrCast(bitmap));
    const old = gdi32.SelectObject(dc, @ptrCast(bitmap));
    defer if (old) |o| {
        _ = gdi32.SelectObject(dc, o);
    };
    const pixels: [*]const [4]u8 = @ptrCast(bits.?);

    const target = try factory.createDCRenderTarget(.{
        .type = .SOFTWARE,
        .pixelFormat = .{ .format = .B8G8R8A8_UNORM, .alphaMode = .PREMULTIPLIED },
    });
    defer com.release(target);
    try target.bindDC(dc, .{ .left = 0, .top = 0, .right = width, .bottom = height });
    const rt = target.asRenderTarget();

    const red = try rt.createSolidColorBrush(.{ .r = 1, .g = 0, .b = 0, .a = 1 });
    defer com.release(red);
    const white = try rt.createSolidColorBrush(.{ .r = 0, .g = 0, .b = 0, .a = 1 });
    defer com.release(white);
    white.setColor(.{ .r = 1, .g = 1, .b = 1, .a = 1 });

    const format = try dwrite_factory.createTextFormat(
        std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI"),
        .NORMAL,
        .NORMAL,
        .NORMAL,
        14,
        std.unicode.utf8ToUtf16LeStringLiteral("en-us"),
    );
    defer com.release(format);
    try format.setWordWrapping(.NO_WRAP);
    try format.setTextAlignment(.LEADING);
    try format.setParagraphAlignment(.NEAR);
    const sign = try dwrite_factory.createEllipsisTrimmingSign(format);
    defer com.release(sign);
    try format.setTrimming(.{ .granularity = .CHARACTER }, sign);

    const text = std.unicode.utf8ToUtf16LeStringLiteral("Ab");
    const layout = try dwrite_factory.createTextLayout(text[0..2], format, 36, height);
    defer com.release(layout);
    try layout.setMaxWidth(36);
    const metrics = try layout.getMetrics();
    try std.testing.expect(metrics.width > 0);
    try std.testing.expectEqual(1, metrics.lineCount);

    rt.beginDraw();
    rt.setTextAntialiasMode(.GRAYSCALE);
    rt.clear(.{ .r = 0, .g = 0, .b = 0, .a = 0 });
    rt.fillRectangle(.{ .left = 0, .top = 0, .right = 16, .bottom = 32 }, red.asBrush());
    rt.drawTextLayout(.{ .x = 24, .y = 4 }, layout, white.asBrush(), d2d1.DRAW_TEXT_OPTIONS_NONE);
    try rt.endDraw();

    // Opaque red, as BGRA.
    try std.testing.expectEqual([4]u8{ 0, 0, 255, 255 }, pixels[16 * width + 8]);
    // Untouched area stays transparent.
    try std.testing.expectEqual(0, pixels[2 * width + 62][3]);
    // The text left some coverage in its span.
    var inked = false;
    for (0..height) |y| {
        for (24..60) |x| {
            if (pixels[y * width + x][3] > 0) inked = true;
        }
    }
    try std.testing.expect(inked);
}
