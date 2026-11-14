//! Language-neutral, application-owned system fonts. No DVUI or GL objects.
//! Render code only reads snapshots and enqueues misses. All discovery/file I/O
//! happens during startup prepare() or on Service's worker. Retain each borrowed
//! blob until DVUI registrations, FreeType faces and draw data have retired.
const std = @import("std");
pub const fc = @import("font_system_fc.zig");
const Allocator = std.mem.Allocator;
const Atomic = std.atomic.Value;

pub const Role = enum { body, mono };
pub const Style = enum { normal, bold, italic, bold_italic };
pub const Slot = enum(u3) {
    body_normal,
    body_bold,
    body_italic,
    body_bold_italic,
    mono_normal,
    mono_bold,
    mono_italic,
    mono_bold_italic,
    pub fn init(font_role: Role, font_style: Style) Slot {
        return @fromBackingInt(@intCast(@as(u3, @backingInt(font_role)) * 4 + @backingInt(font_style)));
    }
    pub fn role(self: Slot) Role {
        return @fromBackingInt(@intCast(@backingInt(self) / 4));
    }
    pub fn style(self: Slot) Style {
        return @fromBackingInt(@intCast(@backingInt(self) % 4));
    }
};
pub const Selection = union(enum) { system, family: []const u8 };
pub const Preferences = struct {
    body: Selection = .system,
    mono: Selection = .system,
    pub fn validate(self: Preferences) !void {
        inline for (.{ self.body, self.mono }) |selection| switch (selection) {
            .system => {},
            .family => |name| {
                if (name.len == 0 or name.len > 1024 or std.mem.indexOfScalar(u8, name, 0) != null or
                    !std.unicode.utf8ValidateSlice(name)) return error.InvalidFamily;
            },
        };
    }
    pub fn clone(self: Preferences, a: Allocator) !Preferences {
        try self.validate();
        const body = try copySelection(a, self.body);
        errdefer freeSelection(a, body);
        return .{ .body = body, .mono = try copySelection(a, self.mono) };
    }
    pub fn deinit(self: Preferences, a: Allocator) void {
        freeSelection(a, self.body);
        freeSelection(a, self.mono);
    }
};
fn copySelection(a: Allocator, s: Selection) !Selection {
    return switch (s) {
        .system => .system,
        .family => |v| .{ .family = try a.dupe(u8, v) },
    };
}
fn freeSelection(a: Allocator, s: Selection) void {
    switch (s) {
        .system => {},
        .family => |v| a.free(v),
    }
}
pub const Options = struct {
    /// Null reads the user's normal Fontconfig configuration into a private
    /// config. Explicit files are useful for private fixtures; never set current.
    config_file: ?[]const u8 = null,
    max_blob_bytes: usize = 256 * 1024 * 1024,
    max_file_bytes: usize = 128 * 1024 * 1024,
    max_snapshots: usize = 3,
    max_candidates_per_slot: usize = 4096,
    max_catalog_families: usize = 8192,
    max_watch_paths: usize = 32768,
    max_fallback_requests: usize = 32,
    check_interval_seconds: i64 = 15,
};
const Budget = struct {
    allocator: Allocator,
    refs: Atomic(usize) = .init(1),
    bytes: Atomic(usize) = .init(0),
    snapshots: Atomic(usize) = .init(0),
    options: Options,
    fn retain(self: *Budget) void {
        _ = self.refs.fetchAdd(1, .monotonic);
    }
    fn release(self: *Budget) void {
        if (self.refs.fetchSub(1, .acq_rel) == 1) self.allocator.destroy(self);
    }
    fn reserve(counter: *Atomic(usize), amount: usize, maximum: usize) !void {
        var old = counter.load(.monotonic);
        while (true) {
            if (amount > maximum or old > maximum - amount) return error.ResidencyBudgetExceeded;
            old = counter.cmpxchgWeak(old, old + amount, .acq_rel, .monotonic) orelse return;
        }
    }
};
pub const Blob = struct {
    allocator: Allocator,
    refs: Atomic(usize) = .init(1),
    budget: *Budget,
    bytes: []const u8,
    identity: [32]u8,
    pub fn retain(self: *Blob) *Blob {
        _ = self.refs.fetchAdd(1, .monotonic);
        return self;
    }
    pub fn release(self: *Blob) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        _ = self.budget.bytes.fetchSub(self.bytes.len, .acq_rel);
        self.allocator.free(self.bytes);
        const budget = self.budget;
        self.allocator.destroy(self);
        budget.release();
    }
};
pub const Rendering = struct {
    antialias: bool,
    hinting: bool,
    autohint: bool,
    embedded_bitmap: bool,
    embolden: bool,
    rgba: i32,
    hint_style: i32,
    lcd_filter: i32,
    dpi: f64,
    scale: f64,
    matrix: fc.Matrix,
};
pub const Candidate = struct {
    /// Strings/charset are borrowed from retained prepared Fontconfig pattern.
    path: []const u8,
    family: []const u8,
    style_name: []const u8,
    index: i32,
    weight: i32,
    slant: i32,
    variations: []const u8,
    variable: bool,
    named_instance: bool,
    color: bool,
    rendering: Rendering,
    charset: ?*const fc.CharSet,
    pattern: *fc.Pattern,
    // Snapshot-local recovery state; metadata stays immutable after preparation.
    fallback_rejected: Atomic(bool) = .init(false),
    pub fn covers(self: *const Candidate, codepoint: u21) bool {
        if (codepoint > 0x10ffff or (codepoint >= 0xd800 and codepoint <= 0xdfff)) return false;
        return if (self.charset) |set| fc.FcCharSetHasChar(set, codepoint) != 0 else false;
    }
    /// Coverage is metadata, not shaping or a proof of FT glyph availability.
    /// The DVUI adapter verifies actual glyph indices and variation selectors.
    pub fn coversCluster(self: *const Candidate, codepoints: []const u21) bool {
        for (codepoints) |cp| if (!isDefaultIgnorable(cp) and !self.covers(cp)) return false;
        return true;
    }
};
pub fn isDefaultIgnorable(cp: u21) bool {
    return cp == 0x00ad or cp == 0x034f or cp == 0x061c or
        (cp >= 0x115f and cp <= 0x1160) or (cp >= 0x17b4 and cp <= 0x17b5) or
        (cp >= 0x180b and cp <= 0x180f) or (cp >= 0x200b and cp <= 0x200f) or
        (cp >= 0x202a and cp <= 0x202e) or (cp >= 0x2060 and cp <= 0x206f) or
        cp == 0x3164 or (cp >= 0xfe00 and cp <= 0xfe0f) or cp == 0xfeff or
        cp == 0xffa0 or (cp >= 0xfff0 and cp <= 0xfff8) or
        (cp >= 0x1bca0 and cp <= 0x1bca3) or (cp >= 0x1d173 and cp <= 0x1d17a) or
        (cp >= 0xe0000 and cp <= 0xe0fff);
}
pub const LoadedFace = struct { candidate: *const Candidate, blob: *Blob, alias: []const u8 };
pub const SlotFaces = struct {
    candidates: []const Candidate = &.{},
    primary: ?LoadedFace = null,
    pub fn firstCovering(self: SlotFaces, codepoints: []const u21) ?usize {
        for (self.candidates, 0..) |*candidate, index| if (candidate.coversCluster(codepoints)) return index;
        return null;
    }
};
const Stamp = struct {
    inode: std.Io.File.INode,
    size: u64,
    mtime: i96,
    ctime: i96,
    fn read(io: std.Io, path: []const u8) ?Stamp {
        const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return null;
        return fromStat(stat);
    }
    fn fromStat(stat: std.Io.File.Stat) Stamp {
        return .{ .inode = stat.inode, .size = stat.size, .mtime = stat.mtime.nanoseconds, .ctime = stat.ctime.nanoseconds };
    }
};
const Watch = struct { path: []const u8, stamp: ?Stamp };
pub const Snapshot = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    refs: Atomic(usize) = .init(1),
    budget: *Budget,
    config: *fc.Config,
    request_id: u64,
    generation: u64,
    preferences: Preferences,
    catalog: []const []const u8 = &.{},
    slots: [8]SlotFaces = @splat(.{}),
    watches: []const Watch = &.{},
    pub fn retain(self: *Snapshot) *Snapshot {
        _ = self.refs.fetchAdd(1, .monotonic);
        return self;
    }
    pub fn release(self: *Snapshot) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        for (self.slots) |slot| {
            if (slot.primary) |face| face.blob.release();
            for (slot.candidates) |candidate| fc.FcPatternDestroy(candidate.pattern);
        }
        fc.FcConfigDestroy(self.config);
        self.arena.deinit();
        const budget = self.budget;
        _ = budget.snapshots.fetchSub(1, .acq_rel);
        self.allocator.destroy(self);
        budget.release();
    }
    pub fn primary(self: *const Snapshot, slot: Slot) LoadedFace {
        return self.slots[@backingInt(slot)].primary.?;
    }
    pub fn changed(self: *const Snapshot, io: std.Io) bool {
        if (fc.FcConfigUptoDate(self.config) == 0) return true;
        for (self.watches) |watch| if (!std.meta.eql(watch.stamp, Stamp.read(io, watch.path))) return true;
        return false;
    }
};
const CachedBlob = struct { path: []const u8, stamp: Stamp, blob: *Blob };
const Store = struct {
    allocator: Allocator,
    budget: *Budget,
    blobs: std.ArrayList(CachedBlob) = .empty,
    fn init(a: Allocator, options: Options) !Store {
        const budget = try a.create(Budget);
        budget.* = .{ .allocator = a, .options = options };
        return .{ .allocator = a, .budget = budget };
    }
    fn deinit(self: *Store) void {
        for (self.blobs.items) |entry| {
            self.allocator.free(entry.path);
            entry.blob.release();
        }
        self.blobs.deinit(self.allocator);
        self.budget.release();
    }
    fn evict(self: *Store) void {
        var i: usize = 0;
        while (i < self.blobs.items.len) {
            const entry = self.blobs.items[i];
            if (entry.blob.refs.load(.acquire) == 1) {
                self.allocator.free(entry.path);
                entry.blob.release();
                _ = self.blobs.swapRemove(i);
            } else i += 1;
        }
    }
    fn load(self: *Store, io: std.Io, path: []const u8) !*Blob {
        const stamp = Stamp.read(io, path) orelse return error.FontFileUnavailable;
        for (self.blobs.items) |entry| if (std.mem.eql(u8, entry.path, path) and std.meta.eql(entry.stamp, stamp)) return entry.blob.retain();
        self.evict();
        if (stamp.size == 0 or stamp.size > self.budget.options.max_file_bytes) return error.FontFileBudgetExceeded;
        const size: usize = @intCast(stamp.size);
        try Budget.reserve(&self.budget.bytes, size, self.budget.options.max_blob_bytes);
        var reserved = true;
        errdefer if (reserved) {
            _ = self.budget.bytes.fetchSub(size, .acq_rel);
        };
        const file = try std.Io.Dir.cwd().openFile(io, path, .{});
        defer file.close(io);
        if (!std.meta.eql(stamp, Stamp.fromStat(try file.stat(io)))) return error.FontFileChanged;
        const bytes = try self.allocator.alloc(u8, size);
        errdefer self.allocator.free(bytes);
        const read_size = try file.readPositionalAll(io, bytes, 0);
        if (read_size != size or !std.meta.eql(stamp, Stamp.fromStat(try file.stat(io))) or
            !std.meta.eql(@as(?Stamp, stamp), Stamp.read(io, path))) return error.FontFileChanged;
        var identity: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &identity, .{});
        for (self.blobs.items) |entry| if (std.mem.eql(u8, &identity, &entry.blob.identity) and std.mem.eql(u8, bytes, entry.blob.bytes)) {
            self.allocator.free(bytes);
            _ = self.budget.bytes.fetchSub(size, .acq_rel);
            reserved = false;
            return entry.blob.retain();
        };
        const blob = try self.allocator.create(Blob);
        errdefer self.allocator.destroy(blob);
        const owned_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned_path);
        try self.blobs.append(self.allocator, .{ .path = owned_path, .stamp = stamp, .blob = blob });
        self.budget.retain();
        blob.* = .{ .allocator = self.allocator, .budget = self.budget, .bytes = bytes, .identity = identity };
        reserved = false;
        return blob.retain();
    }
};

