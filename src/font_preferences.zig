//! Versioned application preferences, separate from Fontconfig configuration.
const std = @import("std");
const fonts = @import("font_system.zig");
const Allocator = std.mem.Allocator;
const StoredRole = struct { mode: enum { system, family }, family: ?[]const u8 = null };
const Document = struct { schema: u32, roles: struct { body: StoredRole, mono: StoredRole } };
var temporary_sequence: std.atomic.Value(u64) = .init(0);

/// Returns an owned path under the caller's single application directory.
pub fn configPath(a: Allocator, environment: *const std.process.Environ.Map, application: []const u8) !?[]u8 {
    if (application.len == 0 or std.mem.eql(u8, application, ".") or std.mem.eql(u8, application, "..") or
        std.mem.indexOfAny(u8, application, "/\\") != null or std.mem.indexOfScalar(u8, application, 0) != null or
        !std.unicode.utf8ValidateSlice(application)) return error.InvalidApplicationName;
    if (environment.get("XDG_CONFIG_HOME")) |base| {
        if (base.len > 0 and std.fs.path.isAbsolute(base))
            return try std.fs.path.join(a, &.{ base, application, "fonts.json" });
    }
    const home = environment.get("HOME") orelse return null;
    if (home.len == 0 or !std.fs.path.isAbsolute(home)) return null;
    return try std.fs.path.join(a, &.{ home, ".config", application, "fonts.json" });
}

pub fn parse(a: Allocator, bytes: []const u8) !fonts.Preferences {
    const parsed = try std.json.parseFromSlice(Document, a, bytes, .{});
    defer parsed.deinit();
    if (parsed.value.schema != 1) return error.UnsupportedFontPreferenceSchema;
    const preferences: fonts.Preferences = .{
        .body = try selection(parsed.value.roles.body),
        .mono = try selection(parsed.value.roles.mono),
    };
    return preferences.clone(a);
}

fn selection(role: StoredRole) !fonts.Selection {
    return switch (role.mode) {
        .system => if (role.family == null) .system else error.InvalidFontPreferences,
        .family => .{ .family = role.family orelse return error.InvalidFontPreferences },
    };
}

pub fn load(a: Allocator, io: std.Io, path: ?[]const u8) !fonts.Preferences {
    const file_path = path orelse return .{};
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, file_path, a, .limited(32 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    defer a.free(bytes);
    return parse(a, bytes);
}

fn stored(value: fonts.Selection) StoredRole {
    return switch (value) {
        .system => .{ .mode = .system },
        .family => |name| .{ .mode = .family, .family = name },
    };
}

pub fn encode(a: Allocator, preferences: fonts.Preferences) ![]u8 {
    try preferences.validate();
    const document: Document = .{ .schema = 1, .roles = .{ .body = stored(preferences.body), .mono = stored(preferences.mono) } };
    return std.json.Stringify.valueAlloc(a, document, .{ .whitespace = .indent_2, .emit_null_optional_fields = false });
}

pub fn save(a: Allocator, io: std.Io, path: ?[]const u8, preferences: fonts.Preferences) !void {
    const destination = path orelse return error.FontPreferencePathUnavailable;
    const bytes = try encode(a, preferences);
    defer a.free(bytes);
    const parent = std.fs.path.dirname(destination) orelse return error.InvalidFontPreferencePath;
    try std.Io.Dir.cwd().createDirPath(io, parent);
    // Exclusive sibling creation prevents clobbering another process's temp file.
    for (0..16) |_| {
        const sequence = temporary_sequence.fetchAdd(1, .monotonic);
        const temporary = try std.fmt.allocPrint(a, "{s}.tmp-{d}-{d}", .{ destination, std.os.linux.getpid(), sequence });
        defer a.free(temporary);
        var file = std.Io.Dir.cwd().createFile(io, temporary, .{ .exclusive = true }) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return err,
        };
        var open = true;
        defer if (open) file.close(io);
        defer std.Io.Dir.cwd().deleteFile(io, temporary) catch {};
        try file.writeStreamingAll(io, bytes);
        try file.sync(io);
        file.close(io);
        open = false;
        try std.Io.Dir.rename(.cwd(), temporary, .cwd(), destination, io);
        return;
    }
    return error.FontPreferenceTemporaryCollision;
}

test "font preferences detach strings and round-trip language-neutral choices" {
    const a = std.testing.allocator;
    const encoded = try encode(a, .{ .body = .{ .family = "Example Sans" }, .mono = .system });
    var preferences = try parse(a, encoded);
    a.free(encoded);
    defer preferences.deinit(a);
    try std.testing.expectEqualStrings("Example Sans", preferences.body.family);
    try std.testing.expect(preferences.mono == .system);
}

test "font preferences reject unsupported schema and contradictory family fields" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.UnsupportedFontPreferenceSchema, parse(a, "{\"schema\":2,\"roles\":{\"body\":{\"mode\":\"system\"},\"mono\":{\"mode\":\"system\"}}}"));
    try std.testing.expectError(error.InvalidFontPreferences, parse(a, "{\"schema\":1,\"roles\":{\"body\":{\"mode\":\"system\",\"family\":\"Ignored\"},\"mono\":{\"mode\":\"system\"}}}"));
    try std.testing.expectError(error.InvalidFontPreferences, parse(a, "{\"schema\":1,\"roles\":{\"body\":{\"mode\":\"family\"},\"mono\":{\"mode\":\"system\"}}}"));
}

test "font preference paths isolate applications and respect XDG fallback" {
    const a = std.testing.allocator;
    var environment = std.process.Environ.Map.init(a);
    defer environment.deinit();
    try environment.put("HOME", "/home/example");
    try environment.put("XDG_CONFIG_HOME", "/config");
    const first = (try configPath(a, &environment, "first-app")).?;
    defer a.free(first);
    const second = (try configPath(a, &environment, "second-app")).?;
    defer a.free(second);
    try std.testing.expectEqualStrings("/config/first-app/fonts.json", first);
    try std.testing.expectEqualStrings("/config/second-app/fonts.json", second);
    try environment.put("XDG_CONFIG_HOME", "relative");
    const fallback = (try configPath(a, &environment, "first-app")).?;
    defer a.free(fallback);
    try std.testing.expectEqualStrings("/home/example/.config/first-app/fonts.json", fallback);
    try std.testing.expectError(error.InvalidApplicationName, configPath(a, &environment, "../escape"));
    try std.testing.expectError(error.InvalidApplicationName, configPath(a, &environment, ""));
    try environment.put("HOME", "relative");
    try std.testing.expectEqual(null, try configPath(a, &environment, "first-app"));
}
