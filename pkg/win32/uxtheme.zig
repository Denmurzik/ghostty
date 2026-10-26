//! uxtheme bindings (window themes, buffered paint). Filled by the tasks that first call them.

const foundation = @import("foundation.zig");

/// Select a visual style for a window ("DarkMode_Explorer" for dark scrollbars); null, null restores the default.
pub extern "uxtheme" fn SetWindowTheme(foundation.HWND, sub_app_name: ?[*:0]const u16, sub_id_list: ?[*:0]const u16) callconv(.winapi) foundation.HRESULT;
