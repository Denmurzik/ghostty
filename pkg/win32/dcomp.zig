//! dcomp.dll bindings (DirectComposition), filled by M3 Task 8.
//! `DCompositionCreateDevice2` is resolved lazily through `LoadLibraryExW(SYSTEM32)` +
//! `GetProcAddress`; dcomp is never imported or linked.
