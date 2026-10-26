//! Split actions.
const std = @import("std");
const win32 = @import("win32");
const apprt = @import("../../../apprt.zig");
const App = @import("../App.zig");
const SplitLayout = @import("../SplitLayout.zig");
const Surface = @import("../Surface.zig");

const log = std.log.scoped(.win32_actions);

fn surfaceOf(app: *App, target: apprt.Target) ?*Surface {
    return switch (target) {
        .app => null,
        .surface => |core| app.surfaceFor(core),
    };
}

pub fn new_split(app: *App, target: apprt.Target, value: apprt.Action.Value(.new_split)) !bool {
    const surface = surfaceOf(app, target) orelse return false;
    const direction: Surface.Tree.Split.Direction = switch (value) {
        .right => .right,
        .down => .down,
        .left => .left,
        .up => .up,
    };
    _ = try surface.tab.split(surface, direction);
    return true;
}

pub fn goto_split(app: *App, target: apprt.Target, value: apprt.Action.Value(.goto_split)) !bool {
    const surface = surfaceOf(app, target) orelse return false;
    const tab = surface.tab;
    const alloc = app.core_app.alloc;
    const from = tab.handleOf(surface) orelse return false;

    const to: Surface.Tree.Goto = switch (value) {
        .previous => .previous_wrapped,
        .next => .next_wrapped,
        .up => .{ .spatial = .up },
        .left => .{ .spatial = .left },
        .down => .{ .spatial = .down },
        .right => .{ .spatial = .right },
    };
    const dest_handle = (try tab.tree.goto(alloc, from, to)) orelse return false;
    if (dest_handle == from) return false;
    const dest = switch (tab.tree.nodes[dest_handle.idx()]) {
        .leaf => |v| v,
        .split => return false,
    };

    if (tab.tree.zoomed != null) {
        tab.tree.zoom(if (app.config.@"split-preserve-zoom".navigation) dest_handle else null);
        tab.layout();
    }

    tab.focused = dest;
    if (tab.window.activeTab() == tab) tab.focus();
    return true;
}

pub fn resize_split(app: *App, target: apprt.Target, value: apprt.Action.Value(.resize_split)) !bool {
    const surface = surfaceOf(app, target) orelse return false;
    const tab = surface.tab;
    if (value.amount == 0) return false;
    const from = tab.handleOf(surface) orelse return false;

    const rect = tab.window.contentRect();
    const bounds: @import("../geom.zig").Rect = .{ .w = rect.w, .h = rect.h };
    const ratio = switch (value.direction) {
        .left => SplitLayout.resizeRatio(.left, value.amount, bounds),
        .right => SplitLayout.resizeRatio(.right, value.amount, bounds),
        .up => SplitLayout.resizeRatio(.up, value.amount, bounds),
        .down => SplitLayout.resizeRatio(.down, value.amount, bounds),
    };
    if (ratio == 0) return false;
    const layout: Surface.Tree.Split.Layout = switch (value.direction) {
        .left, .right => .horizontal,
        .up, .down => .vertical,
    };

    const new_tree = try tab.tree.resize(app.core_app.alloc, from, layout, ratio);
    tab.replaceTree(new_tree);
    return true;
}

pub fn equalize_splits(app: *App, target: apprt.Target, value: apprt.Action.Value(.equalize_splits)) !bool {
    _ = value;
    const surface = surfaceOf(app, target) orelse return false;
    const tab = surface.tab;
    if (!tab.tree.isSplit()) return false;
    const new_tree = try tab.tree.equalize(app.core_app.alloc);
    tab.replaceTree(new_tree);
    return true;
}

pub fn toggle_split_zoom(app: *App, target: apprt.Target, value: apprt.Action.Value(.toggle_split_zoom)) !bool {
    _ = value;
    const surface = surfaceOf(app, target) orelse return false;
    const tab = surface.tab;
    if (!tab.tree.isSplit()) return false;
    const handle = tab.handleOf(surface) orelse return false;

    tab.tree.zoom(if (tab.tree.zoomed == handle) null else handle);
    tab.layout();
    tab.focused = surface;
    if (tab.window.activeTab() == tab) tab.focus();
    return true;
}
