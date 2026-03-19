//! Regression / bug-fix tests ported from Go internal/minifier_tests/minifier_test.go.
//! These test behavioural invariants (contains / not-contains checks) rather than
//! exact snapshot output.

const std = @import("std");
const miniray = @import("miniray");

// =========================================================================
// Helpers
// =========================================================================

fn minifyFull(allocator: std.mem.Allocator, input: [:0]const u8) !miniray.Minifier.Result {
    return miniray.minifyWithOptions(allocator, input, .{
        .minify_whitespace = true,
        .minify_identifiers = true,
        .minify_syntax = true,
        .tree_shaking = false,
    });
}

fn minifyFullWithTreeShaking(allocator: std.mem.Allocator, input: [:0]const u8) !miniray.Minifier.Result {
    return miniray.minifyWithOptions(allocator, input, .{
        .minify_whitespace = true,
        .minify_identifiers = true,
        .minify_syntax = true,
        .tree_shaking = true,
    });
}

fn minifyMangleExt(allocator: std.mem.Allocator, input: [:0]const u8) !miniray.Minifier.Result {
    return miniray.minifyWithOptions(allocator, input, .{
        .minify_whitespace = true,
        .minify_identifiers = true,
        .minify_syntax = true,
        .mangle_external_bindings = true,
        .tree_shaking = false,
    });
}

/// Check for pattern: "const " followed by single lowercase letter, "=", then letter.
/// Equivalent to Go regexp `const [a-z]=[a-zA-Z]`.
fn hasConstAliasPattern(code: []const u8) bool {
    var i: usize = 0;
    while (i + 8 <= code.len) : (i += 1) {
        if (std.mem.startsWith(u8, code[i..], "const ")) {
            const after = i + 6;
            if (after + 2 <= code.len) {
                const ch = code[after];
                if (ch >= 'a' and ch <= 'z' and code[after + 1] == '=') {
                    if (after + 2 < code.len) {
                        const next = code[after + 2];
                        if ((next >= 'a' and next <= 'z') or (next >= 'A' and next <= 'Z')) {
                            return true;
                        }
                    }
                }
            }
        }
    }
    return false;
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

fn count(haystack: []const u8, needle: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) {
        if (std.mem.eql(u8, haystack[i..][0..needle.len], needle)) {
            n += 1;
            i += needle.len;
        } else {
            i += 1;
        }
    }
    return n;
}

// =========================================================================
// 1. TestExternalBindingsKeepOriginalNames
// =========================================================================

test "TestExternalBindingsKeepOriginalNames" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try minifyFullWithTreeShaking(alloc,
        \\@group(0) @binding(0) var<uniform> myUniform: f32;
        \\
        \\fn getValue() -> f32 {
        \\    return myUniform * 2.0;
        \\}
    );

    // Verify the original binding name is preserved
    try std.testing.expect(contains(result.code, "myUniform"));

    // Should not have any aliases at module scope
    try std.testing.expect(!contains(result.code, "const a="));
    try std.testing.expect(!contains(result.code, "let a="));
}

// =========================================================================
// 2. TestNoLetAtModuleScopeWithBindings
// =========================================================================

test "TestNoLetAtModuleScopeWithBindings_SingleBinding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try minifyFullWithTreeShaking(alloc,
        \\@group(0) @binding(0) var<uniform> u: f32;
        \\fn f() -> f32 { return u + u + u; }
    );

    const fn_index = std.mem.indexOf(u8, result.code, "fn ") orelse result.code.len;
    const module_scope = result.code[0..fn_index];
    try std.testing.expect(!contains(module_scope, "let "));
}

test "TestNoLetAtModuleScopeWithBindings_MultipleBindings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try minifyFullWithTreeShaking(alloc,
        \\@group(0) @binding(0) var<uniform> a: f32;
        \\@group(0) @binding(1) var<uniform> b: f32;
        \\fn f() -> f32 { return a + b; }
    );

    const fn_index = std.mem.indexOf(u8, result.code, "fn ") orelse result.code.len;
    const module_scope = result.code[0..fn_index];
    try std.testing.expect(!contains(module_scope, "let "));
}

