//! wtsapi32 bindings: session change notifications (lock, unlock, console
//! and remote connect and disconnect).
const foundation = @import("foundation.zig");
const HWND = foundation.HWND;
const BOOL = foundation.BOOL;

/// Only the session of the calling process (not every session).
pub const NOTIFY_FOR_THIS_SESSION: u32 = 0;

// `wParam` of WM_WTSSESSION_CHANGE
pub const WTS_CONSOLE_CONNECT: usize = 0x1;
pub const WTS_CONSOLE_DISCONNECT: usize = 0x2;
pub const WTS_REMOTE_CONNECT: usize = 0x3;
pub const WTS_REMOTE_DISCONNECT: usize = 0x4;
pub const WTS_SESSION_LOGON: usize = 0x5;
pub const WTS_SESSION_LOGOFF: usize = 0x6;
pub const WTS_SESSION_LOCK: usize = 0x7;
pub const WTS_SESSION_UNLOCK: usize = 0x8;

pub extern "wtsapi32" fn WTSRegisterSessionNotification(HWND, flags: u32) callconv(.winapi) BOOL;
pub extern "wtsapi32" fn WTSUnRegisterSessionNotification(HWND) callconv(.winapi) BOOL;