/// Synchronous startup/fixture API. The caller's allocator must stay alive until
/// the last snapshot/blob release, and be thread-safe if those cross threads.
pub fn prepare(a: Allocator, io: std.Io, preferences: Preferences, request_id: u64, options: Options) !*Snapshot {
    var store = try Store.init(a, options);
    defer store.deinit();
    return prepareWithStore(&store, io, preferences, request_id, options);
}
fn prepareWithStore(store: *Store, io: std.Io, preferences: Preferences, id: u64, options: Options) !*Snapshot {
    try preferences.validate();
    try Budget.reserve(&store.budget.snapshots, 1, options.max_snapshots);
    var reservation_owned = true;
    errdefer if (reservation_owned) {
        _ = store.budget.snapshots.fetchSub(1, .acq_rel);
    };
    const config = fc.FcConfigCreate() orelse return error.FontconfigAllocation;
    var config_owned = true;
    errdefer if (config_owned) fc.FcConfigDestroy(config);
    const a = store.allocator;
    const config_file = if (options.config_file) |p| try a.dupeSentinel(u8, p, 0) else null;
    defer if (config_file) |p| a.free(p);
    if (fc.FcConfigParseAndLoad(config, if (config_file) |p| p.ptr else null, 1) == 0) return error.FontconfigConfiguration;
    if (fc.FcConfigBuildFonts(config) == 0) return error.FontconfigConfiguration;
    const snapshot = try a.create(Snapshot);
    snapshot.* = .{ .allocator = a, .arena = .init(a), .budget = store.budget, .config = config, .request_id = id, .generation = id, .preferences = .{} };
    store.budget.retain();
    // release() owns both snapshot reservation and config from here onward.
    config_owned = false;
    reservation_owned = false;
    var snapshot_owned = true;
    errdefer if (snapshot_owned) snapshot.release();
    const arena = snapshot.arena.allocator();
    snapshot.preferences = try preferences.clone(arena);
    snapshot.catalog = try catalog(config, arena, options.max_catalog_families);
    try validateInstalled(snapshot.catalog, preferences, arena);
    for (&snapshot.slots, 0..) |*slot_faces, i| {
        const slot: Slot = @fromBackingInt(@intCast(i));
        const selection = if (slot.role() == .body) preferences.body else preferences.mono;
        slot_faces.candidates = try match(config, arena, selection, slot, options.max_candidates_per_slot);
        if (slot_faces.candidates.len == 0) return error.NoSystemFont;
        const candidate = &slot_faces.candidates[0];
        try validateRenderable(candidate);
        const blob = try store.load(io, candidate.path);
        slot_faces.primary = .{ .candidate = candidate, .blob = blob, .alias = "" };
        slot_faces.primary.?.alias = try std.fmt.allocPrint(arena, "system-font-{d}-{d}-0", .{ id, i });
    }
    snapshot.watches = try watches(snapshot, io, arena, options);
    snapshot_owned = false;
    return snapshot;
}
fn catalog(config: *fc.Config, a: Allocator, maximum: usize) ![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(a);
    const set = fc.FcConfigGetFonts(config, 0) orelse return error.NoSystemFont;
    for (set.fonts[0..@intCast(set.nfont)]) |pattern| {
        var n: c_int = 0;
        while (true) : (n += 1) {
            var value: ?[*:0]u8 = null;
            if (fc.FcPatternGetString(pattern, "family", n, &value) != 0) break;
            const name = std.mem.span(value orelse break);
            var duplicate = false;
            for (names.items) |existing| if (std.mem.eql(u8, existing, name)) {
                duplicate = true;
                break;
            };
            if (duplicate) continue;
            if (names.items.len >= maximum) return error.CatalogBudgetExceeded;
            try names.append(a, try a.dupe(u8, name));
        }
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn less(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.order(u8, x, y) == .lt;
        }
    }.less);
    return try names.toOwnedSlice(a);
}
fn validateInstalled(names: []const []const u8, prefs: Preferences, a: Allocator) !void {
    inline for (.{ prefs.body, prefs.mono }) |selection| switch (selection) {
        .system => {}, // Generic aliases are intent, never compared to resolved family.
        .family => |family| {
            const requested = try a.dupeSentinel(u8, family, 0);
            defer a.free(requested);
            var found = false;
            for (names) |name| {
                const installed = try a.dupeSentinel(u8, name, 0);
                defer a.free(installed);
                if (fc.FcStrCmpIgnoreCase(requested, installed) == 0) {
                    found = true;
                    break;
                }
            }
            if (!found) return error.FamilyNotInstalled;
        },
    };
}
fn match(config: *fc.Config, a: Allocator, selection: Selection, slot: Slot, maximum: usize) ![]const Candidate {
    const request = fc.FcPatternCreate() orelse return error.FontconfigAllocation;
    defer fc.FcPatternDestroy(request);
    const family = try a.dupeSentinel(u8, switch (selection) {
        .system => if (slot.role() == .body) "sans-serif" else "monospace",
        .family => |name| name,
    }, 0);
    defer a.free(family);
    const style = slot.style();
    const bold = style == .bold or style == .bold_italic;
    const italic = style == .italic or style == .bold_italic;
    if (fc.FcPatternAddString(request, "family", family) == 0 or
        fc.FcPatternAddInteger(request, "weight", if (bold) 200 else 80) == 0 or
        fc.FcPatternAddInteger(request, "slant", if (italic) 100 else 0) == 0 or
        fc.FcPatternAddBool(request, "scalable", 1) == 0) return error.FontconfigAllocation;
    if (fc.FcConfigSubstitute(config, request, 0) == 0) return error.FontconfigAllocation;
    fc.FcDefaultSubstitute(request);
    var coverage: ?*fc.CharSet = null;
    var result: c_int = 0;
    // trim=false retains overlapping coverage faces needed for whole clusters.
    const sorted = fc.FcFontSort(config, request, 0, &coverage, &result) orelse return error.FontconfigMatch;
    defer fc.FcFontSetSortDestroy(sorted);
    defer if (coverage) |set| fc.FcCharSetDestroy(set);
    if (result != 0 or sorted.nfont < 0) return error.FontconfigMatch;
    const count: usize = @intCast(sorted.nfont);
    if (count > maximum) return error.CandidateBudgetExceeded;
    const candidates = try a.alloc(Candidate, count);
    var initialized: usize = 0;
    errdefer for (candidates[0..initialized]) |candidate| fc.FcPatternDestroy(candidate.pattern);
    for (sorted.fonts[0..count], candidates) |font, *candidate| {
        const rendered = fc.FcFontRenderPrepare(config, request, font) orelse return error.FontconfigAllocation;
        var owned = true;
        errdefer if (owned) fc.FcPatternDestroy(rendered);
        var charset: ?*fc.CharSet = null;
        _ = fc.FcPatternGetCharSet(rendered, "charset", 0, &charset);
        var matrix: ?*fc.Matrix = null;
        _ = fc.FcPatternGetMatrix(rendered, "matrix", 0, &matrix);
        candidate.* = .{
            .path = fc.string(rendered, "file") orelse return error.FontconfigMissingFile,
            .family = fc.string(rendered, "family") orelse "",
            .style_name = fc.string(rendered, "style") orelse "",
            .index = fc.integer(rendered, "index", 0),
            .weight = fc.integer(font, "weight", 80),
            .slant = fc.integer(font, "slant", 0),
            .variations = fc.string(rendered, "fontvariations") orelse "",
            .variable = fc.boolean(rendered, "variable", false),
            .named_instance = fc.boolean(rendered, "namedinstance", false),
            .color = fc.boolean(rendered, "color", false),
            .charset = charset,
            .pattern = rendered,
            .rendering = .{ .antialias = fc.boolean(rendered, "antialias", true), .hinting = fc.boolean(rendered, "hinting", true), .autohint = fc.boolean(rendered, "autohint", false), .embedded_bitmap = fc.boolean(rendered, "embeddedbitmap", true), .embolden = fc.boolean(rendered, "embolden", false), .rgba = fc.integer(rendered, "rgba", 0), .hint_style = fc.integer(rendered, "hintstyle", 3), .lcd_filter = fc.integer(rendered, "lcdfilter", 1), .dpi = fc.double(rendered, "dpi", 75), .scale = fc.double(rendered, "scale", 1), .matrix = if (matrix) |m| m.* else .{ .xx = 1, .xy = 0, .yx = 0, .yy = 1 } },
        };
        owned = false;
        initialized += 1;
    }
    return candidates;
}
pub fn validateRenderable(candidate: *const Candidate) !void {
    // Until the DVUI raster API supports these, refuse rather than silently
    // selecting face zero, losing named instances/axes or synthesizing styles.
    if (candidate.index < 0) return error.UnsupportedFaceIndex;
    // FT_Open_Face accepts the full Fontconfig index, including named-instance
    // bits. Explicit variation coordinates still need an FT axis-setting API.
    if (candidate.variations.len != 0) return error.UnsupportedFontVariations;
    const r = candidate.rendering;
    for ([_]f64{ r.matrix.xx, r.matrix.xy, r.matrix.yx, r.matrix.yy }) |value| {
        // FreeType FT_Matrix stores each coordinate in signed 16.16.
        if (!std.math.isFinite(value) or value < -32768 or value > 32767.9999847412109375)
            return error.InvalidRenderingMatrix;
    }
}
fn watches(snapshot: *Snapshot, io: std.Io, a: Allocator, options: Options) ![]const Watch {
    var list: std.ArrayList(Watch) = .empty;
    defer list.deinit(a);
    const lists = [_]?*fc.StrList{ fc.FcConfigGetConfigFiles(snapshot.config), fc.FcConfigGetConfigDirs(snapshot.config), fc.FcConfigGetFontDirs(snapshot.config) };
    for (lists) |maybe| if (maybe) |strings| {
        defer fc.FcStrListDone(strings);
        while (fc.FcStrListNext(strings)) |path| try addWatch(&list, a, io, std.mem.span(path), options.max_watch_paths);
    };
    if (options.config_file) |path| try addWatch(&list, a, io, path, options.max_watch_paths);
    // Watch all candidate file metadata without opening font contents. Parent
    // links catch symlink/generation switches; following stat catches targets.
    for (snapshot.slots) |slot| for (slot.candidates) |candidate| try addWatch(&list, a, io, candidate.path, options.max_watch_paths);
    return try list.toOwnedSlice(a);
}
fn addWatch(list: *std.ArrayList(Watch), a: Allocator, io: std.Io, path: []const u8, maximum: usize) !void {
    var current = path;
    var depth: usize = 0;
    while (current.len != 0) : (depth += 1) {
        // The immediate parent observes replacements/additions. Higher regular
        // ancestors would cause unrelated /tmp or home changes to refresh fonts;
        // retain only symlink ancestors (Nix/Home Manager generation switches).
        const stat = std.Io.Dir.cwd().statFile(io, current, .{ .follow_symlinks = false }) catch null;
        const relevant = depth < 2 or (stat != null and stat.?.kind == .sym_link);
        var duplicate = !relevant;
        for (list.items) |entry| if (std.mem.eql(u8, entry.path, current)) {
            duplicate = true;
            break;
        };
        if (!duplicate) {
            if (list.items.len >= maximum) return error.WatchBudgetExceeded;
            const owned = try a.dupe(u8, current);
            errdefer a.free(owned);
            try list.append(a, .{ .path = owned, .stamp = Stamp.read(io, current) });
        }
        const parent = std.fs.path.dirname(current) orelse break;
        if (std.mem.eql(u8, parent, current)) break;
        current = parent;
    }
}

