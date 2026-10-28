//! user32 bindings: windows, messages, input, keyboard layouts, clipboard
//! and timers. Wide (W) variants only; every function is `callconv(.winapi)`
//! and returns that can be NULL are declared as optionals.
const foundation = @import("foundation.zig");
const BOOL = foundation.BOOL;
const HWND = foundation.HWND;
const HINSTANCE = foundation.HINSTANCE;
const HANDLE = foundation.HANDLE;
const WPARAM = foundation.WPARAM;
const LPARAM = foundation.LPARAM;
const LRESULT = foundation.LRESULT;
const RECT = foundation.RECT;
const POINT = foundation.POINT;

pub const ATOM = u16;
pub const HKL = *opaque {};
pub const HICON = *opaque {};
pub const HCURSOR = *opaque {};
pub const HBRUSH = *opaque {};
pub const HMENU = *opaque {};
pub const HDC = *opaque {};
pub const HMONITOR = *opaque {};
pub const HRGN = *opaque {};
pub const HDWP = *opaque {};

pub const WNDPROC = *const fn (HWND, u32, WPARAM, LPARAM) callconv(.winapi) LRESULT;
pub const WNDENUMPROC = *const fn (HWND, LPARAM) callconv(.winapi) BOOL;
pub const TIMERPROC = *const fn (?HWND, u32, usize, u32) callconv(.winapi) void;

pub const WNDCLASSEXW = extern struct {
    cbSize: u32 = @sizeOf(WNDCLASSEXW),
    style: u32 = 0,
    lpfnWndProc: ?WNDPROC = null,
    cbClsExtra: i32 = 0,
    cbWndExtra: i32 = 0,
    hInstance: ?HINSTANCE = null,
    hIcon: ?HICON = null,
    hCursor: ?HCURSOR = null,
    hbrBackground: ?HBRUSH = null,
    lpszMenuName: ?[*:0]const u16 = null,
    lpszClassName: ?[*:0]const u16 = null,
    hIconSm: ?HICON = null,
};

pub const MSG = extern struct {
    hwnd: ?HWND = null,
    message: u32 = 0,
    wParam: WPARAM = 0,
    lParam: LPARAM = 0,
    time: u32 = 0,
    pt: POINT = .{ .x = 0, .y = 0 },
};

pub const CREATESTRUCTW = extern struct {
    lpCreateParams: ?*anyopaque,
    hInstance: ?HINSTANCE,
    hMenu: ?HMENU,
    hwndParent: ?HWND,
    cy: i32,
    cx: i32,
    y: i32,
    x: i32,
    style: i32,
    lpszName: ?[*:0]const u16,
    lpszClass: ?[*:0]const u16,
    dwExStyle: u32,
};

pub const MINMAXINFO = extern struct {
    ptReserved: POINT,
    ptMaxSize: POINT,
    ptMaxPosition: POINT,
    ptMinTrackSize: POINT,
    ptMaxTrackSize: POINT,
};

pub const TRACKMOUSEEVENT = extern struct {
    cbSize: u32 = @sizeOf(TRACKMOUSEEVENT),
    dwFlags: u32,
    hwndTrack: ?HWND,
    dwHoverTime: u32 = 0,
};

pub const KEYBDINPUT = extern struct {
    wVk: u16,
    wScan: u16,
    dwFlags: u32,
    time: u32 = 0,
    dwExtraInfo: usize = 0,
};

pub const MOUSEINPUT = extern struct {
    dx: i32,
    dy: i32,
    mouseData: u32,
    dwFlags: u32,
    time: u32 = 0,
    dwExtraInfo: usize = 0,
};

pub const HARDWAREINPUT = extern struct {
    uMsg: u32,
    wParamL: u16,
    wParamH: u16,
};

pub const INPUT = extern struct {
    type: u32,
    u: extern union {
        mi: MOUSEINPUT,
        ki: KEYBDINPUT,
        hi: HARDWAREINPUT,
    },
};

pub const PAINTSTRUCT = extern struct {
    hdc: ?HDC,
    fErase: BOOL,
    rcPaint: RECT,
    fRestore: BOOL,
    fIncUpdate: BOOL,
    rgbReserved: [32]u8,
};

pub const SIZE = extern struct {
    cx: i32,
    cy: i32,
};

pub const WINDOWPOS = extern struct {
    hwnd: ?HWND,
    hwndInsertAfter: ?HWND,
    x: i32,
    y: i32,
    cx: i32,
    cy: i32,
    flags: u32,
};

pub const WINDOWPLACEMENT = extern struct {
    length: u32 = @sizeOf(WINDOWPLACEMENT),
    flags: u32 = 0,
    showCmd: u32 = 0,
    ptMinPosition: POINT = .{ .x = 0, .y = 0 },
    ptMaxPosition: POINT = .{ .x = 0, .y = 0 },
    rcNormalPosition: RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
};

pub const MONITORINFO = extern struct {
    cbSize: u32 = @sizeOf(MONITORINFO),
    rcMonitor: RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
    rcWork: RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
    dwFlags: u32 = 0,
};

pub const SCROLLINFO = extern struct {
    cbSize: u32 = @sizeOf(SCROLLINFO),
    fMask: u32 = 0,
    nMin: i32 = 0,
    nMax: i32 = 0,
    nPage: u32 = 0,
    nPos: i32 = 0,
    nTrackPos: i32 = 0,
};

pub const FLASHWINFO = extern struct {
    cbSize: u32 = @sizeOf(FLASHWINFO),
    hwnd: ?HWND,
    dwFlags: u32,
    uCount: u32 = 0,
    dwTimeout: u32 = 0,
};

pub const NCCALCSIZE_PARAMS = extern struct {
    rgrc: [3]RECT,
    lppos: ?*WINDOWPOS,
};

pub const BLENDFUNCTION = extern struct {
    BlendOp: u8 = AC_SRC_OVER,
    BlendFlags: u8 = 0,
    SourceConstantAlpha: u8 = 255,
    AlphaFormat: u8 = 0,
};

pub const HIGHCONTRASTW = extern struct {
    cbSize: u32 = @sizeOf(HIGHCONTRASTW),
    dwFlags: u32 = 0,
    lpszDefaultScheme: ?[*:0]u16 = null,
};

pub const CHANGEFILTERSTRUCT = extern struct {
    cbSize: u32 = @sizeOf(CHANGEFILTERSTRUCT),
    ExtStatus: u32 = 0,
};

pub const TPMPARAMS = extern struct {
    cbSize: u32 = @sizeOf(TPMPARAMS),
    rcExclude: RECT,
};