test "TestNoLetAtModuleScopeWithBindings_StructBinding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try minifyFullWithTreeShaking(alloc,
        \\struct Params { x: f32, y: f32 }
        \\@group(0) @binding(0) var<uniform> params: Params;
        \\fn f() -> f32 { return params.x + params.y; }
    );

    const fn_index = std.mem.indexOf(u8, result.code, "fn ") orelse result.code.len;
    const module_scope = result.code[0..fn_index];
    try std.testing.expect(!contains(module_scope, "let "));
}

test "TestNoLetAtModuleScopeWithBindings_StorageBinding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try minifyFullWithTreeShaking(alloc,
        \\@group(0) @binding(0) var<storage> data: array<f32>;
        \\fn f(i: u32) -> f32 { return data[i]; }
    );

    const fn_index = std.mem.indexOf(u8, result.code, "fn ") orelse result.code.len;
    const module_scope = result.code[0..fn_index];
    try std.testing.expect(!contains(module_scope, "let "));
}

// =========================================================================
// 3. TestNoLetAtModuleScope
// =========================================================================

test "TestNoLetAtModuleScope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try minifyFullWithTreeShaking(alloc,
        \\struct PngineInputs {
        \\    time: f32,
        \\    canvasW: f32,
        \\    canvasH: f32,
        \\}
        \\
        \\@group(0) @binding(0) var<uniform> pngine: PngineInputs;
        \\
        \\@fragment
        \\fn main() -> @location(0) vec4f {
        \\    let t = pngine.time;
        \\    return vec4f(t, 0.0, 0.0, 1.0);
        \\}
    );

    const fn_index = std.mem.indexOf(u8, result.code, "fn ") orelse result.code.len;
    const module_scope = result.code[0..fn_index];

    // Check for 'let' in module scope (which is invalid WGSL)
    try std.testing.expect(!contains(module_scope, "let "));

    // Verify external binding name is preserved
    try std.testing.expect(contains(result.code, "pngine"));
}

// =========================================================================
// 4. TestTemplatedConstructorTypeRenaming
// =========================================================================

test "TestTemplatedConstructorTypeRenaming" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try minifyMangleExt(alloc,
        \\struct Transform2D {
        \\    pos: vec2f,
        \\    scale: vec2f,
        \\}
        \\
        \\fn makeTransforms() -> array<Transform2D, 3> {
        \\    return array<Transform2D, 3>(
        \\        Transform2D(vec2f(0.0), vec2f(1.0)),
        \\        Transform2D(vec2f(1.0), vec2f(1.0)),
        \\        Transform2D(vec2f(2.0), vec2f(1.0)),
        \\    );
        \\}
    );

    // The struct 'Transform2D' should be renamed to a shorter name
    try std.testing.expect(!contains(result.code, "Transform2D"));

    // The output should still contain 'array<' since that's a built-in type
    try std.testing.expect(contains(result.code, "array<"));

    // Verify the minified name appears in array constructor
    try std.testing.expect(contains(result.code, "array<a"));
}

// =========================================================================
// 5. TestNestedTemplatedTypeRenaming
// =========================================================================

test "TestNestedTemplatedTypeRenaming" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try minifyMangleExt(alloc,
        \\struct Point {
        \\    x: f32,
        \\    y: f32,
        \\}
        \\
        \\fn makeNestedArray() {
        \\    var arr: array<array<Point, 2>, 3>;
        \\    arr = array<array<Point, 2>, 3>();
        \\}
    );

    // 'Point' should be renamed
    try std.testing.expect(!contains(result.code, "Point"));
}

// =========================================================================
// 6. TestArraySizeConstantRenaming
// =========================================================================

test "TestArraySizeConstantRenaming" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try minifyMangleExt(alloc,
        \\const TRANSFORM_COUNT = 9u;
        \\
        \\struct Transform2D {
        \\    pos: vec2f,
        \\}
        \\
        \\fn makeTransforms() {
        \\    let transforms = array<Transform2D, TRANSFORM_COUNT>();
        \\}
    );

    // Both 'Transform2D' and 'TRANSFORM_COUNT' should be renamed
    try std.testing.expect(!contains(result.code, "Transform2D"));
    try std.testing.expect(!contains(result.code, "TRANSFORM_COUNT"));
}

// =========================================================================
// 7. TestBuiltinTypesInTemplatedConstructors
// =========================================================================

