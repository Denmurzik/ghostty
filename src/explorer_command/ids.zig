//! Identifiers of the Explorer command, fixed forever: the sparse package's
//! manifest names the same CLSID (`dist/windows/package.ps1` checks the two
//! against each other by reading `clsid_text` and `package_name` here).
const com = @import("com.zig");

pub const clsid_text = "{5DCE6858-478B-4439-9D93-6DAB0557A7BB}";
pub const clsid: com.GUID = com.GUID.parse(clsid_text);

pub const verb_name = "GhosttyOpenHere";
pub const verb_guid_text = "{DE987FDA-8C24-4B83-BCF0-051651C32CAB}";
pub const verb_guid: com.GUID = com.GUID.parse(verb_guid_text);

pub const package_name = "Ghostty.ExplorerMenu";
pub const dll_name = "ghostty-explorer.dll";