// -- Windows and messages --------------------------------------------------

pub extern "user32" fn RegisterClassExW(*const WNDCLASSEXW) callconv(.winapi) ATOM;
pub extern "user32" fn UnregisterClassW(class_name: [*:0]const u16, instance: ?HINSTANCE) callconv(.winapi) BOOL;
pub extern "user32" fn CreateWindowExW(
    ex_style: u32,
    class_name: ?[*:0]const u16,
    window_name: ?[*:0]const u16,
    style: u32,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    parent: ?HWND,
    menu: ?HMENU,
    instance: ?HINSTANCE,
    param: ?*anyopaque,
) callconv(.winapi) ?HWND;
pub extern "user32" fn DestroyWindow(HWND) callconv(.winapi) BOOL;
pub extern "user32" fn DefWindowProcW(HWND, u32, WPARAM, LPARAM) callconv(.winapi) LRESULT;
/// Returns 0 for WM_QUIT, -1 on error.
pub extern "user32" fn GetMessageW(*MSG, ?HWND, min: u32, max: u32) callconv(.winapi) BOOL;
pub extern "user32" fn PeekMessageW(*MSG, ?HWND, min: u32, max: u32, remove: u32) callconv(.winapi) BOOL;
pub extern "user32" fn TranslateMessage(*const MSG) callconv(.winapi) BOOL;
pub extern "user32" fn DispatchMessageW(*const MSG) callconv(.winapi) LRESULT;
pub extern "user32" fn PostMessageW(?HWND, u32, WPARAM, LPARAM) callconv(.winapi) BOOL;
pub extern "user32" fn SendMessageW(HWND, u32, WPARAM, LPARAM) callconv(.winapi) LRESULT;
pub extern "user32" fn PostQuitMessage(exit_code: i32) callconv(.winapi) void;
pub extern "user32" fn GetMessageTime() callconv(.winapi) i32;
pub extern "user32" fn ShowWindow(HWND, cmd: i32) callconv(.winapi) BOOL;
pub extern "user32" fn UpdateWindow(HWND) callconv(.winapi) BOOL;
pub extern "user32" fn SetWindowPos(HWND, insert_after: ?HWND, x: i32, y: i32, cx: i32, cy: i32, flags: u32) callconv(.winapi) BOOL;
pub extern "user32" fn MoveWindow(HWND, x: i32, y: i32, w: i32, h: i32, repaint: BOOL) callconv(.winapi) BOOL;
pub extern "user32" fn GetClientRect(HWND, *RECT) callconv(.winapi) BOOL;
pub extern "user32" fn GetWindowRect(HWND, *RECT) callconv(.winapi) BOOL;
pub extern "user32" fn AdjustWindowRectExForDpi(*RECT, style: u32, menu: BOOL, ex_style: u32, dpi: u32) callconv(.winapi) BOOL;
pub extern "user32" fn GetDpiForWindow(HWND) callconv(.winapi) u32;
pub extern "user32" fn SetWindowLongPtrW(HWND, index: i32, value: isize) callconv(.winapi) isize;
pub extern "user32" fn GetWindowLongPtrW(HWND, index: i32) callconv(.winapi) isize;
pub extern "user32" fn SetWindowTextW(HWND, [*:0]const u16) callconv(.winapi) BOOL;
pub extern "user32" fn IsWindow(?HWND) callconv(.winapi) BOOL;
pub extern "user32" fn SetWindowRgn(HWND, ?HRGN, redraw: BOOL) callconv(.winapi) i32;
pub extern "user32" fn InvalidateRect(?HWND, ?*const RECT, erase: BOOL) callconv(.winapi) BOOL;
pub extern "user32" fn ValidateRect(?HWND, ?*const RECT) callconv(.winapi) BOOL;
pub extern "user32" fn BeginPaint(HWND, *PAINTSTRUCT) callconv(.winapi) ?HDC;
pub extern "user32" fn EndPaint(HWND, *const PAINTSTRUCT) callconv(.winapi) BOOL;
pub extern "user32" fn GetSystemMetricsForDpi(index: i32, dpi: u32) callconv(.winapi) i32;
pub extern "user32" fn MessageBeep(u32) callconv(.winapi) BOOL;
pub extern "user32" fn MessageBoxW(?HWND, text: ?[*:0]const u16, caption: ?[*:0]const u16, flags: u32) callconv(.winapi) i32;

// -- Cursor, mouse and focus -----------------------------------------------

/// `name` is either a string or a `MAKEINTRESOURCE` value such as `IDC_ARROW`.
pub extern "user32" fn LoadCursorW(?HINSTANCE, name: ?*const anyopaque) callconv(.winapi) ?HCURSOR;
pub extern "user32" fn LoadIconW(?HINSTANCE, name: ?*const anyopaque) callconv(.winapi) ?HICON;
pub extern "user32" fn SetCursor(?HCURSOR) callconv(.winapi) ?HCURSOR;
pub extern "user32" fn ShowCursor(show: BOOL) callconv(.winapi) i32;
pub extern "user32" fn SetCapture(HWND) callconv(.winapi) ?HWND;
pub extern "user32" fn ReleaseCapture() callconv(.winapi) BOOL;
pub extern "user32" fn TrackMouseEvent(*TRACKMOUSEEVENT) callconv(.winapi) BOOL;
pub extern "user32" fn GetCursorPos(*POINT) callconv(.winapi) BOOL;
pub extern "user32" fn ScreenToClient(HWND, *POINT) callconv(.winapi) BOOL;
pub extern "user32" fn ClientToScreen(HWND, *POINT) callconv(.winapi) BOOL;
pub extern "user32" fn WindowFromPoint(POINT) callconv(.winapi) ?HWND;
pub extern "user32" fn GetDoubleClickTime() callconv(.winapi) u32;
pub extern "user32" fn SetFocus(?HWND) callconv(.winapi) ?HWND;
pub extern "user32" fn GetFocus() callconv(.winapi) ?HWND;
pub extern "user32" fn SetForegroundWindow(HWND) callconv(.winapi) BOOL;
pub extern "user32" fn GetForegroundWindow() callconv(.winapi) ?HWND;
pub extern "user32" fn GetActiveWindow() callconv(.winapi) ?HWND;
pub extern "user32" fn EnableMenuItem(HMENU, id: u32, flags: u32) callconv(.winapi) i32;
pub extern "user32" fn GetSystemMenu(HWND, revert: BOOL) callconv(.winapi) ?HMENU;
pub extern "user32" fn GetSysColor(index: i32) callconv(.winapi) u32;
pub extern "user32" fn AllowSetForegroundWindow(process_id: u32) callconv(.winapi) BOOL;
pub extern "user32" fn GetClassNameW(HWND, buf: [*]u16, max: i32) callconv(.winapi) i32;
pub extern "user32" fn SystemParametersInfoW(action: u32, param: u32, pv: ?*anyopaque, win_ini: u32) callconv(.winapi) BOOL;

