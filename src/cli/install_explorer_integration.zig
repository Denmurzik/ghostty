const std = @import("std");
const Allocator = std.mem.Allocator;
const explorer_integration = @import("explorer_integration.zig");

pub const Options = explorer_integration.InstallOptions;

/// The `+install-explorer-integration` command adds an "Open Ghostty here"
/// entry to the Windows Explorer context menu of folders, of the background of
/// an open folder, and of drives. It writes three keys named
/// `GhosttyOpenHere` under `HKEY_CURRENT_USER\Software\Classes`; nothing needs
/// administrator rights and nothing outside the current user's registry
/// changes. The entry starts the Ghostty that ran this command, in the chosen
/// folder.
///
/// Windows 11 shows the entry under "Show more options" (the classic menu).
/// The top-level menu needs a packaged app and is not supported.
///
/// Running the command again rewrites the keys, so it also repairs them after
/// Ghostty was moved. `+uninstall-explorer-integration` removes them.
///
/// Flags:
///
///   * `--dry-run`: Print every key and value that would be written and
///     change nothing.
///
/// Only supported on Windows.
pub fn run(alloc: Allocator) !u8 {
    return explorer_integration.runInstall(alloc);
}