test "TestBuiltinTypesInTemplatedConstructors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try minifyMangleExt(alloc,
        \\fn makeVecs() {
        \\    let v1 = vec3<f32>(1.0, 2.0, 3.0);
        \\    let v2 = array<f32, 4>(1.0, 2.0, 3.0, 4.0);
        \\    let v3 = mat2x2<f32>(1.0, 0.0, 0.0, 1.0);
        \\}
    );

    // Built-in types like f32 should NOT be renamed
    try std.testing.expect(contains(result.code, "vec3<f32>"));
    try std.testing.expect(contains(result.code, "array<f32"));
    try std.testing.expect(contains(result.code, "mat2x2<f32>"));
}

// =========================================================================
// 8. TestLocalShadowsFunction
// =========================================================================

test "TestLocalShadowsFunction" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try miniray.minifyWithOptions(alloc,
        \\fn box(p: vec2f, b: vec2f) -> f32 {
        \\    let q = abs(p) - b;
        \\    return length(max(q, vec2f(0.0))) + min(max(q.x, q.y), 0.0);
        \\}
        \\
        \\fn test() -> f32 {
        \\    let raw = box(vec2f(1.0), vec2f(0.5));
        \\    let box = raw * 2.0;
        \\    return box;
        \\}
    , .{
        .minify_whitespace = true,
        .minify_identifiers = true,
        .tree_shaking = false,
    });

    // Verify no errors
    try std.testing.expectEqual(@as(usize, 0), result.errors.len);

    // Original 'box' identifier should not appear in output
    try std.testing.expect(!contains(result.code, "box"));
}

// =========================================================================
// 9. TestLocalShadowsFunctionComplex
// =========================================================================

test "TestLocalShadowsFunctionComplex" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try miniray.minifyWithOptions(alloc,
        \\fn box(p: vec2f, b: vec2f) -> f32 {
        \\    return length(max(abs(p) - b, vec2f(0.0)));
        \\}
        \\
        \\fn scale_sdf(d: f32, s: f32) -> f32 {
        \\    return d * s;
        \\}
        \\
        \\fn render(p: vec2f) -> f32 {
        \\    let raw = box(p, vec2f(0.5));
        \\    let box = scale_sdf(raw, 2.0);
        \\    return box;
        \\}
    , .{
        .minify_whitespace = true,
        .minify_identifiers = true,
        .tree_shaking = false,
    });

    // Should compile without errors
    try std.testing.expectEqual(@as(usize, 0), result.errors.len);

    // The minified code should not contain original 'box'
    try std.testing.expect(!contains(result.code, "box"));
}

// =========================================================================
// 10. TestElseIfSpacing
// =========================================================================

test "TestElseIfSpacing_SimpleElseIf" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try minifyFull(alloc,
        \\fn test(x: i32) -> i32 {
        \\    if (x > 0) {
        \\        return 1;
        \\    } else if (x < 0) {
        \\        return -1;
        \\    } else {
        \\        return 0;
        \\    }
        \\}
    );

    try std.testing.expect(!contains(result.code, "elseif"));
    try std.testing.expect(contains(result.code, "else if"));
    try std.testing.expectEqual(@as(usize, 0), result.errors.len);
}

test "TestElseIfSpacing_ChainedElseIf" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try minifyFull(alloc,
        \\fn classify(x: i32) -> i32 {
        \\    if (x > 100) {
        \\        return 4;
        \\    } else if (x > 50) {
        \\        return 3;
        \\    } else if (x > 10) {
        \\        return 2;
        \\    } else if (x > 0) {
        \\        return 1;
        \\    } else {
        \\        return 0;
        \\    }
        \\}
    );

    try std.testing.expect(!contains(result.code, "elseif"));
    try std.testing.expect(contains(result.code, "else if"));
    try std.testing.expectEqual(@as(usize, 0), result.errors.len);
}

test "TestElseIfSpacing_NestedElseIf" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try minifyFull(alloc,
        \\fn nested(x: i32, y: i32) -> i32 {
        \\    if (x > 0) {
        \\        if (y > 0) {
        \\            return 1;
        \\        } else if (y < 0) {
        \\            return 2;
        \\        } else {
        \\            return 3;
        \\        }
        \\    } else if (x < 0) {
        \\        return -1;
        \\    } else {
        \\        return 0;
        \\    }
        \\}
    );

    try std.testing.expect(!contains(result.code, "elseif"));
    try std.testing.expect(contains(result.code, "else if"));
    try std.testing.expectEqual(@as(usize, 0), result.errors.len);
}

