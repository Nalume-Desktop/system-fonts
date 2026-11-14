const std = @import("std");
const fonts = @import("font_system.zig");

test "preferences reject invalid requests before copying and own Unicode family names" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.InvalidFamily, (fonts.Preferences{ .body = .{ .family = "" } }).validate());
    try std.testing.expectError(error.InvalidFamily, (fonts.Preferences{ .body = .{ .family = "a\x00b" } }).validate());
    try std.testing.expectError(error.InvalidFamily, (fonts.Preferences{ .mono = .{ .family = "\xff" } }).validate());
    var source = [_]u8{ 0xe4, 0xb8, 0xad, ' ', 'F' };
    const copy = try (fonts.Preferences{ .body = .{ .family = &source } }).clone(a);
    defer copy.deinit(a);
    source[3] = '-';
    try std.testing.expectEqualStrings("中 F", copy.body.family);
    try std.testing.expect(copy.mono == .system);
}

test "all body and mono styles have distinct stable slots" {
    for (0..8) |i| {
        const slot: fonts.Slot = @fromBackingInt(@intCast(i));
        try std.testing.expectEqual(slot, fonts.Slot.init(slot.role(), slot.style()));
    }
}

test "Unicode cluster metadata does not turn a script into a language" {
    try std.testing.expect(fonts.isDefaultIgnorable(0x200d));
    try std.testing.expect(fonts.isDefaultIgnorable(0xfe0f));
    try std.testing.expect(fonts.isDefaultIgnorable(0xe0100));
    try std.testing.expect(!fonts.isDefaultIgnorable(0x4e2d));
    try std.testing.expect(!fonts.isDefaultIgnorable(0x1f642));
}