// -- Window tree, placement and monitors ----------------------------------

pub extern "user32" fn SetParent(child: HWND, new_parent: ?HWND) callconv(.winapi) ?HWND;
pub extern "user32" fn GetParent(HWND) callconv(.winapi) ?HWND;
pub extern "user32" fn GetAncestor(HWND, flags: u32) callconv(.winapi) ?HWND;
pub extern "user32" fn IsZoomed(HWND) callconv(.winapi) BOOL;
pub extern "user32" fn IsIconic(HWND) callconv(.winapi) BOOL;
pub extern "user32" fn IsWindowVisible(HWND) callconv(.winapi) BOOL;
pub extern "user32" fn GetWindowPlacement(HWND, *WINDOWPLACEMENT) callconv(.winapi) BOOL;
pub extern "user32" fn SetWindowPlacement(HWND, *const WINDOWPLACEMENT) callconv(.winapi) BOOL;
pub extern "user32" fn MonitorFromWindow(HWND, flags: u32) callconv(.winapi) ?HMONITOR;
pub extern "user32" fn MonitorFromPoint(POINT, flags: u32) callconv(.winapi) ?HMONITOR;
pub extern "user32" fn GetMonitorInfoW(HMONITOR, *MONITORINFO) callconv(.winapi) BOOL;
pub extern "user32" fn BeginDeferWindowPos(count: i32) callconv(.winapi) ?HDWP;
/// Returns the (possibly moved) handle, null on failure.
pub extern "user32" fn DeferWindowPos(HDWP, HWND, insert_after: ?HWND, x: i32, y: i32, cx: i32, cy: i32, flags: u32) callconv(.winapi) ?HDWP;
pub extern "user32" fn EndDeferWindowPos(HDWP) callconv(.winapi) BOOL;
pub extern "user32" fn MapWindowPoints(from: ?HWND, to: ?HWND, points: [*]POINT, count: u32) callconv(.winapi) i32;
pub extern "user32" fn GetDC(?HWND) callconv(.winapi) ?HDC;
pub extern "user32" fn ReleaseDC(?HWND, HDC) callconv(.winapi) i32;
pub extern "user32" fn GetWindowTextW(HWND, buf: [*]u16, max: i32) callconv(.winapi) i32;
pub extern "user32" fn GetWindowTextLengthW(HWND) callconv(.winapi) i32;
pub extern "user32" fn RedrawWindow(?HWND, ?*const RECT, ?HRGN, flags: u32) callconv(.winapi) BOOL;
pub extern "user32" fn ShowWindowAsync(HWND, cmd: i32) callconv(.winapi) BOOL;
pub extern "user32" fn FlashWindowEx(*const FLASHWINFO) callconv(.winapi) BOOL;
pub extern "user32" fn RegisterWindowMessageW([*:0]const u16) callconv(.winapi) u32;
pub extern "user32" fn GetSystemMetrics(index: i32) callconv(.winapi) i32;
pub extern "user32" fn SystemParametersInfoForDpi(action: u32, param: u32, pv: ?*anyopaque, win_ini: u32, dpi: u32) callconv(.winapi) BOOL;
pub extern "user32" fn ChildWindowFromPointEx(HWND, POINT, flags: u32) callconv(.winapi) ?HWND;
pub extern "user32" fn ChangeWindowMessageFilterEx(HWND, msg: u32, action: u32, ?*CHANGEFILTERSTRUCT) callconv(.winapi) BOOL;
pub extern "user32" fn EnumWindows(WNDENUMPROC, LPARAM) callconv(.winapi) BOOL;
pub extern "user32" fn EnumThreadWindows(thread_id: u32, WNDENUMPROC, LPARAM) callconv(.winapi) BOOL;
pub extern "user32" fn SetWindowDisplayAffinity(HWND, affinity: u32) callconv(.winapi) BOOL;
pub extern "user32" fn GetWindowDisplayAffinity(HWND, affinity: *u32) callconv(.winapi) BOOL;
pub extern "user32" fn RegisterClipboardFormatW([*:0]const u16) callconv(.winapi) u32;

/// `SetWindowDisplayAffinity` values (Windows 10 2004 and later for the last).
pub const WDA_NONE = 0x0;
pub const WDA_MONITOR = 0x1;
pub const WDA_EXCLUDEFROMCAPTURE = 0x11;
pub extern "user32" fn GetWindowThreadProcessId(HWND, process_id: ?*u32) callconv(.winapi) u32;
pub extern "user32" fn UpdateLayeredWindow(
    HWND,
    dst: ?HDC,
    pt_dst: ?*const POINT,
    size: ?*const SIZE,
    src: ?HDC,
    pt_src: ?*const POINT,
    key: u32,
    blend: ?*const BLENDFUNCTION,
    flags: u32,
) callconv(.winapi) BOOL;
pub extern "user32" fn GetCapture() callconv(.winapi) ?HWND;

// -- Scroll bars ------------------------------------------------------------

pub extern "user32" fn SetScrollInfo(HWND, bar: i32, *const SCROLLINFO, redraw: BOOL) callconv(.winapi) i32;
pub extern "user32" fn GetScrollInfo(HWND, bar: i32, *SCROLLINFO) callconv(.winapi) BOOL;
pub extern "user32" fn ShowScrollBar(HWND, bar: i32, show: BOOL) callconv(.winapi) BOOL;

// -- Menus and icons ----------------------------------------------------------

pub extern "user32" fn CreatePopupMenu() callconv(.winapi) ?HMENU;
/// `id` is the command id, or an `HMENU` for `MF_POPUP`.
pub extern "user32" fn AppendMenuW(HMENU, flags: u32, id: usize, item: ?[*:0]const u16) callconv(.winapi) BOOL;
/// With `TPM_RETURNCMD` the return value is the chosen command id (0 = none).
pub extern "user32" fn TrackPopupMenuEx(HMENU, flags: u32, x: i32, y: i32, HWND, ?*const TPMPARAMS) callconv(.winapi) BOOL;
pub extern "user32" fn DestroyMenu(HMENU) callconv(.winapi) BOOL;
pub extern "user32" fn LoadImageW(?HINSTANCE, name: ?*const anyopaque, kind: u32, cx: i32, cy: i32, flags: u32) callconv(.winapi) ?HANDLE;
pub extern "user32" fn DestroyIcon(HICON) callconv(.winapi) BOOL;
pub extern "user32" fn EnumClipboardFormats(format: u32) callconv(.winapi) u32;