pub const RequestKind = enum { selection, refresh, fallback, automatic_refresh };
pub const Failure = struct {
    request_id: u64,
    kind: RequestKind,
    err: anyerror,
    message: [192]u8 = @splat(0),
    message_len: usize = 0,
    pub fn text(self: *const Failure) []const u8 {
        return self.message[0..self.message_len];
    }
    pub fn init(id: u64, kind: RequestKind, err: anyerror) Failure {
        var failure: Failure = .{ .request_id = id, .kind = kind, .err = err };
        const formatted = std.fmt.bufPrint(&failure.message, "Font {s}: {s}", .{ @tagName(kind), @errorName(err) }) catch "Font preparation failed";
        failure.message_len = formatted.len;
        return failure;
    }
};
pub const Status = struct {
    newest_selection: u64 = 0,
    active_request: u64 = 0,
    active_generation: u64 = 0,
    pending_request: ?u64 = null,
    latest_failure: ?Failure = null,
};
pub const PreparedFallback = struct {
    allocator: Allocator,
    refs: Atomic(usize) = .init(1),
    request_id: u64,
    generation: u64,
    base: *Snapshot,
    slot: Slot,
    candidate_index: usize,
    face: LoadedFace,
    pub fn retain(self: *PreparedFallback) *PreparedFallback {
        _ = self.refs.fetchAdd(1, .monotonic);
        return self;
    }
    pub fn release(self: *PreparedFallback) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        self.face.blob.release();
        self.base.release();
        self.allocator.free(self.face.alias);
        self.allocator.destroy(self);
    }
};
/// Owns its base until Completion.deinit, including after a selection replaces it.
pub const FallbackFailure = struct { base: *Snapshot, slot: Slot, candidate_index: usize, failure: Failure };
pub const Completion = union(enum) {
    prepared: *Snapshot,
    fallback: *PreparedFallback,
    failed: Failure,
    fallback_failed: FallbackFailure,
    pub fn deinit(self: Completion) void {
        switch (self) {
            .prepared => |s| s.release(),
            .fallback => |s| s.release(),
            .failed => {},
            .fallback_failed => |f| f.base.release(),
        }
    }
    pub fn requestId(self: Completion) u64 {
        return switch (self) {
            .prepared => |s| s.request_id,
            .fallback => |s| s.request_id,
            .failed => |f| f.request_id,
            .fallback_failed => |f| f.failure.request_id,
        };
    }
};
const SelectionRequest = struct { id: u64, kind: RequestKind, preferences: Preferences };
const FallbackRequest = struct { id: u64, base: *Snapshot, slot: Slot, candidate_index: usize };

