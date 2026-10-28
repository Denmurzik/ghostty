const std = @import("std");
const Allocator = std.mem.Allocator;
const explorer_integration = @import("explorer_integration.zig");

pub const Options = explorer_integration.UninstallOptions;

/// The `+uninstall-explorer-integration` command removes the "Open Ghostty
/// here" entries that `+install-explorer-integration` added to the Windows
/// Explorer context menu (the "Show more options" menu on Windows 11).
///
/// It deletes exactly the three `GhosttyOpenHere` keys under
/// `HKEY_CURRENT_USER\Software\Classes`, and only those whose command starts
/// with a quoted path to a file called `ghostty.exe`. A key that belongs to
/// something else is reported and kept.
///
/// Flags:
///
///   * `--dry-run`: Print every key that would be deleted and change nothing.
///
///   * `--all`: Also delete the notification registration
///     (`HKEY_CURRENT_USER\Software\Classes\AppUserModelId\<id>`) and the
///     toast icon under `%LOCALAPPDATA%\ghostty`. This is the full revert for
///     a portable copy.
///
/// Only supported on Windows.
pub fn run(alloc: Allocator) !u8 {
    return explorer_integration.runUninstall(alloc);
}