// -- Keyboard --------------------------------------------------------------

pub extern "user32" fn GetKeyState(vk: i32) callconv(.winapi) i16;
pub extern "user32" fn GetKeyboardState(*[256]u8) callconv(.winapi) BOOL;
pub extern "user32" fn ToUnicodeEx(
    vk: u32,
    scan_code: u32,
    key_state: *const [256]u8,
    buf: [*]u16,
    buf_len: i32,
    flags: u32,
    layout: ?HKL,
) callconv(.winapi) i32;
pub extern "user32" fn VkKeyScanExW(ch: u16, layout: ?HKL) callconv(.winapi) i16;
pub extern "user32" fn MapVirtualKeyExW(code: u32, map_type: u32, layout: ?HKL) callconv(.winapi) u32;
pub extern "user32" fn GetKeyboardLayout(thread_id: u32) callconv(.winapi) ?HKL;
pub extern "user32" fn GetKeyboardLayoutList(count: i32, list: ?[*]HKL) callconv(.winapi) i32;
pub extern "user32" fn LoadKeyboardLayoutW(klid: [*:0]const u16, flags: u32) callconv(.winapi) ?HKL;
pub extern "user32" fn UnloadKeyboardLayout(HKL) callconv(.winapi) BOOL;
pub extern "user32" fn ActivateKeyboardLayout(HKL, flags: u32) callconv(.winapi) ?HKL;
pub extern "user32" fn SendInput(count: u32, inputs: [*]const INPUT, size: i32) callconv(.winapi) u32;

// -- Timers and clipboard --------------------------------------------------

pub extern "user32" fn SetTimer(?HWND, id: usize, elapse_ms: u32, ?TIMERPROC) callconv(.winapi) usize;
pub extern "user32" fn KillTimer(?HWND, id: usize) callconv(.winapi) BOOL;
pub extern "user32" fn OpenClipboard(?HWND) callconv(.winapi) BOOL;
pub extern "user32" fn CloseClipboard() callconv(.winapi) BOOL;
pub extern "user32" fn EmptyClipboard() callconv(.winapi) BOOL;
pub extern "user32" fn GetClipboardData(format: u32) callconv(.winapi) ?HANDLE;
pub extern "user32" fn SetClipboardData(format: u32, mem: ?HANDLE) callconv(.winapi) ?HANDLE;
pub extern "user32" fn IsClipboardFormatAvailable(format: u32) callconv(.winapi) BOOL;

// -- Message parameter helpers (windowsx.h) ----------------------------------

pub inline fn loWord(v: usize) u16 {
    return @truncate(v);
}

pub inline fn hiWord(v: usize) u16 {
    return @truncate(v >> 16);
}

/// GET_X_LPARAM: signed, so negative multi-monitor coordinates survive.
pub inline fn getXLparam(lp: LPARAM) i32 {
    return @as(i16, @bitCast(loWord(@bitCast(lp))));
}

pub inline fn getYLparam(lp: LPARAM) i32 {
    return @as(i16, @bitCast(hiWord(@bitCast(lp))));
}

pub inline fn getWheelDelta(wp: WPARAM) i16 {
    return @bitCast(hiWord(wp));
}

/// GET_XBUTTON_WPARAM: `XBUTTON1` or `XBUTTON2`.
pub inline fn getXButton(wp: WPARAM) u16 {
    return hiWord(wp);
}

pub inline fn makeLparam(lo: u16, hi: u16) LPARAM {
    return @bitCast(@as(usize, lo) | (@as(usize, hi) << 16));
}

// -- Window messages ---------------------------------------------------------

