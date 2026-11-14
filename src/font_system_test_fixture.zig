//! Private Fontconfig patterns: no host configuration or installed fonts.
const fc = @import("font_system_fc.zig");

pub fn config() !*fc.Config {
    const result = fc.FcConfigCreate() orelse return error.FixtureAllocation;
    errdefer fc.FcConfigDestroy(result);
    const xml = "<fontconfig>" ++
        "<alias><family>sans-serif</family><prefer><family>Fixture Sans</family></prefer></alias>" ++
        "<alias><family>monospace</family><prefer><family>Fixture Mono</family></prefer></alias>" ++
        "</fontconfig>";
    if (fc.FcConfigParseAndLoadFromMemory(result, xml, 1) == 0 or fc.FcConfigBuildFonts(result) == 0)
        return error.FixtureConfiguration;
    const set = fc.FcConfigGetFonts(result, 0) orelse return error.FixtureFontSet;
    for ([_][*:0]const u8{ "Fixture Sans", "Fixture Mono" }) |family| {
        for (0..4) |style| {
            const pattern = try face(family, style);
            if (fc.FcFontSetAdd(set, pattern) == 0) {
                fc.FcPatternDestroy(pattern);
                return error.FixtureAllocation;
            }
        }
    }
    return result;
}

fn face(family: [*:0]const u8, style: usize) !*fc.Pattern {
    const pattern = fc.FcPatternCreate() orelse return error.FixtureAllocation;
    errdefer fc.FcPatternDestroy(pattern);
    const charset = fc.FcCharSetCreate() orelse return error.FixtureAllocation;
    defer fc.FcCharSetDestroy(charset);
    for ([_]u32{ 0x41, 0x4e2d, 0x1f642 }) |cp| if (fc.FcCharSetAddChar(charset, cp) == 0)
        return error.FixtureAllocation;
    if (fc.FcPatternAddString(pattern, "family", family) == 0 or
        fc.FcPatternAddString(pattern, "style", ([4][*:0]const u8{ "Regular", "Bold", "Italic", "Bold Italic" })[style]) == 0 or
        fc.FcPatternAddString(pattern, "file", "/fixture-fonts/collection.ttc") == 0 or
        fc.FcPatternAddInteger(pattern, "index", @intCast(style + 2)) == 0 or
        fc.FcPatternAddInteger(pattern, "weight", if (style == 1 or style == 3) 200 else 80) == 0 or
        fc.FcPatternAddInteger(pattern, "slant", if (style >= 2) 100 else 0) == 0 or
        fc.FcPatternAddInteger(pattern, "spacing", 100) == 0 or
        fc.FcPatternAddBool(pattern, "scalable", 1) == 0 or
        fc.FcPatternAddBool(pattern, "outline", 1) == 0 or
        fc.FcPatternAddCharSet(pattern, "charset", charset) == 0) return error.FixtureAllocation;
    return pattern;
}
