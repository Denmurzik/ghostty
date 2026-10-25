//! Windows command line parsing and joining with the rules of the MS C
//! runtime. Shared by the `command` config (`direct:` values), the `.shell`
//! command form and the process spawner.

const std = @import("std");
const mem = std.mem;
const Allocator = std.mem.Allocator;

/// Split a Windows command line into arguments with the rules of the
/// MS C runtime (`CommandLineToArgvW` agrees except for the program name):
///
///   - Arguments are separated by spaces and tabs outside of quotes.
///   - A quote toggles quoting; inside quotes, `""` is a literal quote.
///   - 2n backslashes followed by a quote are n backslashes and the quote
///     toggles quoting; 2n+1 are n backslashes and a literal quote.
///     Backslashes not followed by a quote are literal.
///   - The first argument (the program name) has no escapes: quotes only
///     toggle quoting, so a path may end in a backslash.
///
/// The caller owns the result: each argument and the slice itself.
pub fn tokenizeWindows(alloc: Allocator, s: []const u8) Allocator.Error![][:0]const u8 {
    var args: std.ArrayList([:0]const u8) = .empty;
    errdefer {
        for (args.items) |arg| alloc.free(arg);
        args.deinit(alloc);
    }

    var i: usize = 0;
    while (true) {
        while (i < s.len and (s[i] == ' ' or s[i] == '\t')) i += 1;
        if (i == s.len) break;

        var arg: std.ArrayList(u8) = .empty;
        defer arg.deinit(alloc);

        const is_program = args.items.len == 0;
        var in_quotes = false;
        while (i < s.len) {
            const ch = s[i];
            if (!in_quotes and (ch == ' ' or ch == '\t')) break;

            if (ch == '\\' and !is_program) {
                var n: usize = 0;
                while (i < s.len and s[i] == '\\') : (i += 1) n += 1;
                if (i < s.len and s[i] == '"') {
                    try arg.appendNTimes(alloc, '\\', n / 2);
                    if (n % 2 == 1) {
                        try arg.append(alloc, '"');
                        i += 1;
                    }
                    // Otherwise the quote is left for the next round
                    // to toggle quoting.
                } else {
                    try arg.appendNTimes(alloc, '\\', n);
                }
                continue;
            }

            if (ch == '"') {
                i += 1;
                if (in_quotes and !is_program and i < s.len and s[i] == '"') {
                    try arg.append(alloc, '"');
                    i += 1;
                } else {
                    in_quotes = !in_quotes;
                }
                continue;
            }

            try arg.append(alloc, ch);
            i += 1;
        }

        const owned = try alloc.dupeSentinel(u8, arg.items, 0);
        errdefer alloc.free(owned);
        try args.append(alloc, owned);
    }

    return try args.toOwnedSlice(alloc);
}

/// Join arguments into a Windows command line that the MS C runtime rules
/// (see `tokenizeWindows`) split back into the same arguments. Adapted from
/// Zig's child_process.
pub fn createCommandLine(allocator: mem.Allocator, argv: []const []const u8) ![:0]u8 {
    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    const writer = &buf.writer;

    for (argv, 0..) |arg, arg_i| {
        if (arg_i != 0) try writer.writeByte(' ');
        if (arg.len > 0 and mem.indexOfAny(u8, arg, " \t\n\"") == null) {
            try writer.writeAll(arg);
            continue;
        }
        try writer.writeByte('"');
        if (arg_i == 0) {
            // The program name has no escapes: its quotes only group, and
            // a path can't hold a quote anyway. Doubling backslashes would
            // change the path.
            try writer.writeAll(arg);
            try writer.writeByte('"');
            continue;
        }
        var backslash_count: usize = 0;
        for (arg) |byte| {
            switch (byte) {
                '\\' => backslash_count += 1,
                '"' => {
                    try writer.splatByteAll('\\', backslash_count * 2 + 1);
                    try writer.writeByte('"');
                    backslash_count = 0;
                },
                else => {
                    try writer.splatByteAll('\\', backslash_count);
                    try writer.writeByte(byte);
                    backslash_count = 0;
                },
            }
        }
        try writer.splatByteAll('\\', backslash_count * 2);
        try writer.writeByte('"');
    }

    return buf.toOwnedSliceSentinel(0);
}
