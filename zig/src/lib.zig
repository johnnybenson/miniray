//! C-ABI static library entry point for miniray.
//!
//! Exports miniray_minify_c for embedding in C/C++/Rust/etc.

const std = @import("std");
const Minifier = @import("Minifier.zig");

const OPT_MINIFY_WHITESPACE: u32 = 1 << 0;
const OPT_MINIFY_IDENTIFIERS: u32 = 1 << 1;
const OPT_MINIFY_SYNTAX: u32 = 1 << 2;
const OPT_TREE_SHAKING: u32 = 1 << 3;
const OPT_MANGLE_EXTERNAL: u32 = 1 << 4;
const OPT_PRESERVE_UNIFORM_STRUCTS: u32 = 1 << 5;

/// Result from minification. Caller must call miniray_free_result.
pub const MinirayResult = extern struct {
    code_ptr: ?[*]const u8,
    code_len: u32,
    error: bool,
};

/// Minify WGSL source. Returns a MinirayResult.
/// The result's code_ptr must be freed with miniray_free.
export fn miniray_minify_c(
    source_ptr: [*]const u8,
    source_len: u32,
    flags: u32,
) MinirayResult {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const allocator = arena.allocator();

    // Build sentinel-terminated source
    const source_buf = allocator.alloc(u8, source_len + 1) catch return .{ .code_ptr = null, .code_len = 0, .error = true };
    @memcpy(source_buf[0..source_len], source_ptr[0..source_len]);
    source_buf[source_len] = 0;
    const source: [:0]const u8 = source_buf[0..source_len :0];

    const options = Minifier.Options{
        .minify_whitespace = flags & OPT_MINIFY_WHITESPACE != 0,
        .minify_identifiers = flags & OPT_MINIFY_IDENTIFIERS != 0,
        .minify_syntax = flags & OPT_MINIFY_SYNTAX != 0,
        .tree_shaking = flags & OPT_TREE_SHAKING != 0,
        .mangle_external_bindings = flags & OPT_MANGLE_EXTERNAL != 0,
        .preserve_uniform_struct_types = flags & OPT_PRESERVE_UNIFORM_STRUCTS != 0,
    };

    const result = Minifier.minify(allocator, source, options) catch return .{ .code_ptr = null, .code_len = 0, .error = true };

    // Copy result to page_allocator so arena can't free it
    const out = std.heap.page_allocator.alloc(u8, result.code.len) catch return .{ .code_ptr = null, .code_len = 0, .error = true };
    @memcpy(out, result.code);

    arena.deinit();

    return .{
        .code_ptr = out.ptr,
        .code_len = @intCast(out.len),
        .error = false,
    };
}

/// Free memory returned by miniray_minify_c.
export fn miniray_free_c(ptr: [*]u8, len: u32) void {
    std.heap.page_allocator.free(ptr[0..len]);
}

/// Return the version string and length.
export fn miniray_version_c(len: *u32) [*]const u8 {
    const v = "0.1.0";
    len.* = v.len;
    return v.ptr;
}
