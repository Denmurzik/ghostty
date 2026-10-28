//! The SHA-256 pins of the vendored ConPTY files, read from the table in
//! `vendor/conpty/README.md` (`| `x64/conpty.dll` | package path | `hash` |`).
//! std-only so that the build script and the tests can both use it.

const std = @import("std");

/// The pinned hash (64 lowercase hex digits) of `file` (e.g. `x64/conpty.dll`),
/// or null when the table has no such row.
pub fn pinFor(readme: []const u8, file: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, readme, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, "|")) continue;
        var cols = std.mem.splitScalar(u8, line, '|');
        _ = cols.next(); // before the first bar
        const name = unquote(cols.next() orelse continue) orelse continue;
        if (!std.mem.eql(u8, name, file)) continue;
        _ = cols.next() orelse continue; // package path
        const hash = unquote(cols.next() orelse continue) orelse continue;
        if (hash.len != 64) continue;
        for (hash) |c| switch (c) {
            '0'...'9', 'a'...'f' => {},
            else => break,
        } else return hash;
    }
    return null;
}

/// A table cell that is one code span: its text, else null.
fn unquote(cell: []const u8) ?[]const u8 {
    const t = std.mem.trim(u8, cell, " \t");
    if (t.len < 2 or t[0] != '`' or t[t.len - 1] != '`') return null;
    return t[1 .. t.len - 1];
}

/// Whether the SHA-256 of `bytes` is the lowercase hex `pin`.
pub fn matches(bytes: []const u8, pin: []const u8) bool {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.mem.eql(u8, &hex, pin);
}

const sample =
    \\| File | Package path | SHA-256 |
    \\|---|---|---|
    \\| `x64/conpty.dll` | `runtimes/win-x64/native/conpty.dll` | `feeef341d891643c62d30b6b07800bc70f0bc148f44cb8c3bee84aa557ae805a` |
    \\| `arm64/OpenConsole.exe` | `build/native/runtimes/arm64/OpenConsole.exe` | `4313825a3ba634d113cc6ed3bc8ce735e3c19d360cecd985794787479469f91f` |
    \\| `x64/bad.dll` | `p` | `XYZ` |
;

test "conpty pins: rows are found by file name" {
    try std.testing.expectEqualStrings(
        "feeef341d891643c62d30b6b07800bc70f0bc148f44cb8c3bee84aa557ae805a",
        pinFor(sample, "x64/conpty.dll").?,
    );
    try std.testing.expectEqualStrings(
        "4313825a3ba634d113cc6ed3bc8ce735e3c19d360cecd985794787479469f91f",
        pinFor(sample, "arm64/OpenConsole.exe").?,
    );
    try std.testing.expect(pinFor(sample, "arm64/conpty.dll") == null);
    try std.testing.expect(pinFor(sample, "x64/bad.dll") == null);
    try std.testing.expect(pinFor("", "x64/conpty.dll") == null);
}

test "conpty pins: hash comparison" {
    // SHA-256 of the empty string.
    const empty = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
    try std.testing.expect(matches("", empty));
    try std.testing.expect(!matches("x", empty));
}
