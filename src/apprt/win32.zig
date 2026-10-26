// The required comptime API for any apprt.
pub const App = @import("win32/App.zig");
pub const Surface = @import("win32/Surface.zig");
pub const resourcesDir = @import("../os/main.zig").resourcesDir;

test {
    @import("std").testing.refAllDecls(@This());
    _ = App;
    _ = Surface;
    _ = @import("win32/geom.zig");
    _ = @import("win32/messages.zig");
    _ = @import("win32/Overrides.zig");
    _ = @import("win32/instance.zig");
    _ = @import("win32/SplitLayout.zig");
    _ = @import("win32/TabStrip.zig");
    _ = @import("win32/frame.zig");
    _ = @import("win32/Chrome.zig");
    _ = @import("win32/strip_input.zig");
    _ = @import("win32/title_edit.zig");
    _ = @import("win32/theme.zig");
    _ = @import("win32/placement.zig");
    _ = @import("win32/scrollbar.zig");
    _ = @import("win32/bell.zig");
    _ = @import("win32/taskbar.zig");
    _ = @import("win32/resize_overlay.zig");
    _ = @import("win32/tab_drag.zig");
    _ = @import("win32/drag_ghost.zig");
    _ = @import("win32/drop.zig");
    _ = @import("win32/ipc/protocol.zig");
    _ = @import("win32/ipc/Server.zig");
    _ = @import("win32/ipc/client.zig");
    _ = @import("win32/ipc/ops.zig");
}