/// One worker owns Fontconfig discovery and Store mutations. Short Io.Mutex
/// critical sections protect queues/status; expensive matching and I/O run unlocked.
/// smp_allocator lets detached snapshots survive Service.destroy and cross threads.
pub const Service = struct {
    allocator: Allocator = std.heap.smp_allocator,
    io: std.Io,
    options: Options,
    mutex: std.Io.Mutex = .init,
    wake: std.Io.Event = .unset,
    worker: ?std.Thread = null,
    stopping: bool = false,
    next_id: u64 = 0,
    requested: Preferences = .{},
    selection: ?SelectionRequest = null,
    fallbacks: std.ArrayList(FallbackRequest) = .empty,
    completion: ?Completion = null,
    fallback_completions: std.ArrayList(Completion) = .empty,
    active: ?*Snapshot = null,
    observed: Status = .{},
    store: Store,
    in_flight_fallback: ?FallbackRequest = null,

    pub fn create(io: std.Io, options: Options) !*Service {
        if (options.check_interval_seconds < 1 or options.max_fallback_requests == 0 or options.max_snapshots == 0)
            return error.InvalidOptions;
        const a = std.heap.smp_allocator;
        const self = try a.create(Service);
        errdefer a.destroy(self);
        var owned_options = options;
        owned_options.config_file = if (options.config_file) |p| try a.dupe(u8, p) else null;
        errdefer if (owned_options.config_file) |p| a.free(p);
        self.* = .{ .io = io, .options = owned_options, .store = try Store.init(a, owned_options) };
        errdefer self.store.deinit();
        self.worker = try std.Thread.spawn(.{}, workerMain, .{self});
        return self;
    }
    pub fn destroy(self: *Service) void {
        self.lock();
        self.stopping = true;
        self.wake.set(self.io);
        self.unlock();
        if (self.worker) |worker| worker.join();
        if (self.selection) |pending| pending.preferences.deinit(self.allocator);
        for (self.fallbacks.items) |pending| pending.base.release();
        self.fallbacks.deinit(self.allocator);
        if (self.completion) |completion| completion.deinit();
        for (self.fallback_completions.items) |completion| completion.deinit();
        self.fallback_completions.deinit(self.allocator);
        if (self.active) |active| active.release();
        self.requested.deinit(self.allocator);
        self.store.deinit();
        if (self.options.config_file) |p| self.allocator.free(p);
        self.allocator.destroy(self);
    }
    fn lock(self: *Service) void {
        self.mutex.lockUncancelable(self.io);
    }
    fn unlock(self: *Service) void {
        self.mutex.unlock(self.io);
    }
    fn nextId(self: *Service) !u64 {
        if (self.next_id == std.math.maxInt(u64)) return error.RequestIdExhausted;
        self.next_id += 1;
        return self.next_id;
    }
    /// Copies both family strings before returning. A/B/A requests are separate
    /// monotonic transactions; only the newest selection completion survives.
    pub fn request(self: *Service, preferences: Preferences) !u64 {
        const owned = try preferences.clone(self.allocator);
        errdefer owned.deinit(self.allocator);
        self.lock();
        defer self.unlock();
        if (self.stopping) return error.ServiceStopped;
        return self.enqueueSelection(owned, .selection);
    }
    pub fn refresh(self: *Service) !u64 {
        self.lock();
        defer self.unlock();
        if (self.stopping) return error.ServiceStopped;
        const owned = try self.requested.clone(self.allocator);
        errdefer owned.deinit(self.allocator);
        return self.enqueueSelection(owned, .refresh);
    }
    fn enqueueSelection(self: *Service, owned: Preferences, kind: RequestKind) !u64 {
        const latest = try owned.clone(self.allocator);
        errdefer latest.deinit(self.allocator);
        const id = try self.nextId();
        if (self.selection) |previous| previous.preferences.deinit(self.allocator);
        self.requested.deinit(self.allocator);
        self.requested = latest;
        self.selection = .{ .id = id, .kind = kind, .preferences = owned };
        if (self.completion) |completion| completion.deinit();
        self.completion = null;
        for (self.fallbacks.items) |pending| pending.base.release();
        self.fallbacks.clearRetainingCapacity();
        for (self.fallback_completions.items) |completion| completion.deinit();
        self.fallback_completions.clearRetainingCapacity();
        self.observed.newest_selection = id;
        self.observed.pending_request = id;
        self.wake.set(self.io);
        return id;
    }
    pub fn requestedPreferences(self: *Service, allocator: Allocator) !Preferences {
        self.lock();
        defer self.unlock();
        return self.requested.clone(allocator);
    }
    pub fn status(self: *Service) Status {
        self.lock();
        defer self.unlock();
        return self.observed;
    }
    /// A controller's failed EGL/staging/registration transaction is a visible
    /// failure too. Obsolete transactions cannot overwrite a newer status.
    pub fn reportPublicationFailure(self: *Service, id: u64, kind: RequestKind, err: anyerror) void {
        self.lock();
        defer self.unlock();
        if (kind == .fallback) {
            if (self.observed.pending_request != null or id <= self.observed.active_generation) return;
        } else {
            if (id != self.observed.newest_selection) return;
            self.observed.pending_request = null;
        }
        self.observed.latest_failure = Failure.init(id, kind, err);
    }
    /// Runtime commits hold the queue mutex across the final infallible window
    /// publication, preventing refresh/selection from invalidating staged epochs.
    /// Callback must not allocate, perform native I/O, or call Service methods.
    pub fn commitPrepared(self: *Service, snapshot: *Snapshot, context: anytype, comptime publish: fn (@TypeOf(context)) void) !void {
        self.lock();
        defer self.unlock();
        try self.validatePreparedLocked(snapshot);
        publish(context);
        self.recordAppliedLocked(snapshot);
    }
    pub fn commitFallback(self: *Service, fallback: *PreparedFallback, context: anytype, comptime publish: fn (@TypeOf(context)) void) !void {
        self.lock();
        defer self.unlock();
        try self.validateFallbackLocked(fallback);
        publish(context);
        self.observed.active_generation = fallback.generation;
    }
    /// For startup/tests without a concurrently publishing registry. Runtime
    /// controllers must use commitPrepared/commitFallback to close the race.
    pub fn acknowledgeApplied(self: *Service, snapshot: *Snapshot) !void {
        self.lock();
        defer self.unlock();
        try self.validatePreparedLocked(snapshot);
        self.recordAppliedLocked(snapshot);
    }
    fn validatePreparedLocked(self: *Service, snapshot: *Snapshot) !void {
        if (self.stopping) return error.ServiceStopped;
        if (snapshot.request_id != self.observed.newest_selection or snapshot.request_id < self.observed.active_request or
            snapshot.generation < self.observed.active_generation)
            return error.ObsoleteRequest;
    }
    fn recordAppliedLocked(self: *Service, snapshot: *Snapshot) void {
        if (self.active) |previous| previous.release();
        self.active = snapshot.retain();
        self.observed.active_request = snapshot.request_id;
        self.observed.active_generation = snapshot.generation;
        self.observed.pending_request = null;
        self.observed.latest_failure = null;
    }
    pub fn acknowledgeFallback(self: *Service, fallback: *PreparedFallback) !void {
        self.lock();
        defer self.unlock();
        try self.validateFallbackLocked(fallback);
        self.observed.active_generation = fallback.generation;
    }
    fn validateFallbackLocked(self: *Service, fallback: *PreparedFallback) !void {
        if (self.stopping) return error.ServiceStopped;
        if (!self.fallbackCurrent(fallback.base) or fallback.generation <= self.observed.active_generation)
            return error.ObsoleteRequest;
    }
    fn fallbackCurrent(self: *Service, base: *Snapshot) bool {
        return self.active == base and self.observed.pending_request == null;
    }
    /// Reject only against the still-current snapshot. Refresh/selection gets a
    /// fresh candidate set; late worker or staging failures cannot poison it.
    /// Returns true once per candidate so callers schedule only bounded retries.
    pub fn rejectFallback(self: *Service, base: *Snapshot, slot: Slot, candidate_index: usize, failure: Failure) bool {
        self.lock();
        defer self.unlock();
        if (self.stopping or !self.fallbackCurrent(base)) return false;
        const candidates = base.slots[@backingInt(slot)].candidates;
        if (candidate_index >= candidates.len) return false;
        if (@constCast(&candidates[candidate_index]).fallback_rejected.swap(true, .acq_rel)) return false;
        self.observed.latest_failure = failure;
        return true;
    }
    /// Candidate index is chosen by coverage metadata, never a locale classifier.
    /// Repeat misses for the same candidate share one bounded preparation request.
    pub fn requestFallback(self: *Service, base: *Snapshot, slot: Slot, candidate_index: usize) !u64 {
        if (candidate_index >= base.slots[@backingInt(slot)].candidates.len) return error.InvalidCandidate;
        self.lock();
        defer self.unlock();
        if (self.stopping) return error.ServiceStopped;
        if (!self.fallbackCurrent(base)) return error.ObsoleteRequest;
        if (base.slots[@backingInt(slot)].candidates[candidate_index].fallback_rejected.load(.acquire)) return error.RejectedCandidate;
        for (self.fallbacks.items) |pending| if (pending.base == base and pending.slot == slot and pending.candidate_index == candidate_index) return pending.id;
        if (self.in_flight_fallback) |pending| if (pending.base == base and pending.slot == slot and pending.candidate_index == candidate_index) return pending.id;
        for (self.fallback_completions.items) |completion| switch (completion) {
            .fallback => |ready| if (ready.base == base and ready.slot == slot and ready.candidate_index == candidate_index) return ready.request_id,
            .fallback_failed => |ready| if (ready.base == base and ready.slot == slot and ready.candidate_index == candidate_index) return ready.failure.request_id,
            else => {},
        };
        const queued = self.fallbacks.items.len + self.fallback_completions.items.len + @intFromBool(self.in_flight_fallback != null);
        if (queued >= self.options.max_fallback_requests) return error.FallbackQueueFull;
        const id = try self.nextId();
        try self.fallbacks.ensureUnusedCapacity(self.allocator, 1);
        // Reserve the result before accepting work: failures must never lose the
        // context needed to release a cached miss, even under memory pressure.
        try self.fallback_completions.ensureTotalCapacity(self.allocator, queued + 1);
        self.fallbacks.appendAssumeCapacity(.{ .id = id, .base = base.retain(), .slot = slot, .candidate_index = candidate_index });
        self.wake.set(self.io);
        return id;
    }
    /// Transfers one owned result to the controller. The controller must recheck
    /// status before publication because a request can arrive while staging views.
    pub fn poll(self: *Service) ?Completion {
        self.lock();
        defer self.unlock();
        if (self.completion) |completion| {
            self.completion = null;
            return completion;
        }
        while (self.fallback_completions.items.len != 0) {
            const completion = self.fallback_completions.orderedRemove(0);
            switch (completion) {
                .fallback => |fallback| if (!self.fallbackCurrent(fallback.base)) {
                    completion.deinit();
                    continue;
                },
                .fallback_failed => |failure| if (!self.fallbackCurrent(failure.base)) {
                    completion.deinit();
                    continue;
                },
                else => {},
            }
            return completion;
        }
        return null;
    }
    fn workerMain(self: *Service) void {
        while (true) {
            self.lock();
            if (self.stopping) {
                self.unlock();
                return;
            }
            if (self.selection) |pending| {
                self.selection = null;
                self.unlock();
                const result: Completion = if (prepareWithStore(&self.store, self.io, pending.preferences, pending.id, self.options)) |snapshot|
                    .{ .prepared = snapshot }
                else |err|
                    .{ .failed = Failure.init(pending.id, pending.kind, err) };
                pending.preferences.deinit(self.allocator);
                self.lock();
                if (self.stopping or pending.id != self.observed.newest_selection) result.deinit() else {
                    if (self.completion) |old| old.deinit();
                    self.completion = result;
                    if (result == .failed) {
                        self.observed.latest_failure = result.failed;
                        self.observed.pending_request = null;
                    }
                }
                self.unlock();
                continue;
            }
            if (self.fallbacks.items.len != 0) {
                const pending = self.fallbacks.orderedRemove(0);
                self.in_flight_fallback = pending;
                self.unlock();
                const result: Completion = if (self.prepareFallback(pending)) |fallback|
                    .{ .fallback = fallback }
                else |err|
                    .{ .fallback_failed = .{ .base = pending.base.retain(), .slot = pending.slot, .candidate_index = pending.candidate_index, .failure = Failure.init(pending.id, .fallback, err) } };
                self.lock();
                self.in_flight_fallback = null;
                if (self.stopping or !self.fallbackCurrent(pending.base)) result.deinit() else {
                    self.fallback_completions.appendAssumeCapacity(result);
                    if (result == .fallback_failed) self.observed.latest_failure = result.fallback_failed.failure;
                }
                pending.base.release();
                self.unlock();
                continue;
            }
            // Reset under the same mutex that enqueuers use, so no wake is lost.
            self.wake.reset();
            self.unlock();
            self.wake.waitTimeout(self.io, .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(self.options.check_interval_seconds) } }) catch |err| switch (err) {
                error.Timeout => self.checkChanges(),
                error.Canceled => return,
            };
        }
    }
    fn prepareFallback(self: *Service, pending: FallbackRequest) !*PreparedFallback {
        const candidate = &pending.base.slots[@backingInt(pending.slot)].candidates[pending.candidate_index];
        try validateRenderable(candidate);
        const blob = try self.store.load(self.io, candidate.path);
        errdefer blob.release();
        const alias = try std.fmt.allocPrint(self.allocator, "system-font-{d}-{d}-{d}", .{ pending.id, @backingInt(pending.slot), pending.candidate_index });
        errdefer self.allocator.free(alias);
        const fallback = try self.allocator.create(PreparedFallback);
        fallback.* = .{ .allocator = self.allocator, .request_id = pending.id, .generation = pending.id, .base = pending.base.retain(), .slot = pending.slot, .candidate_index = pending.candidate_index, .face = .{ .candidate = candidate, .blob = blob, .alias = alias } };
        return fallback;
    }
    fn checkChanges(self: *Service) void {
        self.lock();
        const active = if (self.active) |snapshot| snapshot.retain() else null;
        const newest = self.observed.newest_selection;
        self.unlock();
        const snapshot = active orelse return;
        defer snapshot.release();
        if (!snapshot.changed(self.io)) return;
        self.lock();
        defer self.unlock();
        // The same failed config should not create an unbounded retry loop. A
        // failed auto refresh leaves newest != active; explicit Refresh retries.
        if (self.stopping or newest != self.observed.newest_selection or
            self.observed.newest_selection != self.observed.active_request or !self.fallbackCurrent(snapshot)) return;
        const owned = self.requested.clone(self.allocator) catch return;
        _ = self.enqueueSelection(owned, .automatic_refresh) catch {
            owned.deinit(self.allocator);
        };
    }
};

