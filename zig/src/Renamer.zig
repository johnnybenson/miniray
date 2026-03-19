//! Symbol renaming for minification.
//!
//! Assigns short names to frequently-used symbols, avoiding reserved words
//! and API-facing names. Follows esbuild's frequency-based approach.

const std = @import("std");
const Ast = @import("Ast.zig");
const Lexer = @import("Lexer.zig");
const Printer = @import("Printer.zig");

const Renamer = @This();

// =========================================================================
// NoOp Renamer
// =========================================================================

pub const NoOpRenamer = struct {
    symbols: []const Ast.Symbol,
    renamer: Printer.Renamer,

    pub fn init(symbols: []const Ast.Symbol) NoOpRenamer {
        var self = NoOpRenamer{
            .symbols = symbols,
            .renamer = undefined,
        };
        self.renamer = .{
            .ptr = @ptrCast(&self),
            .nameForSymbolFn = &nameForSymbolImpl,
        };
        return self;
    }

    fn nameForSymbolImpl(ptr: *const anyopaque, ref: Ast.SymbolIndex) []const u8 {
        const self: *const NoOpRenamer = @ptrCast(@alignCast(ptr));
        if (!ref.isValid()) return "";
        const idx = ref.index();
        if (idx >= self.symbols.len) return "";
        return self.symbols[idx].original_name;
    }
};

// =========================================================================
// Minify Renamer
// =========================================================================

pub const MinifyRenamer = struct {
    symbols: []Ast.Symbol,
    reserved_names: std.StringHashMapUnmanaged(void),
    slots: std.ArrayListUnmanaged(SymbolSlot),
    top_level_slots: std.AutoHashMapUnmanaged(u32, u32),
    name_buf: std.ArrayListUnmanaged(u8), // storage for generated names
    name_offsets: std.ArrayListUnmanaged(NameSlice), // offset+len into name_buf
    allocator: std.mem.Allocator,
    renamer: Printer.Renamer,

    const SymbolSlot = struct {
        name: []const u8,
        count: u32,
    };

    const NameSlice = struct {
        offset: u32,
        len: u32,
    };

    pub fn init(allocator: std.mem.Allocator, symbols: []Ast.Symbol, reserved: std.StringHashMapUnmanaged(void)) MinifyRenamer {
        var self = MinifyRenamer{
            .symbols = symbols,
            .reserved_names = reserved,
            .slots = .empty,
            .top_level_slots = .empty,
            .name_buf = .empty,
            .name_offsets = .empty,
            .allocator = allocator,
            .renamer = undefined,
        };
        self.renamer = .{
            .ptr = @ptrCast(&self),
            .nameForSymbolFn = &nameForSymbolImpl,
        };
        return self;
    }

    pub fn accumulateSymbolUseCounts(self: *MinifyRenamer, uses: *const std.AutoHashMapUnmanaged(Ast.SymbolIndex, u32)) void {
        var it = uses.iterator();
        while (it.next()) |entry| {
            const ref = entry.key_ptr.*;
            if (!ref.isValid()) continue;
            const idx = ref.index();
            if (idx >= self.symbols.len) continue;
            const sym = &self.symbols[idx];
            if (sym.flags.must_not_be_renamed) continue;
            sym.use_count += entry.value_ptr.*;
        }
    }

    pub fn allocateSlots(self: *MinifyRenamer) void {
        const SymWithCount = struct { idx: u32, count: u32 };
        var renameable: std.ArrayListUnmanaged(SymWithCount) = .empty;
        defer renameable.deinit(self.allocator);

        for (self.symbols, 0..) |*sym, i| {
            if (sym.flags.must_not_be_renamed) continue;
            if (sym.use_count > 0) {
                renameable.append(self.allocator, .{
                    .idx = @intCast(i),
                    .count = sym.use_count,
                }) catch {};
            }
        }

        // Sort by count descending, then by index ascending for stability
        std.mem.sort(SymWithCount, renameable.items, {}, struct {
            fn lessThan(_: void, a: SymWithCount, b: SymWithCount) bool {
                if (a.count != b.count) return a.count > b.count;
                return a.idx < b.idx;
            }
        }.lessThan);

        self.slots.ensureTotalCapacity(self.allocator, renameable.items.len) catch {};
        for (renameable.items, 0..) |item, i| {
            self.top_level_slots.put(self.allocator, item.idx, @intCast(i)) catch {};
            self.slots.append(self.allocator, .{ .name = "", .count = item.count }) catch {};
        }
    }

    pub fn reserveUnrenamedSymbolNames(self: *MinifyRenamer) void {
        for (self.symbols, 0..) |*sym, i| {
            if (!self.top_level_slots.contains(@intCast(i))) {
                self.reserved_names.put(self.allocator, sym.original_name, {}) catch {};
            }
        }
    }

    pub fn assignNames(self: *MinifyRenamer) void {
        var name_index: u32 = 0;
        var buf: [16]u8 = undefined;

        // First pass: compute total name storage needed
        var total_len: usize = 0;
        var indices: std.ArrayListUnmanaged(u32) = .empty;
        defer indices.deinit(self.allocator);
        for (self.slots.items) |_| {
            var name = numberToMinifiedName(&buf, name_index);
            while (self.reserved_names.contains(name)) {
                name_index += 1;
                name = numberToMinifiedName(&buf, name_index);
            }
            indices.append(self.allocator, name_index) catch {};
            total_len += name.len;
            name_index += 1;
        }

        // Pre-allocate name buffer to avoid reallocation
        self.name_buf.ensureTotalCapacity(self.allocator, total_len) catch {};

        // Second pass: store names (no reallocation will occur)
        for (self.slots.items, 0..) |*slot, i| {
            const idx = indices.items[i];
            const name = numberToMinifiedName(&buf, idx);
            const offset: u32 = @intCast(self.name_buf.items.len);
            self.name_buf.appendSlice(self.allocator, name) catch {};
            self.name_offsets.append(self.allocator, .{ .offset = offset, .len = @intCast(name.len) }) catch {};
            slot.name = self.name_buf.items[offset .. offset + name.len];
        }
    }

    fn nameForSymbolImpl(ptr: *const anyopaque, ref: Ast.SymbolIndex) []const u8 {
        const self: *const MinifyRenamer = @ptrCast(@alignCast(ptr));
        if (!ref.isValid()) return "";
        const idx = ref.index();
        if (idx >= self.symbols.len) return "";
        const sym = &self.symbols[idx];
        if (sym.flags.must_not_be_renamed) return sym.original_name;
        if (self.top_level_slots.get(idx)) |slot_idx| {
            return self.slots.items[slot_idx].name;
        }
        return sym.original_name;
    }
};