test "TestElseIfSpacing_ElseIfWithoutFinalElse" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try minifyFull(alloc,
        \\fn partial(x: i32) -> i32 {
        \\    if (x > 0) {
        \\        return 1;
        \\    } else if (x < 0) {
        \\        return -1;
        \\    }
        \\    return 0;
        \\}
    );

    try std.testing.expect(!contains(result.code, "elseif"));
    try std.testing.expect(contains(result.code, "else if"));
    try std.testing.expectEqual(@as(usize, 0), result.errors.len);
}

test "TestElseIfSpacing_ElseIfWithComplexConditions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try minifyFull(alloc,
        \\fn complex(a: i32, b: i32) -> i32 {
        \\    if (a > 0 && b > 0) {
        \\        return 1;
        \\    } else if (a < 0 || b < 0) {
        \\        return -1;
        \\    } else if (a == 0 && b == 0) {
        \\        return 0;
        \\    } else {
        \\        return 2;
        \\    }
        \\}
    );

    try std.testing.expect(!contains(result.code, "elseif"));
    try std.testing.expect(contains(result.code, "else if"));
    try std.testing.expectEqual(@as(usize, 0), result.errors.len);
}

// =========================================================================
// 11. TestElseIfInComputeShader
// =========================================================================

test "TestElseIfInComputeShader" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try minifyFull(alloc,
        \\@compute @workgroup_size(64)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    var value: f32 = 0.0;
        \\    let x = f32(id.x);
        \\
        \\    if (x > 100.0) {
        \\        value = 1.0;
        \\    } else if (x > 50.0) {
        \\        value = 0.75;
        \\    } else if (x > 25.0) {
        \\        value = 0.5;
        \\    } else if (x > 0.0) {
        \\        value = 0.25;
        \\    } else {
        \\        value = 0.0;
        \\    }
        \\}
    );

    // Verify proper else if spacing
    try std.testing.expect(!contains(result.code, "elseif"));

    // Count the number of "else if" occurrences - should be at least 3
    try std.testing.expect(count(result.code, "else if") >= 3);
}

// =========================================================================
// 12. TestNoInvalidConstAliases
// =========================================================================

test "TestNoInvalidConstAliases_SingleUniform" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try minifyFullWithTreeShaking(alloc,
        \\struct Params { time: f32, scale: f32 }
        \\@group(0) @binding(0) var<uniform> params: Params;
        \\
        \\fn getValue() -> f32 {
        \\    return params.time * params.scale;
        \\}
    );

    try std.testing.expect(!hasConstAliasPattern(result.code));
    const fn_index = std.mem.indexOf(u8, result.code, "fn ") orelse result.code.len;
    const module_scope = result.code[0..fn_index];
    try std.testing.expect(!contains(module_scope, "let "));
    try std.testing.expectEqual(@as(usize, 0), result.errors.len);
}

test "TestNoInvalidConstAliases_MultipleUniforms" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try minifyFullWithTreeShaking(alloc,
        \\@group(0) @binding(0) var<uniform> time: f32;
        \\@group(0) @binding(1) var<uniform> scale: f32;
        \\
        \\fn getValue() -> f32 {
        \\    return time * scale * time * scale;
        \\}
    );

    try std.testing.expect(!hasConstAliasPattern(result.code));
    const fn_index = std.mem.indexOf(u8, result.code, "fn ") orelse result.code.len;
    const module_scope = result.code[0..fn_index];
    try std.testing.expect(!contains(module_scope, "let "));
    try std.testing.expectEqual(@as(usize, 0), result.errors.len);
}

test "TestNoInvalidConstAliases_StorageBuffer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try minifyFullWithTreeShaking(alloc,
        \\@group(0) @binding(0) var<storage, read_write> data: array<f32>;
        \\
        \\fn process(idx: u32) {
        \\    data[idx] = data[idx] * 2.0;
        \\}
    );

    try std.testing.expect(!hasConstAliasPattern(result.code));
    const fn_index = std.mem.indexOf(u8, result.code, "fn ") orelse result.code.len;
    const module_scope = result.code[0..fn_index];
    try std.testing.expect(!contains(module_scope, "let "));
    try std.testing.expectEqual(@as(usize, 0), result.errors.len);
}