// Dedicated tests import this module; keep private ownership validation here.
test {
    _ = @import("font_system_tests.zig");
    _ = @import("font_preferences.zig");
}

test "private Fontconfig aliases, real styles, TTC indices and Unicode coverage" {
    const t = std.testing;
    const config = try @import("font_system_test_fixture.zig").config();
    defer fc.FcConfigDestroy(config);
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const families = try catalog(config, arena.allocator(), 8);
    try validateInstalled(families, .{}, arena.allocator());
    try validateInstalled(families, .{ .body = .{ .family = "fixture sans" } }, arena.allocator());
    try t.expectError(error.FamilyNotInstalled, validateInstalled(families, .{ .body = .{ .family = "Uninstalled Family" } }, arena.allocator()));
    for (0..8) |i| {
        const slot: Slot = @fromBackingInt(@intCast(i));
        const candidates = try match(config, arena.allocator(), .system, slot, 16);
        defer for (candidates) |candidate| fc.FcPatternDestroy(candidate.pattern);
        const first = &candidates[0];
        try t.expectEqualStrings(if (slot.role() == .body) "Fixture Sans" else "Fixture Mono", first.family);
        const style: usize = @backingInt(slot.style());
        try t.expectEqual(@as(i32, @intCast(style + 2)), first.index);
        try t.expectEqual(@as(i32, if (style == 1 or style == 3) 200 else 80), first.weight);
        try t.expectEqual(@as(i32, if (style >= 2) 100 else 0), first.slant);
        try t.expect(first.coversCluster(&.{ 0x41, 0x4e2d, 0x1f642, 0x200d, 0xfe0f }));
        try t.expect(!first.covers(0x42) and !first.covers(0xd800) and !first.covers(0x110000));
        try validateRenderable(first);
    }
    const candidates = try match(config, arena.allocator(), .system, .body_normal, 16);
    defer for (candidates) |candidate| fc.FcPatternDestroy(candidate.pattern);
    var face = candidates[0];
    face.index = 0x00020003;
    face.named_instance = true;
    face.rendering.embolden = true;
    face.rendering.matrix.xy = 0.2;
    try validateRenderable(&face);
    face.variations = "wght=650";
    try t.expectError(error.UnsupportedFontVariations, validateRenderable(&face));
    face.variations = "";
    face.rendering.matrix.xy = 32768;
    try t.expectError(error.InvalidRenderingMatrix, validateRenderable(&face));
}