// =========================================================================
// Name generation
// =========================================================================

const head = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ";
const tail = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";

/// Convert a number to a minified identifier name.
/// Sequence: a, b, ..., z, A, ..., Z, aa, ba, ca, ...
pub fn numberToMinifiedName(buf: []u8, n_in: u32) []const u8 {
    var n = n_in;
    const n_head: u32 = head.len;
    const n_tail: u32 = tail.len;

    var len: u32 = 0;
    buf[len] = head[n % n_head];
    len += 1;
    n = n / n_head;

    while (n > 0) {
        n -= 1;
        buf[len] = tail[n % n_tail];
        len += 1;
        n = n / n_tail;
    }

    return buf[0..len];
}

// =========================================================================
// Reserved names
// =========================================================================

pub fn computeReservedNames(allocator: std.mem.Allocator) std.StringHashMapUnmanaged(void) {
    var reserved = std.StringHashMapUnmanaged(void){};

    // Keywords
    const keywords = [_][]const u8{
        "alias", "break", "case", "const", "const_assert", "continue",
        "continuing", "default", "diagnostic", "discard", "else", "enable",
        "false", "fn", "for", "if", "let", "loop", "override", "requires",
        "return", "struct", "switch", "true", "var", "while",
    };
    for (keywords) |kw| reserved.put(allocator, kw, {}) catch {};

    // Reserved words
    const reserved_words = [_][]const u8{
        "NULL",  "Self",   "abstract",     "active",    "alignas",         "alignof",
        "as",    "asm",    "asm_fragment",  "async",     "attribute",       "auto",
        "await", "become", "cast",          "catch",     "class",           "co_await",
        "co_return", "co_yield", "coherent", "column_major", "common",     "compile",
        "compile_fragment", "concept", "const_cast", "consteval", "constexpr", "constinit",
        "crate", "debugger", "decltype", "delete", "demote", "demote_to_helper",
        "do", "dynamic_cast", "enum", "explicit", "export", "extends",
        "extern", "external", "fallthrough", "filter", "final", "finally",
        "friend", "from", "fxgroup", "get", "goto", "groupshared",
        "highp", "impl", "implements", "import", "inline", "instanceof",
        "interface", "layout", "lowp", "macro", "macro_rules", "match",
        "mediump", "meta", "mod", "module", "move", "mut",
        "mutable", "namespace", "new", "nil", "noexcept", "noinline",
        "nointerpolation", "non_coherent", "noncoherent", "noperspective",
        "null", "nullptr", "of", "operator", "package", "packoffset",
        "partition", "pass", "patch", "pixelfragment", "precise", "precision",
        "premerge", "priv", "protected", "pub", "public", "readonly",
        "ref", "regardless", "register", "reinterpret_cast", "require",
        "resource", "restrict", "self", "set", "shared", "sizeof",
        "smooth", "snorm", "static", "static_assert", "static_cast", "std",
        "subroutine", "super", "target", "template", "this", "thread_local",
        "throw", "trait", "try", "type", "typedef", "typeid",
        "typename", "typeof", "union", "unless", "unorm", "unsafe",
        "unsized", "use", "using", "varying", "virtual", "volatile",
        "wgsl", "where", "with", "writeonly", "yield",
    };
    for (reserved_words) |w| reserved.put(allocator, w, {}) catch {};

    // Single underscore
    reserved.put(allocator, "_", {}) catch {};

    // Builtin types
    const builtin_types = [_][]const u8{
        "bool", "i32", "u32", "f32", "f16",
        "vec2", "vec3", "vec4",
        "vec2i", "vec3i", "vec4i", "vec2u", "vec3u", "vec4u",
        "vec2f", "vec3f", "vec4f", "vec2h", "vec3h", "vec4h",
        "mat2x2", "mat2x3", "mat2x4", "mat3x2", "mat3x3", "mat3x4",
        "mat4x2", "mat4x3", "mat4x4",
        "mat2x2f", "mat2x3f", "mat2x4f", "mat3x2f", "mat3x3f", "mat3x4f",
        "mat4x2f", "mat4x3f", "mat4x4f",
        "mat2x2h", "mat2x3h", "mat2x4h", "mat3x2h", "mat3x3h", "mat3x4h",
        "mat4x2h", "mat4x3h", "mat4x4h",
        "array", "ptr", "atomic",
        "sampler", "sampler_comparison",
        "texture_1d", "texture_2d", "texture_2d_array",
        "texture_3d", "texture_cube", "texture_cube_array",
        "texture_multisampled_2d",
        "texture_storage_1d", "texture_storage_2d", "texture_storage_2d_array", "texture_storage_3d",
        "texture_depth_2d", "texture_depth_2d_array", "texture_depth_cube", "texture_depth_cube_array",
        "texture_depth_multisampled_2d", "texture_external",
    };
    for (builtin_types) |t| reserved.put(allocator, t, {}) catch {};

    // Address spaces
    for ([_][]const u8{ "function", "private", "workgroup", "uniform", "storage" }) |s| {
        reserved.put(allocator, s, {}) catch {};
    }

    // Access modes
    for ([_][]const u8{ "read", "write", "read_write" }) |m| {
        reserved.put(allocator, m, {}) catch {};
    }

    // Texel formats
    const texel_formats = [_][]const u8{
        "rgba8unorm", "rgba8snorm", "rgba8uint", "rgba8sint",
        "rgba16uint", "rgba16sint", "rgba16float",
        "r32uint", "r32sint", "r32float",
        "rg32uint", "rg32sint", "rg32float",
        "rgba32uint", "rgba32sint", "rgba32float",
        "bgra8unorm",
    };
    for (texel_formats) |f| reserved.put(allocator, f, {}) catch {};

    return reserved;
}

// =========================================================================
// Tests
// =========================================================================

test "numberToMinifiedName sequence" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("a", numberToMinifiedName(&buf, 0));
    try std.testing.expectEqualStrings("b", numberToMinifiedName(&buf, 1));
    try std.testing.expectEqualStrings("z", numberToMinifiedName(&buf, 25));
    try std.testing.expectEqualStrings("A", numberToMinifiedName(&buf, 26));
    try std.testing.expectEqualStrings("Z", numberToMinifiedName(&buf, 51));
    try std.testing.expectEqualStrings("aa", numberToMinifiedName(&buf, 52));
    try std.testing.expectEqualStrings("ba", numberToMinifiedName(&buf, 53));
}