test "TestNoInvalidConstAliases_MixedBindings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try minifyFullWithTreeShaking(alloc,
        \\struct Uniforms { multiplier: f32 }
        \\@group(0) @binding(0) var<uniform> uniforms: Uniforms;
        \\@group(0) @binding(1) var<storage> input: array<f32>;
        \\@group(0) @binding(2) var<storage, read_write> output: array<f32>;
        \\
        \\fn process(idx: u32) {
        \\    output[idx] = input[idx] * uniforms.multiplier;
        \\}
    );

    try std.testing.expect(!hasConstAliasPattern(result.code));
    const fn_index = std.mem.indexOf(u8, result.code, "fn ") orelse result.code.len;
    const module_scope = result.code[0..fn_index];
    try std.testing.expect(!contains(module_scope, "let "));
    try std.testing.expectEqual(@as(usize, 0), result.errors.len);
}

test "TestNoInvalidConstAliases_UniformUsedManyTimes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try minifyFullWithTreeShaking(alloc,
        \\@group(0) @binding(0) var<uniform> factor: f32;
        \\
        \\fn compute(a: f32, b: f32, c: f32) -> f32 {
        \\    let x = a * factor;
        \\    let y = b * factor;
        \\    let z = c * factor;
        \\    let w = (x + y + z) * factor;
        \\    return w * factor;
        \\}
    );

    try std.testing.expect(!hasConstAliasPattern(result.code));
    const fn_index = std.mem.indexOf(u8, result.code, "fn ") orelse result.code.len;
    const module_scope = result.code[0..fn_index];
    try std.testing.expect(!contains(module_scope, "let "));
    try std.testing.expectEqual(@as(usize, 0), result.errors.len);
}

// =========================================================================
// 13. TestExternalBindingsPreserveNames
// =========================================================================

test "TestExternalBindingsPreserveNames" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try miniray.minifyWithOptions(alloc,
        \\@group(0) @binding(0) var<uniform> myUniforms: f32;
        \\@group(0) @binding(1) var<storage> myStorage: array<f32>;
        \\
        \\fn process(idx: u32) -> f32 {
        \\    return myStorage[idx] * myUniforms;
        \\}
    , .{
        .minify_whitespace = true,
        .minify_identifiers = true,
        .mangle_external_bindings = false,
        .tree_shaking = false,
    });

    // External binding names should be preserved
    try std.testing.expect(contains(result.code, "myUniforms"));
    try std.testing.expect(contains(result.code, "myStorage"));

    // Function should still be renamed
    try std.testing.expect(!contains(result.code, "process"));
}

// =========================================================================
// 14. TestExternalBindingsMangled
// =========================================================================

test "TestExternalBindingsMangled" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try minifyMangleExt(alloc,
        \\@group(0) @binding(0) var<uniform> myUniforms: f32;
        \\
        \\fn getValue() -> f32 {
        \\    return myUniforms * 2.0;
        \\}
    );

    // External binding should be renamed
    try std.testing.expect(!contains(result.code, "myUniforms"));
}

// =========================================================================
// 15. TestShadowingBasic
// =========================================================================

test "TestShadowingBasic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try miniray.minifyWithOptions(alloc,
        \\fn helper(x: f32) -> f32 {
        \\    return x * 2.0;
        \\}
        \\
        \\fn main() -> f32 {
        \\    let a = helper(1.0);
        \\    let helper = a + 1.0;
        \\    return helper;
        \\}
    , .{
        .minify_whitespace = true,
        .minify_identifiers = true,
        .tree_shaking = false,
    });

    try std.testing.expectEqual(@as(usize, 0), result.errors.len);

    // Should not contain original names
    try std.testing.expect(!contains(result.code, "helper"));
}

// =========================================================================
// 16. TestShadowingMultipleFunctions
// =========================================================================

