const system = @import("font_system.zig");
pub const fc = @import("font_system_fc.zig");
pub const preferences = @import("font_preferences.zig");
pub const Role = system.Role;
pub const Style = system.Style;
pub const Slot = system.Slot;
pub const Selection = system.Selection;
pub const Preferences = system.Preferences;
pub const Options = system.Options;
pub const Blob = system.Blob;
pub const Rendering = system.Rendering;
pub const Candidate = system.Candidate;
pub const isDefaultIgnorable = system.isDefaultIgnorable;
pub const LoadedFace = system.LoadedFace;
pub const SlotFaces = system.SlotFaces;
pub const Snapshot = system.Snapshot;
pub const prepare = system.prepare;
pub const validateRenderable = system.validateRenderable;
pub const RequestKind = system.RequestKind;
pub const Failure = system.Failure;
pub const Status = system.Status;
pub const PreparedFallback = system.PreparedFallback;
pub const FallbackFailure = system.FallbackFailure;
pub const Completion = system.Completion;
pub const Service = system.Service;

test {
    _ = system;
    _ = preferences;
}
