# system-fonts

Linux system-font discovery, immutable snapshots, fallback preparation and versioned application preferences for Zig 0.17. No GUI dependency.

Add dependency `system_fonts` with path `../system-fonts`, then import `dependency.module("system_fonts")`. The root exports the font_system API (Service, Snapshot, Preferences, Selection, Role, Style, Slot, Options, prepare and supporting types), plus `fc` (Fontconfig bindings) and `preferences`.

`preferences.configPath(allocator, environment, application)` returns an owned optional path to `$XDG_CONFIG_HOME/<application>/fonts.json` or `$HOME/.config/<application>/fonts.json`. The application must be a nonempty single directory name; callers can instead pass an explicit path to load/save. Free returned paths with the allocator. Snapshots and blobs retain explicit retain/release ownership.

Build options: standard target and optimize. Requires libc and system Fontconfig through pkg-config; no Zig package dependencies.

Run `zig build test -j1`. In the sibling development checkout, run `nix develop /home/HumXC/nalume/zushell -c zig build test -j1` from this directory.