test "TestShadowingMultipleFunctions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try miniray.minifyWithOptions(alloc,
        \\fn circle(p: vec2f, r: f32) -> f32 {
        \\    return length(p) - r;
        \\}
        \\
        \\fn box(p: vec2f, b: vec2f) -> f32 {
        \\    let d = abs(p) - b;
        \\    return length(max(d, vec2f(0.0))) + min(max(d.x, d.y), 0.0);
        \\}
        \\
        \\fn scene(p: vec2f) -> f32 {
        \\    let d1 = circle(p, 0.5);
        \\    let d2 = box(p, vec2f(0.3));
        \\
        \\    let circle = min(d1, d2);
        \\    let box = circle * 2.0;
        \\
        \\    return box;
        \\}
    , .{
        .minify_whitespace = true,
        .minify_identifiers = true,
        .tree_shaking = false,
    });

    try std.testing.expectEqual(@as(usize, 0), result.errors.len);

    // All original names should be renamed
    try std.testing.expect(!contains(result.code, "circle"));
    try std.testing.expect(!contains(result.code, "box"));
    try std.testing.expect(!contains(result.code, "scene"));
}

// =========================================================================
// 17. TestShadowingInNestedScopes
// =========================================================================

test "TestShadowingInNestedScopes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try miniray.minifyWithOptions(alloc,
        \\fn outer(x: f32) -> f32 {
        \\    return x + 1.0;
        \\}
        \\
        \\fn test() -> f32 {
        \\    let a = outer(1.0);
        \\    if (a > 0.0) {
        \\        let outer = a * 2.0;
        \\        return outer;
        \\    }
        \\    return outer(a);
        \\}
    , .{
        .minify_whitespace = true,
        .minify_identifiers = true,
        .tree_shaking = false,
    });

    try std.testing.expectEqual(@as(usize, 0), result.errors.len);
}

// =========================================================================
// 18. TestShadowingWithLoops
// =========================================================================

test "TestShadowingWithLoops" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try miniray.minifyWithOptions(alloc,
        \\fn index(i: u32) -> u32 {
        \\    return i * 2u;
        \\}
        \\
        \\fn sum() -> u32 {
        \\    var total: u32 = 0u;
        \\    for (var i: u32 = 0u; i < 10u; i++) {
        \\        let idx = index(i);
        \\        let index = idx + 1u;
        \\        total += index;
        \\    }
        \\    return total;
        \\}
    , .{
        .minify_whitespace = true,
        .minify_identifiers = true,
        .tree_shaking = false,
    });

    try std.testing.expectEqual(@as(usize, 0), result.errors.len);
}

// =========================================================================
// 19. TestShadowingCallBeforeAndAfter
// =========================================================================

test "TestShadowingCallBeforeAndAfter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try miniray.minifyWithOptions(alloc,
        \\fn foo(x: f32) -> f32 {
        \\    return x * 2.0;
        \\}
        \\
        \\fn test() -> f32 {
        \\    let a = foo(1.0);
        \\    let foo = 3.0;
        \\    let b = foo + a;
        \\    return b;
        \\}
        \\
        \\fn test2() -> f32 {
        \\    return foo(2.0);
        \\}
    , .{
        .minify_whitespace = true,
        .minify_identifiers = true,
        .tree_shaking = false,
    });

    try std.testing.expectEqual(@as(usize, 0), result.errors.len);

    // 'foo' should be renamed
    try std.testing.expect(!contains(result.code, "foo"));
}

// =========================================================================
// 20. TestShadowingStruct
// =========================================================================

test "TestShadowingStruct" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try miniray.minifyWithOptions(alloc,
        \\struct Data {
        \\    value: f32,
        \\}
        \\
        \\fn Data_new(v: f32) -> Data {
        \\    return Data(v);
        \\}
        \\
        \\fn test() -> f32 {
        \\    let d = Data_new(1.0);
        \\    let Data = d.value;
        \\    return Data;
        \\}
    , .{
        .minify_whitespace = true,
        .minify_identifiers = true,
        .tree_shaking = false,
    });

    try std.testing.expectEqual(@as(usize, 0), result.errors.len);
}

// =========================================================================
// 21. TestShadowingParameter
// =========================================================================

test "TestShadowingParameter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try miniray.minifyWithOptions(alloc,
        \\fn transform(p: vec2f) -> vec2f {
        \\    return p * 2.0;
        \\}
        \\
        \\fn test(transform: f32) -> f32 {
        \\    return transform + 1.0;
        \\}
        \\
        \\fn test2() -> vec2f {
        \\    return transform(vec2f(1.0));
        \\}
    , .{
        .minify_whitespace = true,
        .minify_identifiers = true,
        .tree_shaking = false,
    });

    try std.testing.expectEqual(@as(usize, 0), result.errors.len);
}