fn testService() !*Service {
    const a = std.testing.allocator;
    const service = try a.create(Service);
    errdefer a.destroy(service);
    service.* = .{ .allocator = a, .io = std.testing.io, .options = .{}, .store = try Store.init(a, .{}) };
    return service;
}
fn testSnapshot(store: *Store, id: u64) !*Snapshot {
    const config = try @import("font_system_test_fixture.zig").config();
    var config_owned = true;
    errdefer if (config_owned) fc.FcConfigDestroy(config);
    const snapshot = try store.allocator.create(Snapshot);
    snapshot.* = .{ .allocator = store.allocator, .arena = .init(store.allocator), .budget = store.budget, .config = config, .request_id = id, .generation = id, .preferences = .{} };
    store.budget.retain();
    _ = store.budget.snapshots.fetchAdd(1, .monotonic);
    config_owned = false;
    errdefer snapshot.release();
    snapshot.slots[0].candidates = try match(config, snapshot.arena.allocator(), .system, .body_normal, 16);
    return snapshot;
}

test "copied requests are monotonic and guarded commits reject stale fallback leases" {
    const t = std.testing;
    const service = try testService();
    defer service.destroy();
    var name = [_]u8{ 'T', 'e', 's', 't' };
    const first = try service.request(.{ .body = .{ .family = &name } });
    name[0] = 'X';
    try t.expectEqualStrings("Test", service.requested.body.family);
    const second = try service.request(.{});
    try t.expect(second > first);
    const base = try testSnapshot(&service.store, second);
    defer base.release();
    var published: usize = 0;
    const Publish = struct {
        fn run(value: *usize) void {
            value.* += 1;
        }
    };
    try service.commitPrepared(base, &published, Publish.run);
    try t.expectEqual(@as(usize, 1), published);
    const fallback = try service.requestFallback(base, .body_normal, 1);
    try t.expectEqual(fallback, try service.requestFallback(base, .body_normal, 1));
    try t.expectEqual(@as(usize, 1), service.fallbacks.items.len);
    try t.expectEqual(@as(usize, 3), base.refs.load(.monotonic));
    const third = try service.request(.{});
    try t.expect(third > fallback);
    try t.expectEqual(@as(usize, 0), service.fallbacks.items.len);
    try t.expectEqual(@as(usize, 2), base.refs.load(.monotonic));
    try t.expectError(error.ObsoleteRequest, service.commitPrepared(base, &published, Publish.run));
    try t.expectEqual(@as(usize, 1), published);
    try t.expectError(error.ObsoleteRequest, service.requestFallback(base, .body_normal, 1));
    try t.expectError(error.InvalidFamily, service.request(.{ .body = .{ .family = "" } }));
    try t.expectEqual(third, service.status().newest_selection);
    service.next_id = std.math.maxInt(u64);
    try t.expectError(error.RequestIdExhausted, service.refresh());
}