pub const WM_NULL = 0x0000;
pub const WM_CREATE = 0x0001;
pub const WM_DESTROY = 0x0002;
pub const WM_MOVE = 0x0003;
pub const WM_SIZE = 0x0005;
pub const WM_ACTIVATE = 0x0006;
pub const WM_SETFOCUS = 0x0007;
pub const WM_KILLFOCUS = 0x0008;
pub const WM_ENABLE = 0x000A;
pub const WM_PAINT = 0x000F;
pub const WM_CLOSE = 0x0010;
pub const WM_QUERYENDSESSION = 0x0011;
pub const WM_QUIT = 0x0012;
pub const WM_ERASEBKGND = 0x0014;
pub const WM_SYSCOLORCHANGE = 0x0015;
pub const WM_ENDSESSION = 0x0016;
pub const WM_SHOWWINDOW = 0x0018;
pub const WM_SETTINGCHANGE = 0x001A;
pub const WM_ACTIVATEAPP = 0x001C;
pub const WM_CANCELMODE = 0x001F;
pub const WM_SETCURSOR = 0x0020;
pub const WM_MOUSEACTIVATE = 0x0021;
pub const WM_GETMINMAXINFO = 0x0024;
pub const WM_WINDOWPOSCHANGING = 0x0046;
pub const WM_WINDOWPOSCHANGED = 0x0047;
pub const WM_INPUTLANGCHANGEREQUEST = 0x0050;
pub const WM_INPUTLANGCHANGE = 0x0051;
pub const WM_CONTEXTMENU = 0x007B;
pub const WM_DISPLAYCHANGE = 0x007E;
pub const WM_SETICON = 0x0080;
pub const WM_NCCREATE = 0x0081;
pub const WM_NCDESTROY = 0x0082;
pub const WM_NCCALCSIZE = 0x0083;
pub const WM_NCHITTEST = 0x0084;
pub const WM_NCPAINT = 0x0085;
pub const WM_NCACTIVATE = 0x0086;
pub const WM_GETDLGCODE = 0x0087;
pub const WM_NCMOUSEMOVE = 0x00A0;
pub const WM_NCLBUTTONDOWN = 0x00A1;
pub const WM_NCLBUTTONUP = 0x00A2;
pub const WM_NCLBUTTONDBLCLK = 0x00A3;
pub const WM_KEYDOWN = 0x0100;
pub const WM_KEYUP = 0x0101;
pub const WM_CHAR = 0x0102;
pub const WM_DEADCHAR = 0x0103;
pub const WM_SYSKEYDOWN = 0x0104;
pub const WM_SYSKEYUP = 0x0105;
pub const WM_SYSCHAR = 0x0106;
pub const WM_SYSDEADCHAR = 0x0107;
pub const WM_UNICHAR = 0x0109;
pub const WM_IME_STARTCOMPOSITION = 0x010D;
pub const WM_IME_ENDCOMPOSITION = 0x010E;
pub const WM_IME_COMPOSITION = 0x010F;
pub const WM_COMMAND = 0x0111;
pub const WM_SYSCOMMAND = 0x0112;
pub const WM_TIMER = 0x0113;
pub const WM_MENUCHAR = 0x0120;
pub const WM_MOUSEMOVE = 0x0200;
pub const WM_LBUTTONDOWN = 0x0201;
pub const WM_LBUTTONUP = 0x0202;
pub const WM_LBUTTONDBLCLK = 0x0203;
pub const WM_RBUTTONDOWN = 0x0204;
pub const WM_RBUTTONUP = 0x0205;
pub const WM_RBUTTONDBLCLK = 0x0206;
pub const WM_MBUTTONDOWN = 0x0207;
pub const WM_MBUTTONUP = 0x0208;
pub const WM_MBUTTONDBLCLK = 0x0209;
pub const WM_MOUSEWHEEL = 0x020A;
pub const WM_XBUTTONDOWN = 0x020B;
pub const WM_XBUTTONUP = 0x020C;
pub const WM_XBUTTONDBLCLK = 0x020D;
pub const WM_MOUSEHWHEEL = 0x020E;
pub const WM_SIZING = 0x0214;
pub const WM_CAPTURECHANGED = 0x0215;
pub const WM_MOVING = 0x0216;
pub const WM_ENTERSIZEMOVE = 0x0231;
pub const WM_EXITSIZEMOVE = 0x0232;
pub const WM_DROPFILES = 0x0233;
pub const WM_IME_SETCONTEXT = 0x0281;
pub const WM_IME_NOTIFY = 0x0282;
pub const WM_IME_CONTROL = 0x0283;
pub const WM_IME_COMPOSITIONFULL = 0x0284;
pub const WM_IME_SELECT = 0x0285;
pub const WM_IME_CHAR = 0x0286;
pub const WM_IME_REQUEST = 0x0288;
pub const WM_IME_KEYDOWN = 0x0290;
pub const WM_IME_KEYUP = 0x0291;
pub const WM_NCMOUSELEAVE = 0x02A2;
pub const WM_MOUSELEAVE = 0x02A3;
pub const WM_DPICHANGED = 0x02E0;
pub const WM_THEMECHANGED = 0x031A;
pub const WM_CLIPBOARDUPDATE = 0x031D;
pub const WM_DWMCOMPOSITIONCHANGED = 0x031E;
pub const WM_USER = 0x0400;
pub const WM_APP = 0x8000;

/// WM_UNICHAR wParam that asks whether the window handles WM_UNICHAR.
pub const UNICODE_NOCHAR = 0xFFFF;

// WM_SIZE wParam
pub const SIZE_RESTORED = 0;
pub const SIZE_MINIMIZED = 1;
pub const SIZE_MAXIMIZED = 2;
pub const SIZE_MAXSHOW = 3;
pub const SIZE_MAXHIDE = 4;

// WM_ACTIVATE wParam
pub const WA_INACTIVE = 0;
pub const WA_ACTIVE = 1;
pub const WA_CLICKACTIVE = 2;

// WM_NCHITTEST results
pub const HTERROR = -2;
pub const HTTRANSPARENT = -1;
pub const HTNOWHERE = 0;
pub const HTCLIENT = 1;
pub const HTCAPTION = 2;

// Mouse message wParam key state flags
pub const MK_LBUTTON = 0x0001;
pub const MK_RBUTTON = 0x0002;
pub const MK_SHIFT = 0x0004;
pub const MK_CONTROL = 0x0008;
pub const MK_MBUTTON = 0x0010;
pub const MK_XBUTTON1 = 0x0020;
pub const MK_XBUTTON2 = 0x0040;

pub const XBUTTON1 = 0x0001;
pub const XBUTTON2 = 0x0002;
pub const WHEEL_DELTA = 120;

// WM_KEYDOWN/WM_CHAR lParam high word flags
pub const KF_EXTENDED = 0x0100;
pub const KF_DLGMODE = 0x0800;
pub const KF_MENUMODE = 0x1000;
pub const KF_ALTDOWN = 0x2000;
pub const KF_REPEAT = 0x4000;
pub const KF_UP = 0x8000;

// -- Virtual keys ------------------------------------------------------------
// Digits and letters share their ASCII codes ('0'..'9', 'A'..'Z') and are
// intentionally not repeated here.