// =========================================================================
// 22. TestPreserveUniformStructTypes_Basic
// =========================================================================

test "TestPreserveUniformStructTypes_Basic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try miniray.minifyWithOptions(alloc,
        \\struct MyUniforms {
        \\    time: f32,
        \\    scale: f32,
        \\}
        \\
        \\@group(0) @binding(0) var<uniform> u: MyUniforms;
        \\
        \\fn getValue() -> f32 {
        \\    return u.time * u.scale;
        \\}
    , .{
        .minify_whitespace = true,
        .minify_identifiers = true,
        .minify_syntax = true,
        .preserve_uniform_struct_types = true,
        .tree_shaking = false,
    });

    // Struct type 'MyUniforms' should be preserved
    try std.testing.expect(contains(result.code, "MyUniforms"));

    // Variable name 'u' should be preserved (external binding)
    try std.testing.expect(contains(result.code, "var<uniform> u"));

    // Function 'getValue' should be renamed
    try std.testing.expect(!contains(result.code, "getValue"));
}

// =========================================================================
// 23. TestPreserveUniformStructTypes_MultipleStructs
// =========================================================================

test "TestPreserveUniformStructTypes_MultipleStructs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try miniray.minifyWithOptions(alloc,
        \\struct UniformA {
        \\    x: f32,
        \\}
        \\
        \\struct StorageB {
        \\    y: f32,
        \\}
        \\
        \\struct NotInBinding {
        \\    z: f32,
        \\}
        \\
        \\@group(0) @binding(0) var<uniform> a: UniformA;
        \\@group(0) @binding(1) var<storage> b: StorageB;
        \\
        \\fn process() -> f32 {
        \\    var local: NotInBinding;
        \\    local.z = 1.0;
        \\    return a.x + b.y + local.z;
        \\}
    , .{
        .minify_whitespace = true,
        .minify_identifiers = true,
        .preserve_uniform_struct_types = true,
        .tree_shaking = false,
    });

    // UniformA and StorageB should be preserved (used in bindings)
    try std.testing.expect(contains(result.code, "UniformA"));
    try std.testing.expect(contains(result.code, "StorageB"));

    // NotInBinding struct should be renamed
    try std.testing.expect(!contains(result.code, "NotInBinding"));
}

// =========================================================================
// 24. TestPreserveUniformStructTypes_NestedType
// =========================================================================

test "TestPreserveUniformStructTypes_NestedType" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try miniray.minifyWithOptions(alloc,
        \\struct Inner {
        \\    v: f32,
        \\}
        \\
        \\struct Outer {
        \\    inner: Inner,
        \\}
        \\
        \\@group(0) @binding(0) var<uniform> u: Outer;
        \\
        \\fn getValue() -> f32 {
        \\    return u.inner.v;
        \\}
    , .{
        .minify_whitespace = true,
        .minify_identifiers = true,
        .preserve_uniform_struct_types = true,
        .tree_shaking = false,
    });

    // Outer should be preserved (direct type in uniform)
    try std.testing.expect(contains(result.code, "Outer"));
}

// =========================================================================
// 25. TestPreserveUniformStructTypes_Disabled
// =========================================================================

test "TestPreserveUniformStructTypes_Disabled" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try miniray.minifyWithOptions(alloc,
        \\struct MyUniforms {
        \\    time: f32,
        \\}
        \\
        \\@group(0) @binding(0) var<uniform> u: MyUniforms;
        \\
        \\fn getValue() -> f32 {
        \\    return u.time;
        \\}
    , .{
        .minify_whitespace = true,
        .minify_identifiers = true,
        .preserve_uniform_struct_types = false,
        .tree_shaking = false,
    });

    // Struct type 'MyUniforms' should be renamed when option is disabled
    try std.testing.expect(!contains(result.code, "MyUniforms"));
}

// =========================================================================
// 26. TestPreserveUniformStructTypes_WithKeepNames
// =========================================================================

