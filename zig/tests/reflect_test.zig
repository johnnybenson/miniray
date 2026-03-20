//! Reflect tests — ported from Go's internal/minifier_tests/minify_reflect_test.go.
//! Tests the combined minification and reflection functionality.

const std = @import("std");
const miniray = @import("miniray");

// =========================================================================
// TestMinifyAndReflect
// =========================================================================

test "MinifyAndReflect" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source: [:0]const u8 =
        \\struct Uniforms {
        \\    time: f32,
        \\    resolution: vec2f,
        \\}
        \\
        \\@group(0) @binding(0) var<uniform> uniforms: Uniforms;
        \\@group(0) @binding(1) var texSampler: sampler;
        \\@group(0) @binding(2) var texture: texture_2d<f32>;
        \\
        \\@fragment
        \\fn main(@location(0) uv: vec2f) -> @location(0) vec4f {
        \\    let t = uniforms.time;
        \\    return textureSample(texture, texSampler, uv);
        \\}
    ;

    // Minify
    const result = try miniray.minifyWithOptions(allocator, source, .{
        .minify_whitespace = true,
        .minify_identifiers = true,
        .minify_syntax = false,
        .tree_shaking = false,
    });

    // Check that minification worked
    try std.testing.expectEqual(@as(usize, 0), result.errors.len);
    try std.testing.expect(result.code.len > 0);
    try std.testing.expect(result.minified_size < result.original_size);

    // Reflect on the original source
    const reflect_result = try miniray.reflect(allocator, source);

    // Check that reflection worked
    try std.testing.expect(reflect_result.bindings.items.len > 0);
    try std.testing.expect(reflect_result.entry_points.items.len > 0);

    // Check for the uniforms binding
    var found_uniforms = false;
    for (reflect_result.bindings.items) |b| {
        if (std.mem.eql(u8, b.name, "uniforms")) {
            found_uniforms = true;
            try std.testing.expectEqual(@as(i32, 0), b.group);
            try std.testing.expectEqual(@as(i32, 0), b.binding);
        }
    }
    try std.testing.expect(found_uniforms);

    // Check for entry point
    var found_main = false;
    for (reflect_result.entry_points.items) |ep| {
        if (std.mem.eql(u8, ep.name, "main")) {
            found_main = true;
            try std.testing.expectEqualStrings("fragment", ep.stage);
        }
    }
    try std.testing.expect(found_main);
}

// =========================================================================
// TestMinifyAndReflectCombined — uses minifyAndReflect for shared renamer
// =========================================================================

test "MinifyAndReflectCombined" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source: [:0]const u8 =
        \\struct Uniforms {
        \\    time: f32,
        \\    resolution: vec2f,
        \\}
        \\
        \\@group(0) @binding(0) var<uniform> uniforms: Uniforms;
        \\@group(0) @binding(1) var texSampler: sampler;
        \\
        \\@fragment
        \\fn main(@location(0) uv: vec2f) -> @location(0) vec4f {
        \\    let t = uniforms.time;
        \\    return vec4f(t, 0.0, 0.0, 1.0);
        \\}
    ;

    const result = try miniray.minifyAndReflect(allocator, source, .{
        .minify_whitespace = true,
        .minify_identifiers = true,
        .minify_syntax = false,
        .tree_shaking = false,
    });

    // Minification should succeed
    try std.testing.expectEqual(@as(usize, 0), result.minify.errors.len);
    try std.testing.expect(result.minify.code.len > 0);
    try std.testing.expect(result.minify.minified_size < result.minify.original_size);

    // Reflection should have bindings with mapped names
    try std.testing.expect(result.reflect.bindings.items.len >= 2);
    try std.testing.expect(result.reflect.entry_points.items.len > 0);

    // The uniforms binding should have original name "uniforms" but a mapped name
    // that differs (since identifiers are minified). The mapped name should appear
    // in the minified code.
    for (result.reflect.bindings.items) |b| {
        if (b.group == 0 and b.binding == 0) {
            try std.testing.expectEqualStrings("uniforms", b.name);
            // name_mapped should appear in the minified output
            try std.testing.expect(std.mem.indexOf(u8, result.minify.code, b.name_mapped) != null);
        }
    }

    // Entry point "main" keeps its name (entry points are not renamed)
    var found_main = false;
    for (result.reflect.entry_points.items) |ep| {
        if (std.mem.eql(u8, ep.name, "main")) {
            found_main = true;
        }
    }
    try std.testing.expect(found_main);
}

