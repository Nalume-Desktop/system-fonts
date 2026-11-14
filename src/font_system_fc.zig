//! Minimal native Fontconfig ABI (fontconfig/fontconfig.h). No global config mutation.
const std = @import("std");
pub const Config = opaque {};
pub const Pattern = opaque {};
pub const CharSet = opaque {};
pub const StrList = opaque {};
pub const Matrix = extern struct { xx: f64, xy: f64, yx: f64, yy: f64 };
pub const FontSet = extern struct { nfont: c_int, sfont: c_int, fonts: [*]*Pattern };
pub extern "fontconfig" fn FcConfigCreate() ?*Config;
pub extern "fontconfig" fn FcConfigDestroy(*Config) void;
pub extern "fontconfig" fn FcConfigParseAndLoad(*Config, ?[*:0]const u8, c_int) c_int;
pub extern "fontconfig" fn FcConfigParseAndLoadFromMemory(*Config, [*:0]const u8, c_int) c_int;
pub extern "fontconfig" fn FcConfigBuildFonts(*Config) c_int;
pub extern "fontconfig" fn FcConfigUptoDate(*Config) c_int;
pub extern "fontconfig" fn FcConfigGetFonts(*Config, c_int) ?*FontSet;
pub extern "fontconfig" fn FcConfigGetConfigFiles(*Config) ?*StrList;
pub extern "fontconfig" fn FcConfigGetConfigDirs(*Config) ?*StrList;
pub extern "fontconfig" fn FcConfigGetFontDirs(*Config) ?*StrList;
pub extern "fontconfig" fn FcStrListNext(*StrList) ?[*:0]u8;
pub extern "fontconfig" fn FcStrListDone(*StrList) void;
pub extern "fontconfig" fn FcPatternCreate() ?*Pattern;
pub extern "fontconfig" fn FcPatternDestroy(*Pattern) void;
pub extern "fontconfig" fn FcPatternAddString(*Pattern, [*:0]const u8, [*:0]const u8) c_int;
pub extern "fontconfig" fn FcPatternAddInteger(*Pattern, [*:0]const u8, c_int) c_int;
pub extern "fontconfig" fn FcPatternAddBool(*Pattern, [*:0]const u8, c_int) c_int;
pub extern "fontconfig" fn FcPatternGetString(*const Pattern, [*:0]const u8, c_int, *?[*:0]u8) c_int;
pub extern "fontconfig" fn FcPatternGetInteger(*const Pattern, [*:0]const u8, c_int, *c_int) c_int;
pub extern "fontconfig" fn FcPatternGetDouble(*const Pattern, [*:0]const u8, c_int, *f64) c_int;
pub extern "fontconfig" fn FcPatternGetBool(*const Pattern, [*:0]const u8, c_int, *c_int) c_int;
pub extern "fontconfig" fn FcPatternGetMatrix(*const Pattern, [*:0]const u8, c_int, *?*Matrix) c_int;
pub extern "fontconfig" fn FcPatternGetCharSet(*const Pattern, [*:0]const u8, c_int, *?*CharSet) c_int;
pub extern "fontconfig" fn FcConfigSubstitute(*Config, *Pattern, c_int) c_int;
pub extern "fontconfig" fn FcDefaultSubstitute(*Pattern) void;
pub extern "fontconfig" fn FcFontSort(*Config, *Pattern, c_int, *?*CharSet, *c_int) ?*FontSet;
pub extern "fontconfig" fn FcFontSetSortDestroy(*FontSet) void;
pub extern "fontconfig" fn FcFontRenderPrepare(*Config, *Pattern, *Pattern) ?*Pattern;
pub extern "fontconfig" fn FcFontSetAdd(*FontSet, *Pattern) c_int;
pub extern "fontconfig" fn FcCharSetCreate() ?*CharSet;
pub extern "fontconfig" fn FcCharSetAddChar(*CharSet, u32) c_int;
pub extern "fontconfig" fn FcPatternAddCharSet(*Pattern, [*:0]const u8, *const CharSet) c_int;
pub extern "fontconfig" fn FcCharSetDestroy(*CharSet) void;
pub extern "fontconfig" fn FcCharSetHasChar(*const CharSet, u32) c_int;
pub extern "fontconfig" fn FcStrCmpIgnoreCase([*:0]const u8, [*:0]const u8) c_int;

pub fn string(p: *const Pattern, key: [*:0]const u8) ?[]const u8 {
    var value: ?[*:0]u8 = null;
    if (FcPatternGetString(p, key, 0, &value) != 0) return null;
    return std.mem.span(value orelse return null);
}
pub fn integer(p: *const Pattern, key: [*:0]const u8, default: i32) i32 {
    var value: c_int = default;
    _ = FcPatternGetInteger(p, key, 0, &value);
    return value;
}
pub fn boolean(p: *const Pattern, key: [*:0]const u8, default: bool) bool {
    var value: c_int = @intFromBool(default);
    _ = FcPatternGetBool(p, key, 0, &value);
    return value != 0;
}
pub fn double(p: *const Pattern, key: [*:0]const u8, default: f64) f64 {
    var value = default;
    _ = FcPatternGetDouble(p, key, 0, &value);
    return value;
}