pub const VK_LBUTTON = 0x01;
pub const VK_RBUTTON = 0x02;
pub const VK_CANCEL = 0x03;
pub const VK_MBUTTON = 0x04;
pub const VK_XBUTTON1 = 0x05;
pub const VK_XBUTTON2 = 0x06;
pub const VK_BACK = 0x08;
pub const VK_TAB = 0x09;
pub const VK_CLEAR = 0x0C;
pub const VK_RETURN = 0x0D;
pub const VK_SHIFT = 0x10;
pub const VK_CONTROL = 0x11;
pub const VK_MENU = 0x12;
pub const VK_PAUSE = 0x13;
pub const VK_CAPITAL = 0x14;
pub const VK_KANA = 0x15;
pub const VK_HANGUL = 0x15;
pub const VK_IME_ON = 0x16;
pub const VK_JUNJA = 0x17;
pub const VK_FINAL = 0x18;
pub const VK_HANJA = 0x19;
pub const VK_KANJI = 0x19;
pub const VK_IME_OFF = 0x1A;
pub const VK_ESCAPE = 0x1B;
pub const VK_CONVERT = 0x1C;
pub const VK_NONCONVERT = 0x1D;
pub const VK_ACCEPT = 0x1E;
pub const VK_MODECHANGE = 0x1F;
pub const VK_SPACE = 0x20;
pub const VK_PRIOR = 0x21;
pub const VK_NEXT = 0x22;
pub const VK_END = 0x23;
pub const VK_HOME = 0x24;
pub const VK_LEFT = 0x25;
pub const VK_UP = 0x26;
pub const VK_RIGHT = 0x27;
pub const VK_DOWN = 0x28;
pub const VK_SELECT = 0x29;
pub const VK_PRINT = 0x2A;
pub const VK_EXECUTE = 0x2B;
pub const VK_SNAPSHOT = 0x2C;
pub const VK_INSERT = 0x2D;
pub const VK_DELETE = 0x2E;
pub const VK_HELP = 0x2F;
pub const VK_LWIN = 0x5B;
pub const VK_RWIN = 0x5C;
pub const VK_APPS = 0x5D;
pub const VK_SLEEP = 0x5F;
pub const VK_NUMPAD0 = 0x60;
pub const VK_NUMPAD1 = 0x61;
pub const VK_NUMPAD2 = 0x62;
pub const VK_NUMPAD3 = 0x63;
pub const VK_NUMPAD4 = 0x64;
pub const VK_NUMPAD5 = 0x65;
pub const VK_NUMPAD6 = 0x66;
pub const VK_NUMPAD7 = 0x67;
pub const VK_NUMPAD8 = 0x68;
pub const VK_NUMPAD9 = 0x69;
pub const VK_MULTIPLY = 0x6A;
pub const VK_ADD = 0x6B;
pub const VK_SEPARATOR = 0x6C;
pub const VK_SUBTRACT = 0x6D;
pub const VK_DECIMAL = 0x6E;
pub const VK_DIVIDE = 0x6F;
pub const VK_F1 = 0x70;
pub const VK_F2 = 0x71;
pub const VK_F3 = 0x72;
pub const VK_F4 = 0x73;
pub const VK_F5 = 0x74;
pub const VK_F6 = 0x75;
pub const VK_F7 = 0x76;
pub const VK_F8 = 0x77;
pub const VK_F9 = 0x78;
pub const VK_F10 = 0x79;
pub const VK_F11 = 0x7A;
pub const VK_F12 = 0x7B;
pub const VK_F13 = 0x7C;
pub const VK_F14 = 0x7D;
pub const VK_F15 = 0x7E;
pub const VK_F16 = 0x7F;
pub const VK_F17 = 0x80;
pub const VK_F18 = 0x81;
pub const VK_F19 = 0x82;
pub const VK_F20 = 0x83;
pub const VK_F21 = 0x84;
pub const VK_F22 = 0x85;
pub const VK_F23 = 0x86;
pub const VK_F24 = 0x87;
pub const VK_NUMLOCK = 0x90;
pub const VK_SCROLL = 0x91;
pub const VK_LSHIFT = 0xA0;
pub const VK_RSHIFT = 0xA1;
pub const VK_LCONTROL = 0xA2;
pub const VK_RCONTROL = 0xA3;
pub const VK_LMENU = 0xA4;
pub const VK_RMENU = 0xA5;
pub const VK_BROWSER_BACK = 0xA6;
pub const VK_BROWSER_FORWARD = 0xA7;
pub const VK_BROWSER_REFRESH = 0xA8;
pub const VK_BROWSER_STOP = 0xA9;
pub const VK_BROWSER_SEARCH = 0xAA;
pub const VK_BROWSER_FAVORITES = 0xAB;
pub const VK_BROWSER_HOME = 0xAC;
pub const VK_VOLUME_MUTE = 0xAD;
pub const VK_VOLUME_DOWN = 0xAE;
pub const VK_VOLUME_UP = 0xAF;
pub const VK_MEDIA_NEXT_TRACK = 0xB0;
pub const VK_MEDIA_PREV_TRACK = 0xB1;
pub const VK_MEDIA_STOP = 0xB2;
pub const VK_MEDIA_PLAY_PAUSE = 0xB3;
pub const VK_OEM_1 = 0xBA;
pub const VK_OEM_PLUS = 0xBB;
pub const VK_OEM_COMMA = 0xBC;
pub const VK_OEM_MINUS = 0xBD;
pub const VK_OEM_PERIOD = 0xBE;
pub const VK_OEM_2 = 0xBF;
pub const VK_OEM_3 = 0xC0;
pub const VK_OEM_4 = 0xDB;
pub const VK_OEM_5 = 0xDC;
pub const VK_OEM_6 = 0xDD;
pub const VK_OEM_7 = 0xDE;
pub const VK_OEM_8 = 0xDF;
pub const VK_OEM_102 = 0xE2;
pub const VK_PROCESSKEY = 0xE5;
pub const VK_PACKET = 0xE7;

// -- Keyboard layouts and SendInput -------------------------------------------

pub const KLF_ACTIVATE = 0x00000001;
pub const KLF_SUBSTITUTE_OK = 0x00000002;
pub const KLF_REORDER = 0x00000008;
pub const KLF_REPLACELANG = 0x00000010;
pub const KLF_NOTELLSHELL = 0x00000080;
pub const KLF_SETFORPROCESS = 0x00000100;

pub const KEYEVENTF_EXTENDEDKEY = 0x0001;
pub const KEYEVENTF_KEYUP = 0x0002;
pub const KEYEVENTF_UNICODE = 0x0004;
pub const KEYEVENTF_SCANCODE = 0x0008;

pub const INPUT_MOUSE = 0;
pub const INPUT_KEYBOARD = 1;
pub const INPUT_HARDWARE = 2;

pub const MAPVK_VK_TO_VSC = 0;
pub const MAPVK_VSC_TO_VK = 1;
pub const MAPVK_VK_TO_CHAR = 2;
pub const MAPVK_VSC_TO_VK_EX = 3;
pub const MAPVK_VK_TO_VSC_EX = 4;

// -- Window styles, show/position flags ----------------------------------------

pub const CS_VREDRAW = 0x0001;
pub const CS_HREDRAW = 0x0002;
pub const CS_DBLCLKS = 0x0008;
pub const CS_OWNDC = 0x0020;

pub const WS_OVERLAPPED = 0x00000000;
pub const WS_POPUP = 0x80000000;
pub const WS_CHILD = 0x40000000;
pub const WS_MINIMIZE = 0x20000000;
pub const WS_VISIBLE = 0x10000000;
pub const WS_DISABLED = 0x08000000;
pub const WS_CLIPSIBLINGS = 0x04000000;
pub const WS_CLIPCHILDREN = 0x02000000;
pub const WS_MAXIMIZE = 0x01000000;
pub const WS_CAPTION = 0x00C00000;
pub const WS_BORDER = 0x00800000;
pub const WS_DLGFRAME = 0x00400000;
pub const WS_VSCROLL = 0x00200000;
pub const WS_HSCROLL = 0x00100000;
pub const WS_SYSMENU = 0x00080000;
pub const WS_THICKFRAME = 0x00040000;
pub const WS_MINIMIZEBOX = 0x00020000;
pub const WS_MAXIMIZEBOX = 0x00010000;
pub const WS_OVERLAPPEDWINDOW = WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_THICKFRAME | WS_MINIMIZEBOX | WS_MAXIMIZEBOX;