// =========================================================================
// TestMinifyAndReflectCombinedParseError
// =========================================================================

test "MinifyAndReflectCombinedParseError" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source: [:0]const u8 = "fn invalid( { }";

    const result = try miniray.minifyAndReflect(allocator, source, miniray.Minifier.defaultOptions());
    try std.testing.expect(result.minify.errors.len > 0);
    try std.testing.expect(result.reflect.errors.items.len > 0);
}

// =========================================================================
// TestMinifyAndReflectParseError
// =========================================================================

test "MinifyAndReflectParseError" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source: [:0]const u8 = "fn invalid( { }";

    // Minify should return errors
    const result = try miniray.minifyWithOptions(allocator, source, miniray.Minifier.defaultOptions());
    try std.testing.expect(result.errors.len > 0);
}

// =========================================================================
// TestMinifyAndReflectWithTreeShaking
// =========================================================================

test "MinifyAndReflectWithTreeShaking" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source: [:0]const u8 =
        \\fn unused() -> i32 {
        \\    return 42;
        \\}
        \\
        \\@compute @workgroup_size(1)
        \\fn main() {
        \\}
    ;

    // Minify with tree shaking
    const result = try miniray.minifyWithOptions(allocator, source, .{
        .minify_whitespace = true,
        .minify_identifiers = true,
        .minify_syntax = false,
        .tree_shaking = true,
    });

    try std.testing.expectEqual(@as(usize, 0), result.errors.len);

    // unused function should be eliminated
    try std.testing.expect(result.symbols_dead > 0);

    // Reflect original, find entry point "main"
    const reflect_result = try miniray.reflect(allocator, source);

    var found_main = false;
    for (reflect_result.entry_points.items) |ep| {
        if (std.mem.eql(u8, ep.name, "main")) {
            found_main = true;
        }
    }
    try std.testing.expect(found_main);
}

// =========================================================================
// TestMinifyAndReflectStructLayout
// =========================================================================

test "MinifyAndReflectStructLayout" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source: [:0]const u8 =
        \\struct MyStruct {
        \\    a: f32,
        \\    b: vec3f,
        \\    c: mat4x4f,
        \\}
        \\
        \\@group(0) @binding(0) var<uniform> data: MyStruct;
        \\
        \\@compute @workgroup_size(1)
        \\fn main() {
        \\    let x = data.a;
        \\}
    ;

    // Minify
    const result = try miniray.minifyWithOptions(allocator, source, .{
        .minify_whitespace = true,
        .minify_identifiers = true,
        .minify_syntax = false,
        .tree_shaking = false,
    });

    try std.testing.expectEqual(@as(usize, 0), result.errors.len);

    // Reflect original
    const reflect_result = try miniray.reflect(allocator, source);

    // Check struct layout is included
    try std.testing.expect(reflect_result.structs.count() > 0);

    // Find a struct with 3 fields
    var found_struct = false;
    var iter = reflect_result.structs.iterator();
    while (iter.next()) |entry| {
        if (entry.value_ptr.fields.items.len == 3) {
            found_struct = true;
            // Check first field name is "a"
            try std.testing.expectEqualStrings("a", entry.value_ptr.fields.items[0].name);
        }
    }
    try std.testing.expect(found_struct);
}

// =========================================================================
// TestConvenienceMinifyFunction
// =========================================================================

test "ConvenienceMinifyFunction" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source: [:0]const u8 = "fn foo() { let x = 1; }";

    // Test with default options (miniray.minify)
    const result = try miniray.minify(allocator, source);
    try std.testing.expectEqual(@as(usize, 0), result.errors.len);
    try std.testing.expect(result.code.len > 0);

    // Test with custom options (minify_whitespace only)
    const result2 = try miniray.minifyWithOptions(allocator, source, .{
        .minify_whitespace = true,
        .minify_identifiers = false,
        .minify_syntax = false,
        .tree_shaking = false,
    });
    try std.testing.expectEqual(@as(usize, 0), result2.errors.len);
}
