//! `ghostty-explorer.dll`: the in-process COM server of the Windows 11
//! top-level "Open Ghostty here" entry. Only the two COM entry points are
//! exported; registration is the sparse package's job (R-M7-13).
const com = @import("com.zig");
const command = @import("command.zig");

pub export fn DllGetClassObject(rclsid: ?*const com.GUID, riid: ?*const com.GUID, ppv: ?*?*anyopaque) callconv(.winapi) com.HRESULT {
    return command.getClassObject(rclsid, riid, ppv);
}

pub export fn DllCanUnloadNow() callconv(.winapi) com.HRESULT {
    return command.canUnloadNow();
}

// The DLL needs no process or thread attach work. Declaring the entry points
// here (public but not exported) keeps std from emitting its own
// `DllMainCRTStartup`, which would add the CRT and TLS symbols to the export
// table; the build disables the entry point (`/NOENTRY`).
pub fn DllMainCRTStartup() void {}
pub fn _DllMainCRTStartup() void {}

test {
    _ = com;
    _ = command;
    _ = @import("ids.zig");
}
