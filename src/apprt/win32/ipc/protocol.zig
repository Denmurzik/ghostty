//! IPC wire protocol: framing, requests, responses. Std only so that the
//! tmux shim can import this file as a module.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const version: u32 = 1;

/// Wire limit (tmux payloads in M4).
pub const max_frame: u32 = 16 << 20;

/// What the M2 server accepts; the JSON is parsed on the UI thread.
pub const max_request_m2: u32 = 64 << 10;

/// Frame: u32 LE length followed by the payload bytes.
pub fn writeFrame(w: *std.Io.Writer, payload: []const u8) !void {
    if (payload.len > max_frame) return error.FrameTooLarge;
    try w.writeInt(u32, @intCast(payload.len), .little);
    try w.writeAll(payload);
}

/// `max` is checked before allocating: the server passes `max_request_m2`.
pub fn readFrame(r: *std.Io.Reader, alloc: Allocator, max: u32) ![]u8 {
    const len = try r.takeInt(u32, .little);
    if (len > @min(max, max_frame)) return error.FrameTooLarge;
    const buf = try alloc.alloc(u8, len);
    errdefer alloc.free(buf);
    try r.readSliceAll(buf);
    return buf;
}

pub const Code = enum(u8) {
    ok = 0,
    failed = 1,
    bad_request = 2,
    version_mismatch = 3,
};

pub const Request = struct {
    v: u32,
    op: []const u8,
    args: []const []const u8 = &.{},
    core_surface: []const u8 = "0",
    surface: u32 = 0,
    window: u32 = 0,
    action: []const u8 = "",
    dpi: u32 = 0,
    scheme: []const u8 = "",
    /// `export-io` (test op): the text to export and the file it goes to.
    text: []const u8 = "",
    path: []const u8 = "",
    /// GetTickCount64() value after which the server must not act; 0 = none.
    deadline_ms: u64 = 0,
};

pub fn expired(req: Request, now_ms: u64) bool {
    return req.deadline_ms != 0 and now_ms > req.deadline_ms;
}

pub fn parseRequest(
    arena: Allocator,
    bytes: []const u8,
) error{ BadRequest, OutOfMemory }!Request {
    return std.json.parseFromSliceLeaky(Request, arena, bytes, .{
        .ignore_unknown_fields = true,
    }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.BadRequest,
    };
}

pub fn encodeRequest(alloc: Allocator, req: Request) ![]u8 {
    return std.json.Stringify.valueAlloc(alloc, req, .{});
}

pub const Response = struct {
    code: Code,
    stdout: []const u8,
    stderr: []const u8,
    data_json: ?[]const u8,
};

pub fn encodeResponse(
    alloc: Allocator,
    code: Code,
    stdout: []const u8,
    stderr: []const u8,
    data_json: ?[]const u8,
) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(alloc);
    errdefer aw.deinit();
    var jw: std.json.Stringify = .{ .writer = &aw.writer };
    try jw.beginObject();
    try jw.objectField("v");
    try jw.write(version);
    try jw.objectField("code");
    try jw.write(@backingInt(code));
    try jw.objectField("stdout");
    try jw.write(stdout);
    try jw.objectField("stderr");
    try jw.write(stderr);
    try jw.objectField("data");
    if (data_json) |d| {
        try jw.beginWriteRaw();
        try aw.writer.writeAll(d);
        jw.endWriteRaw();
    } else {
        try jw.write(null);
    }
    try jw.endObject();
    return aw.toOwnedSlice();
}

pub fn parseResponse(arena: Allocator, bytes: []const u8) !Response {
    const Wire = struct {
        v: u32,
        code: u8,
        stdout: []const u8 = "",
        stderr: []const u8 = "",
        data: std.json.Value = .null,
    };
    const wire = std.json.parseFromSliceLeaky(Wire, arena, bytes, .{
        .ignore_unknown_fields = true,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.BadResponse,
    };
    const code = std.enums.fromInt(Code, wire.code) orelse return error.BadResponse;
    const data_json: ?[]const u8 = switch (wire.data) {
        .null => null,
        else => try std.json.Stringify.valueAlloc(arena, wire.data, .{}),
    };
    return .{
        .code = code,
        .stdout = wire.stdout,
        .stderr = wire.stderr,
        .data_json = data_json,
    };
}

pub const max_class_len = 80;

/// Keeps [A-Za-z0-9._-], every other byte becomes '_'; at most 80 bytes.
pub fn sanitizeClass(buf: []u8, class: []const u8) []const u8 {
    const n = @min(class.len, @min(buf.len, max_class_len));
    for (class[0..n], buf[0..n]) |c, *out| {
        out.* = switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9', '.', '_', '-' => c,
            else => '_',
        };
    }
    return buf[0..n];
}

/// `\\.\pipe\ghostty-<sid>-<session>-<u|a>-<class>`: the marker segment (`a`
/// elevated, `u` not) precedes the class, so a class can never mimic it.
pub fn pipeName(
    buf: []u8,
    sid: []const u8,
    session: u32,
    class: []const u8,
    elevated: bool,
) ![]const u8 {
    var class_buf: [max_class_len]u8 = undefined;
    return std.fmt.bufPrint(buf, "\\\\.\\pipe\\ghostty-{s}-{d}-{c}-{s}", .{
        sid,
        session,
        @as(u8, if (elevated) 'a' else 'u'),
        sanitizeClass(&class_buf, class),
    });
}