test "immutable blobs share bytes and survive the worker store" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "one.ttf", .data = "fixture bytes" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "two.ttf", .data = "fixture bytes" });
    const one = try tmp.dir.realPathFileAlloc(t.io, "one.ttf", t.allocator);
    defer t.allocator.free(one);
    const two = try tmp.dir.realPathFileAlloc(t.io, "two.ttf", t.allocator);
    defer t.allocator.free(two);
    var store = try Store.init(t.allocator, .{ .max_blob_bytes = 32 });
    var live = true;
    defer if (live) store.deinit();
    const first = try store.load(t.io, one);
    defer first.release();
    const repeated = try store.load(t.io, one);
    defer repeated.release();
    const same = try store.load(t.io, two);
    defer same.release();
    try t.expect(first == repeated and first == same);
    try t.expectEqual(@as(usize, "fixture bytes".len), store.budget.bytes.load(.monotonic));
    try t.expectError(error.ResidencyBudgetExceeded, Budget.reserve(&store.budget.bytes, 33, 32));
    store.deinit();
    live = false;
    try t.expectEqualStrings("fixture bytes", first.bytes);
}

test "private file watches detect reload without watching unrelated ancestors" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "fonts.conf", .data = "<fontconfig/>" });
    const path = try tmp.dir.realPathFileAlloc(t.io, "fonts.conf", t.allocator);
    defer t.allocator.free(path);
    var entries: std.ArrayList(Watch) = .empty;
    defer {
        for (entries.items) |watch| t.allocator.free(watch.path);
        entries.deinit(t.allocator);
    }
    try addWatch(&entries, t.allocator, t.io, path, 8);
    try t.expect(entries.items.len >= 2);
    for (entries.items) |watch| try t.expect(!std.mem.eql(u8, watch.path, "/"));
    const before = entries.items[0].stamp;
    try tmp.dir.writeFile(t.io, .{ .sub_path = "fonts.conf", .data = "<fontconfig><!--new revision--></fontconfig>" });
    try t.expect(!std.meta.eql(before, Stamp.read(t.io, path)));
}

test "worker reports private empty config failure and refresh advances request" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "empty.conf", .data = "<fontconfig/>" });
    const path = try tmp.dir.realPathFileAlloc(t.io, "empty.conf", t.allocator);
    defer t.allocator.free(path);
    const service = try Service.create(t.io, .{ .config_file = path });
    defer service.destroy();
    const id = try service.request(.{});
    var result: ?Completion = null;
    for (0..500) |_| {
        result = service.poll();
        if (result != null) break;
        try std.Io.sleep(t.io, .fromMilliseconds(2), .awake);
    }
    const completion = result orelse return error.WorkerDidNotComplete;
    defer completion.deinit();
    try t.expect(completion == .failed);
    try t.expectEqual(id, completion.requestId());
    try t.expectEqual(@as(u64, 0), service.status().active_generation);
    try t.expect((try service.refresh()) > id);
}

test "snapshot native config and prepared charset survive service shutdown" {
    const t = std.testing;
    const service = try testService();
    var live = true;
    defer if (live) service.destroy();
    const id = try service.request(.{});
    const snapshot = try testSnapshot(&service.store, id);
    defer snapshot.release();
    try service.acknowledgeApplied(snapshot);
    service.destroy();
    live = false;
    try t.expect(snapshot.slots[0].candidates[0].coversCluster(&.{ 0x41, 0x4e2d, 0x1f642 }));
    try t.expectEqual(@as(usize, 1), snapshot.refs.load(.monotonic));
}