pub const WS_EX_DLGMODALFRAME = 0x00000001;
pub const WS_EX_TOPMOST = 0x00000008;
pub const WS_EX_TRANSPARENT = 0x00000020;
pub const WS_EX_TOOLWINDOW = 0x00000080;
pub const WS_EX_WINDOWEDGE = 0x00000100;
pub const WS_EX_CLIENTEDGE = 0x00000200;
pub const WS_EX_APPWINDOW = 0x00040000;
pub const WS_EX_LAYERED = 0x00080000;
pub const WS_EX_NOREDIRECTIONBITMAP = 0x00200000;
pub const WS_EX_NOACTIVATE = 0x08000000;

/// CW_USEDEFAULT as the `i32` that `CreateWindowExW` takes.
pub const CW_USEDEFAULT: i32 = @bitCast(@as(u32, 0x80000000));

pub const SW_HIDE = 0;
pub const SW_SHOWNORMAL = 1;
pub const SW_SHOWMINIMIZED = 2;
pub const SW_SHOWMAXIMIZED = 3;
pub const SW_MAXIMIZE = 3;
pub const SW_SHOWNOACTIVATE = 4;
pub const SW_SHOW = 5;
pub const SW_MINIMIZE = 6;
pub const SW_SHOWMINNOACTIVE = 7;
pub const SW_SHOWNA = 8;
pub const SW_RESTORE = 9;
pub const SW_SHOWDEFAULT = 10;

pub const SWP_NOSIZE = 0x0001;
pub const SWP_NOMOVE = 0x0002;
pub const SWP_NOZORDER = 0x0004;
pub const SWP_NOREDRAW = 0x0008;
pub const SWP_NOACTIVATE = 0x0010;
pub const SWP_FRAMECHANGED = 0x0020;
pub const SWP_SHOWWINDOW = 0x0040;
pub const SWP_HIDEWINDOW = 0x0080;
pub const SWP_NOOWNERZORDER = 0x0200;
pub const SWP_NOSENDCHANGING = 0x0400;

/// `SetWindowPos` insert-after sentinels. `HWND_TOP` is `null`.
pub const HWND_TOP: ?HWND = null;
pub const HWND_BOTTOM: HWND = @ptrFromInt(1);
pub const HWND_TOPMOST: HWND = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));
pub const HWND_NOTOPMOST: HWND = @ptrFromInt(@as(usize, @bitCast(@as(isize, -2))));
/// Parent for message-only windows.
pub const HWND_MESSAGE: HWND = @ptrFromInt(@as(usize, @bitCast(@as(isize, -3))));

pub const GWL_STYLE = -16;
pub const GWL_EXSTYLE = -20;
pub const GWLP_WNDPROC = -4;
pub const GWLP_HINSTANCE = -6;
pub const GWLP_ID = -12;
pub const GWLP_USERDATA = -21;

// -- Resource ids, clipboard formats, message box, misc ------------------------

/// MAKEINTRESOURCE values for `LoadCursorW` / `LoadIconW`.
fn intResource(comptime id: usize) *const anyopaque {
    return @ptrFromInt(id);
}

pub const IDC_ARROW = intResource(32512);
pub const IDC_IBEAM = intResource(32513);
pub const IDC_WAIT = intResource(32514);
pub const IDC_CROSS = intResource(32515);
pub const IDC_UPARROW = intResource(32516);
pub const IDC_SIZENWSE = intResource(32642);
pub const IDC_SIZENESW = intResource(32643);
pub const IDC_SIZEWE = intResource(32644);
pub const IDC_SIZENS = intResource(32645);
pub const IDC_SIZEALL = intResource(32646);
pub const IDC_NO = intResource(32648);
pub const IDC_HAND = intResource(32649);
pub const IDC_APPSTARTING = intResource(32650);
pub const IDC_HELP = intResource(32651);

pub const IDI_APPLICATION = intResource(32512);

pub const CF_TEXT = 1;
pub const CF_UNICODETEXT = 13;

pub const MB_OK = 0x00000000;
pub const MB_OKCANCEL = 0x00000001;
pub const MB_ABORTRETRYIGNORE = 0x00000002;
pub const MB_YESNOCANCEL = 0x00000003;
pub const MB_YESNO = 0x00000004;
pub const MB_ICONERROR = 0x00000010;
pub const MB_ICONHAND = 0x00000010;
pub const MB_ICONQUESTION = 0x00000020;
pub const MB_ICONWARNING = 0x00000030;
pub const MB_ICONEXCLAMATION = 0x00000030;
pub const MB_ICONINFORMATION = 0x00000040;
pub const MB_ICONASTERISK = 0x00000040;
pub const MB_SETFOREGROUND = 0x00010000;
pub const MB_TOPMOST = 0x00040000;

pub const PM_NOREMOVE = 0x0000;
pub const PM_REMOVE = 0x0001;
pub const PM_NOYIELD = 0x0002;

pub const TME_HOVER = 0x00000001;
pub const TME_LEAVE = 0x00000002;
pub const TME_NONCLIENT = 0x00000010;
pub const TME_CANCEL = 0x80000000;

// GetSystemMetricsForDpi indices
pub const SM_CYCAPTION = 4;
pub const SM_CXSIZEFRAME = 32;
pub const SM_CYSIZEFRAME = 33;
pub const SM_CXPADDEDBORDER = 92;
/// Nonzero in a Remote Desktop session.
pub const SM_REMOTESESSION = 0x1000;

pub const SM_CXFRAME = 32;
pub const SM_CYFRAME = 33;
pub const SM_CXSMICON = 49;

// -- Non-client, scroll, window-state and menu constants ----------------------

pub const WM_VSCROLL = 0x0115;
pub const WM_NCRBUTTONUP = 0x00A5;

// WM_NCHITTEST results (continued)
pub const HTSYSMENU = 3;
pub const HTGROWBOX = 4;
pub const HTSIZE = HTGROWBOX;
pub const HTMENU = 5;
pub const HTHSCROLL = 6;
pub const HTVSCROLL = 7;
pub const HTMINBUTTON = 8;
pub const HTMAXBUTTON = 9;
pub const HTLEFT = 10;
pub const HTRIGHT = 11;
pub const HTTOP = 12;
pub const HTTOPLEFT = 13;
pub const HTTOPRIGHT = 14;
pub const HTBOTTOM = 15;
pub const HTBOTTOMLEFT = 16;
pub const HTBOTTOMRIGHT = 17;
pub const HTBORDER = 18;
pub const HTREDUCE = HTMINBUTTON;
pub const HTZOOM = HTMAXBUTTON;
pub const HTSIZEFIRST = HTLEFT;
pub const HTSIZELAST = HTBOTTOMRIGHT;
pub const HTOBJECT = 19;
pub const HTCLOSE = 20;
pub const HTHELP = 21;