test "TestPreserveUniformStructTypes_WithKeepNames" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try miniray.minifyWithOptions(alloc,
        \\struct AutoPreserved {
        \\    a: f32,
        \\}
        \\
        \\struct ManuallyKept {
        \\    b: f32,
        \\}
        \\
        \\struct ShouldRename {
        \\    c: f32,
        \\}
        \\
        \\@group(0) @binding(0) var<uniform> u: AutoPreserved;
        \\
        \\fn helper() -> f32 {
        \\    var m: ManuallyKept;
        \\    var s: ShouldRename;
        \\    return u.a + m.b + s.c;
        \\}
    , .{
        .minify_whitespace = true,
        .minify_identifiers = true,
        .preserve_uniform_struct_types = true,
        .keep_names = &.{"ManuallyKept"},
        .tree_shaking = false,
    });

    // AutoPreserved: preserved via PreserveUniformStructTypes
    try std.testing.expect(contains(result.code, "AutoPreserved"));

    // ManuallyKept: preserved via keepNames
    try std.testing.expect(contains(result.code, "ManuallyKept"));

    // ShouldRename: not in keepNames, not in uniform binding
    try std.testing.expect(!contains(result.code, "ShouldRename"));
}

// =========================================================================
// 27. TestPreserveUniformStructTypes_PngineBuiltins
// =========================================================================

test "TestPreserveUniformStructTypes_PngineBuiltins" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try miniray.minifyWithOptions(alloc,
        \\struct PngineInputs {
        \\    time: f32,
        \\    canvasW: f32,
        \\    canvasH: f32,
        \\}
        \\
        \\@group(0) @binding(0) var<uniform> pngine: PngineInputs;
        \\
        \\fn computeUV(pos: vec2f) -> vec2f {
        \\    return pos / vec2f(pngine.canvasW, pngine.canvasH);
        \\}
        \\
        \\@fragment
        \\fn main(@builtin(position) pos: vec4f) -> @location(0) vec4f {
        \\    let uv = computeUV(pos.xy);
        \\    let t = pngine.time;
        \\    return vec4f(uv, t, 1.0);
        \\}
    , .{
        .minify_whitespace = true,
        .minify_identifiers = true,
        .minify_syntax = true,
        .preserve_uniform_struct_types = true,
        .tree_shaking = false,
    });

    // PngineInputs should be preserved
    try std.testing.expect(contains(result.code, "PngineInputs"));

    // pngine variable should be preserved (external binding)
    try std.testing.expect(contains(result.code, "pngine"));

    // Entry point 'main' should be preserved
    try std.testing.expect(contains(result.code, "fn main"));

    // Helper function 'computeUV' should be renamed
    try std.testing.expect(!contains(result.code, "computeUV"));

    // Field names should be preserved (accessed via `.`)
    try std.testing.expect(contains(result.code, ".time"));
    try std.testing.expect(contains(result.code, ".canvasW"));
}

// =========================================================================
// 28. TestShadowingRealisticSDF
// =========================================================================

test "TestShadowingRealisticSDF" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\fn box(p: vec2f, b: vec2f) -> f32 {
        \\    let d = abs(p) - b;
        \\    return length(max(d, vec2f(0.0))) + min(max(d.x, d.y), 0.0);
        \\}
        \\
        \\fn circle(p: vec2f, r: f32) -> f32 {
        \\    return length(p) - r;
        \\}
        \\
        \\fn smoothMin(a: f32, b: f32, k: f32) -> f32 {
        \\    let h = max(k - abs(a - b), 0.0) / k;
        \\    return min(a, b) - h * h * k * 0.25;
        \\}
        \\
        \\fn scene(p: vec2f) -> f32 {
        \\    let box = box(p - vec2f(0.5, 0.0), vec2f(0.3, 0.2));
        \\    let circle = circle(p + vec2f(0.5, 0.0), 0.25);
        \\    let combined = smoothMin(box, circle, 0.1);
        \\    return combined;
        \\}
        \\
        \\@fragment
        \\fn main(@location(0) uv: vec2f) -> @location(0) vec4f {
        \\    let d = scene(uv);
        \\    return vec4f(vec3f(d), 1.0);
        \\}
    ;

    const result = try miniray.minifyWithOptions(alloc, source, .{
        .minify_whitespace = true,
        .minify_identifiers = true,
        .tree_shaking = false,
    });

    try std.testing.expectEqual(@as(usize, 0), result.errors.len);

    // Should be minified (at least 25% smaller)
    try std.testing.expect(result.code.len <= source.len * 3 / 4);
}
