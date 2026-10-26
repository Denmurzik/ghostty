//! winmm bindings (system sounds). Filled by the tasks that first call them.

const foundation = @import("foundation.zig");

/// `fdwSound` flags of `PlaySoundW`.
pub const SND_ASYNC = 0x0001;
pub const SND_NODEFAULT = 0x0002;
pub const SND_PURGE = 0x0040;
pub const SND_FILENAME = 0x00020000;

pub extern "winmm" fn PlaySoundW(
    sound: ?[*:0]const u16,
    module: ?foundation.HMODULE,
    flags: u32,
) callconv(.winapi) foundation.BOOL;