// WM_SYSCOMMAND wParam (the low 4 bits are used by the system)
pub const SC_MINIMIZE = 0xF020;
pub const SC_MAXIMIZE = 0xF030;
pub const SC_CLOSE = 0xF060;
pub const SC_RESTORE = 0xF120;

// Scroll bar selectors, WM_VSCROLL codes, SCROLLINFO masks, EnableScrollBar flags
pub const SB_HORZ = 0;
pub const SB_VERT = 1;
pub const SB_CTL = 2;
pub const SB_BOTH = 3;

pub const SB_LINEUP = 0;
pub const SB_LINELEFT = 0;
pub const SB_LINEDOWN = 1;
pub const SB_LINERIGHT = 1;
pub const SB_PAGEUP = 2;
pub const SB_PAGELEFT = 2;
pub const SB_PAGEDOWN = 3;
pub const SB_PAGERIGHT = 3;
pub const SB_THUMBPOSITION = 4;
pub const SB_THUMBTRACK = 5;
pub const SB_TOP = 6;
pub const SB_LEFT = 6;
pub const SB_BOTTOM = 7;
pub const SB_RIGHT = 7;
pub const SB_ENDSCROLL = 8;

pub const SIF_RANGE = 0x0001;
pub const SIF_PAGE = 0x0002;
pub const SIF_POS = 0x0004;
pub const SIF_DISABLENOSCROLL = 0x0008;
pub const SIF_TRACKPOS = 0x0010;
pub const SIF_ALL = SIF_RANGE | SIF_PAGE | SIF_POS | SIF_TRACKPOS;

pub const ESB_ENABLE_BOTH = 0x0000;
pub const ESB_DISABLE_LTUP = 0x0001;
pub const ESB_DISABLE_RTDN = 0x0002;
pub const ESB_DISABLE_BOTH = 0x0003;

pub const FLASHW_STOP = 0;
pub const FLASHW_CAPTION = 0x00000001;
pub const FLASHW_TRAY = 0x00000002;
pub const FLASHW_ALL = FLASHW_CAPTION | FLASHW_TRAY;
pub const FLASHW_TIMER = 0x00000004;
pub const FLASHW_TIMERNOFG = 0x0000000C;

pub const MONITOR_DEFAULTTONULL = 0;
pub const MONITOR_DEFAULTTOPRIMARY = 1;
pub const MONITOR_DEFAULTTONEAREST = 2;

pub const RDW_INVALIDATE = 0x0001;
pub const RDW_ERASE = 0x0004;
pub const RDW_ALLCHILDREN = 0x0080;
pub const RDW_UPDATENOW = 0x0100;
pub const RDW_ERASENOW = 0x0200;
pub const RDW_FRAME = 0x0400;

pub const ES_AUTOHSCROLL = 0x0080;

pub const GA_PARENT = 1;
pub const GA_ROOT = 2;
pub const GA_ROOTOWNER = 3;

pub const CWP_ALL = 0x0000;
pub const CWP_SKIPINVISIBLE = 0x0001;
pub const CWP_SKIPDISABLED = 0x0002;
pub const CWP_SKIPTRANSPARENT = 0x0004;

pub const MSGFLT_RESET = 0;
pub const MSGFLT_ALLOW = 1;
pub const MSGFLT_DISALLOW = 2;

pub const SPI_GETHIGHCONTRAST = 0x0042;
pub const SPI_GETWHEELSCROLLLINES = 0x0068;
pub const HCF_HIGHCONTRASTON = 0x00000001;

pub const MF_STRING = 0x00000000;
pub const MF_SEPARATOR = 0x00000800;
pub const TPM_RIGHTBUTTON = 0x0002;
pub const TPM_BOTTOMALIGN = 0x0020;
pub const TPM_RETURNCMD = 0x0100;

pub const IMAGE_ICON = 1;
pub const LR_DEFAULTCOLOR = 0x00000000;

pub extern "user32" fn SendMessageTimeoutW(HWND, u32, WPARAM, LPARAM, flags: u32, timeout: u32, result: ?*usize) callconv(.winapi) LRESULT;

/// PeekMessageW: handle only the messages sent from other threads (QS_SENDMESSAGE << 16).
pub const PM_QS_SENDMESSAGE = 0x00400000;

pub const ULW_ALPHA = 0x00000002;
pub const AC_SRC_OVER = 0x00;
pub const AC_SRC_ALPHA = 0x01;

// -- Global hotkeys, edit control (M3) -----------------------------------------
pub extern "user32" fn RegisterHotKey(?HWND, id: i32, modifiers: u32, vk: u32) callconv(.winapi) BOOL;
pub extern "user32" fn UnregisterHotKey(?HWND, id: i32) callconv(.winapi) BOOL;

pub const WM_HOTKEY = 0x0312;
pub const MOD_ALT = 0x0001;
pub const MOD_CONTROL = 0x0002;
pub const MOD_SHIFT = 0x0004;
pub const MOD_WIN = 0x0008;
pub const MOD_NOREPEAT = 0x4000;

/// `GetLastError` after `RegisterHotKey` when another process owns the combination.
pub const ERROR_HOTKEY_ALREADY_REGISTERED = 1409;

/// `SetWindowLongPtrW` index that changes the owner of a top-level window.
pub const GWLP_HWNDPARENT = -8;

pub const ES_LEFT = 0x0000;
pub const EM_SETSEL = 0x00B1;
pub const ECM_FIRST = 0x1500;
/// `wparam` TRUE keeps the banner visible while the edit has focus; `lparam` is a `[*:0]const u16`.
pub const EM_SETCUEBANNER = ECM_FIRST + 1;
pub const EN_KILLFOCUS = 0x0200;
pub const EN_CHANGE = 0x0300;
pub const WM_CTLCOLOREDIT = 0x0133;

/// `GetWindow` command: the window above in the Z order.
pub const GW_HWNDPREV = 3;
/// `GetWindow` command: the owner of an owned window.
pub const GW_OWNER = 4;
pub extern "user32" fn GetWindow(HWND, cmd: u32) callconv(.winapi) ?HWND;

/// Sent by PrintWindow (and WM_PRINT) to draw the client area into a DC.
pub const WM_PRINTCLIENT = 0x0318;
