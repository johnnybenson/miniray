//! JSON configuration loading for miniray.
//!
//! Supports wgslmin.json / .wgslminrc config files.
//! Walks up directory tree to find config.

const std = @import("std");
const Minifier = @import("Minifier.zig");

const Config = @This();

minify_whitespace: ?bool = null,
minify_identifiers: ?bool = null,
minify_syntax: ?bool = null,
mangle_external_bindings: ?bool = null,
tree_shaking: ?bool = null,
preserve_uniform_struct_types: ?bool = null,
keep_names: []const []const u8 = &.{},
source_map: ?bool = null,
source_map_sources: ?bool = null,

pub const config_file_names = [_][]const u8{
    "wgslmin.json",
    ".wgslminrc",
    ".wgslminrc.json",
};

/// Load config from a JSON file.
pub fn loadFile(allocator: std.mem.Allocator, path: []const u8) !Config {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const content = try file.readToEndAlloc(allocator, 1024 * 1024);

    return parseJson(allocator, content);
}

pub fn parseJson(allocator: std.mem.Allocator, content: []const u8) !Config {
    var config = Config{};

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
    const root = parsed.value;

    if (root != .object) return config;

    if (root.object.get("minifyWhitespace")) |v| {
        if (v == .bool) config.minify_whitespace = v.bool;
    }
    if (root.object.get("minifyIdentifiers")) |v| {
        if (v == .bool) config.minify_identifiers = v.bool;
    }
    if (root.object.get("minifySyntax")) |v| {
        if (v == .bool) config.minify_syntax = v.bool;
    }
    if (root.object.get("mangleExternalBindings")) |v| {
        if (v == .bool) config.mangle_external_bindings = v.bool;
    }
    if (root.object.get("treeShaking")) |v| {
        if (v == .bool) config.tree_shaking = v.bool;
    }
    if (root.object.get("preserveUniformStructTypes")) |v| {
        if (v == .bool) config.preserve_uniform_struct_types = v.bool;
    }
    if (root.object.get("keepNames")) |v| {
        if (v == .array) {
            var names: std.ArrayListUnmanaged([]const u8) = .empty;
            for (v.array.items) |item| {
                if (item == .string) {
                    try names.append(allocator, item.string);
                }
            }
            config.keep_names = names.items;
        }
    }
    if (root.object.get("sourceMap")) |v| {
        if (v == .bool) config.source_map = v.bool;
    }
    if (root.object.get("sourceMapSources")) |v| {
        if (v == .bool) config.source_map_sources = v.bool;
    }

    return config;
}

/// Convert config to minifier options, using defaults for unset fields.
pub fn toOptions(self: Config) Minifier.Options {
    var opts = Minifier.defaultOptions();
    if (self.minify_whitespace) |v| opts.minify_whitespace = v;
    if (self.minify_identifiers) |v| opts.minify_identifiers = v;
    if (self.minify_syntax) |v| opts.minify_syntax = v;
    if (self.mangle_external_bindings) |v| opts.mangle_external_bindings = v;
    if (self.tree_shaking) |v| opts.tree_shaking = v;
    if (self.preserve_uniform_struct_types) |v| opts.preserve_uniform_struct_types = v;
    if (self.keep_names.len > 0) opts.keep_names = self.keep_names;
    return opts;
}