test "win32 ipc protocol: frame roundtrip and limits" {
    const testing = std.testing;
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try writeFrame(&aw.writer, "{}");
    try testing.expectEqualSlices(u8, &.{ 2, 0, 0, 0, '{', '}' }, aw.written());

    var r: std.Io.Reader = .fixed(aw.written());
    const got = try readFrame(&r, testing.allocator, max_frame);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("{}", got);

    var big: std.Io.Reader = .fixed(&.{ 1, 0, 0, 1 }); // 16 MiB + 1
    try testing.expectError(error.FrameTooLarge, readFrame(&big, testing.allocator, max_frame));

    var m2: std.Io.Reader = .fixed(&.{ 0x00, 0x04, 0x01, 0, 0 }); // 65 KiB header
    try testing.expectError(error.FrameTooLarge, readFrame(&m2, testing.allocator, max_request_m2));

    var trunc: std.Io.Reader = .fixed(&.{ 2, 0 });
    try testing.expectError(error.EndOfStream, readFrame(&trunc, testing.allocator, max_frame));

    var short: std.Io.Reader = .fixed(&.{ 5, 0, 0, 0, 'a' });
    try testing.expectError(error.EndOfStream, readFrame(&short, testing.allocator, max_frame));
}

test "win32 ipc protocol: request parse ignores unknown fields" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const req = try parseRequest(
        arena.allocator(),
        "{\"v\":1,\"op\":\"new-window\",\"args\":[\"--title=a\"],\"zzz\":3}",
    );
    try std.testing.expectEqualStrings("new-window", req.op);
    try std.testing.expectEqual(@as(usize, 1), req.args.len);
    try std.testing.expectEqualStrings("--title=a", req.args[0]);
}

test "win32 ipc protocol: bad request" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.BadRequest, parseRequest(arena.allocator(), "not json"));
    try std.testing.expectError(error.BadRequest, parseRequest(arena.allocator(), "{\"op\":1}"));
}

test "win32 ipc protocol: response with data" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const bytes = try encodeResponse(testing.allocator, .ok, "", "", "{\"a\":1}");
    defer testing.allocator.free(bytes);
    const resp = try parseResponse(arena.allocator(), bytes);
    try testing.expectEqual(Code.ok, resp.code);
    try testing.expectEqualStrings("{\"a\":1}", resp.data_json.?);

    const none = try encodeResponse(testing.allocator, .failed, "o\n", "e", null);
    defer testing.allocator.free(none);
    const r2 = try parseResponse(arena.allocator(), none);
    try testing.expectEqual(Code.failed, r2.code);
    try testing.expectEqualStrings("o\n", r2.stdout);
    try testing.expectEqualStrings("e", r2.stderr);
    try testing.expect(r2.data_json == null);
}

test "win32 ipc protocol: pipe name has the elevation marker" {
    const t = std.testing;
    var b1: [256]u8 = undefined;
    var b2: [256]u8 = undefined;
    const admin = try pipeName(&b1, "S-1", 1, "c", true);
    try t.expectEqualStrings("\\\\.\\pipe\\ghostty-S-1-1-a-c", admin);
    const normal = try pipeName(&b2, "S-1", 1, "c", false);
    try t.expectEqualStrings("\\\\.\\pipe\\ghostty-S-1-1-u-c", normal);
    // A class can never mimic the other instance's pipe.
    const spoof = try pipeName(&b2, "S-1", 1, "x-admin", false);
    const real = try pipeName(&b1, "S-1", 1, "x", true);
    try t.expect(!std.mem.eql(u8, spoof, real));
}

test "win32 ipc protocol: deadline" {
    const testing = std.testing;
    try testing.expect(!expired(.{ .v = 1, .op = "x" }, std.math.maxInt(u64)));
    const r: Request = .{ .v = 1, .op = "x", .deadline_ms = 1000 };
    try testing.expect(!expired(r, 1000));
    try testing.expect(expired(r, 1001));

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const bytes = try encodeRequest(testing.allocator, r);
    defer testing.allocator.free(bytes);
    const back = try parseRequest(arena.allocator(), bytes);
    try testing.expectEqual(@as(u64, 1000), back.deadline_ms);
    try testing.expectEqualStrings("x", back.op);
}

test "win32 ipc protocol: pipe name sanitizes class" {
    const testing = std.testing;
    var buf: [256]u8 = undefined;
    const name = try pipeName(&buf, "S-1-5-21-1", 1, "com.mitchellh.ghostty", false);
    try testing.expectEqualStrings("\\\\.\\pipe\\ghostty-S-1-5-21-1-1-u-com.mitchellh.ghostty", name);

    var cb: [80]u8 = undefined;
    try testing.expectEqualStrings("a_b___", sanitizeClass(&cb, "a b/ж"));
    const long: [200]u8 = @splat('x');
    try testing.expectEqual(@as(usize, 80), sanitizeClass(&cb, &long).len);
}
