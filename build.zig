const std = @import("std");
pub fn build(b: *std.Build) void {
    if (b.graph.environ_map.get("PKG_CONFIG")) |value| {
        if (value.len == 0) _ = b.graph.environ_map.swapRemove("PKG_CONFIG");
    }
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const module = b.addModule("system_fonts", .{ .root_source_file = b.path("src/root.zig"), .target = target, .optimize = optimize, .link_libc = true });
    module.linkSystemLibrary("fontconfig", .{ .preferred_link_mode = .dynamic, .search_strategy = .mode_first });
    const tests = b.addTest(.{ .use_llvm = true, .root_module = module });
    b.step("test", "Test font service and application preferences").dependOn(&b.addRunArtifact(tests).step);
}