test "fallback publication owns bytes, keeps base alive and rejects obsolete callbacks" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "fallback.ttf", .data = "fallback fixture" });
    const path = try tmp.dir.realPathFileAlloc(t.io, "fallback.ttf", t.allocator);
    defer t.allocator.free(path);
    const service = try testService();
    defer service.destroy();
    const selection = try service.request(.{});
    const snapshot = try testSnapshot(&service.store, selection);
    defer snapshot.release();
    const faces = try snapshot.arena.allocator().dupe(Candidate, snapshot.slots[0].candidates);
    faces[1].path = try snapshot.arena.allocator().dupe(u8, path);
    snapshot.slots[0].candidates = faces;
    try service.acknowledgeApplied(snapshot);
    const id = try service.nextId();
    const fallback = try service.prepareFallback(.{ .id = id, .base = snapshot, .slot = .body_normal, .candidate_index = 1 });
    defer fallback.release();
    try t.expectEqualStrings("fallback fixture", fallback.face.blob.bytes);
    try t.expectEqual(@as(usize, 3), snapshot.refs.load(.monotonic));
    var published: usize = 0;
    const Publish = struct {
        fn run(value: *usize) void {
            value.* += 1;
        }
    };
    try service.commitFallback(fallback, &published, Publish.run);
    try t.expectEqual(id, service.status().active_generation);
    try t.expectError(error.ObsoleteRequest, service.commitFallback(fallback, &published, Publish.run));
    try t.expectEqual(@as(usize, 1), published);
    const newer = try service.request(.{});
    try t.expectError(error.ObsoleteRequest, service.commitFallback(fallback, &published, Publish.run));
    try t.expectError(error.ObsoleteRequest, service.requestFallback(snapshot, .body_normal, 1));
    service.reportPublicationFailure(newer, .selection, error.RegistrationFailed);
    try t.expect(service.status().pending_request == null);
    try t.expectEqual(error.RegistrationFailed, service.status().latest_failure.?.err);
    service.reportPublicationFailure(selection, .selection, error.ObsoleteRequest);
    try t.expectEqual(newer, service.status().latest_failure.?.request_id);
    const recovery_id = try service.requestFallback(snapshot, .body_normal, 1);
    const recovery = try service.prepareFallback(.{ .id = recovery_id, .base = snapshot, .slot = .body_normal, .candidate_index = 1 });
    defer recovery.release();
    try service.commitFallback(recovery, &published, Publish.run);
    try t.expectEqual(@as(usize, 2), published);
    try t.expectEqual(recovery_id, service.status().active_generation);
    const late_selection = try testSnapshot(&service.store, newer);
    defer late_selection.release();
    try t.expectError(error.ObsoleteRequest, service.commitPrepared(late_selection, &published, Publish.run));
    try t.expectEqual(@as(usize, 2), published);
    try t.expectEqual(recovery_id, service.status().active_generation);
}

fn testPoll(service: *Service) !Completion {
    for (0..500) |_| {
        if (service.poll()) |completion| return completion;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(2), .awake);
    }
    return error.WorkerDidNotComplete;
}

test "worker fallback failure retains context, coalesces views and advances independent slots" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "later.ttf", .data = "owned worker bytes; FreeType validity is tested by native checks" });
    const path = try tmp.dir.realPathFileAlloc(t.io, "later.ttf", t.allocator);
    defer t.allocator.free(path);
    const missing = try std.fmt.allocPrint(t.allocator, "{s}.absent", .{path});
    defer t.allocator.free(missing);
    const service = try testService();
    defer service.destroy();
    const id = try service.nextId();
    service.observed.newest_selection = id;
    const snapshot = try testSnapshot(&service.store, id);
    defer snapshot.release();
    const slots = [_]Slot{ .body_normal, .mono_normal };
    for (slots) |slot| {
        const faces = @constCast(if (slot == .body_normal)
            try snapshot.arena.allocator().dupe(Candidate, snapshot.slots[0].candidates)
        else
            try match(snapshot.config, snapshot.arena.allocator(), .system, slot, 16));
        try t.expect(faces.len >= 3);
        faces[1].path = try snapshot.arena.allocator().dupe(u8, missing);
        faces[2].path = try snapshot.arena.allocator().dupe(u8, path);
        snapshot.slots[@backingInt(slot)].candidates = faces;
    }
    try service.acknowledgeApplied(snapshot);
    var bad_ids: [2]u64 = undefined;
    for (slots, 0..) |slot, i| {
        bad_ids[i] = try service.requestFallback(snapshot, slot, 1);
        // Two views hitting the same candidate must share one result/retry.
        try t.expectEqual(bad_ids[i], try service.requestFallback(snapshot, slot, 1));
    }
    service.worker = try std.Thread.spawn(.{}, Service.workerMain, .{service});
    for (slots, 0..) |slot, i| {
        const completion = try testPoll(service);
        defer completion.deinit();
        try t.expect(completion == .fallback_failed);
        const failed = completion.fallback_failed;
        try t.expectEqual(snapshot, failed.base);
        try t.expectEqual(slot, failed.slot);
        try t.expectEqual(@as(usize, 1), failed.candidate_index);
        try t.expectEqual(bad_ids[i], completion.requestId());
        try t.expectEqual(error.FontFileUnavailable, failed.failure.err);
        try t.expect(service.rejectFallback(failed.base, failed.slot, failed.candidate_index, failed.failure));
        try t.expect(!service.rejectFallback(failed.base, failed.slot, failed.candidate_index, failed.failure));
        try t.expectError(error.RejectedCandidate, service.requestFallback(snapshot, slot, 1));
        try t.expect(!snapshot.slots[@backingInt(slot)].candidates[2].fallback_rejected.load(.acquire));
    }
    try t.expectEqual(id, service.status().active_generation);
    for (slots) |slot| _ = try service.requestFallback(snapshot, slot, 2);
    var publications: usize = 0;
    const Publish = struct {
        fn run(value: *usize) void {
            value.* += 1;
        }
    };
    for (slots) |slot| {
        const completion = try testPoll(service);
        defer completion.deinit();
        try t.expect(completion == .fallback);
        try t.expectEqual(slot, completion.fallback.slot);
        try t.expectEqual(@as(usize, 2), completion.fallback.candidate_index);
        try service.commitFallback(completion.fallback, &publications, Publish.run);
    }
    try t.expectEqual(@as(usize, 2), publications);
    try t.expect(service.poll() == null);
}

test "late worker and staging failures cannot reject replacement snapshot candidates" {
    const t = std.testing;
    const service = try testService();
    defer service.destroy();
    const old_id = try service.request(.{});
    const old = try testSnapshot(&service.store, old_id);
    defer old.release();
    try service.acknowledgeApplied(old);
    const failed = Failure.init(old_id + 1, .fallback, error.FontError);
    try t.expect(service.rejectFallback(old, .body_normal, 1, failed));
    const retained: Completion = .{ .fallback_failed = .{ .base = old.retain(), .slot = .body_normal, .candidate_index = 1, .failure = failed } };
    defer retained.deinit();
    const fresh_id = try service.refresh();
    const fresh = try testSnapshot(&service.store, fresh_id);
    defer fresh.release();
    // A selection in progress must keep the old candidate set untouched too.
    try t.expect(!service.rejectFallback(old, .body_normal, 2, failed));
    try service.acknowledgeApplied(fresh);
    try t.expect(!service.rejectFallback(old, .body_normal, 1, failed));
    try t.expect(old.slots[0].candidates[1].fallback_rejected.load(.acquire));
    try t.expect(!fresh.slots[0].candidates[1].fallback_rejected.load(.acquire));
    _ = try service.requestFallback(fresh, .body_normal, 1);
    try t.expectEqual(fresh_id, service.status().active_generation);
}
