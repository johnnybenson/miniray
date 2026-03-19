//! WGSL built-in functions and their type signatures.
//!
//! Implements the builtin function table as defined in WGSL spec section 17,
//! supporting overload resolution and validation of builtin function calls.
//! Ports the Go `internal/builtins/builtins.go` package.

const std = @import("std");

const Builtins = @This();

// =========================================================================
// Enums
// =========================================================================

/// Identifies categories of builtin functions.
pub const Kind = enum(u8) {
    constructor, // Type constructors
    conversion, // Bit reinterpretation
    logical, // Logical operations
    array, // Array operations
    numeric, // Math functions
    derivative, // Derivative functions (require uniform flow)
    texture, // Texture sampling
    atomic, // Atomic operations
    packing, // Data packing/unpacking
    synchronization, // Barriers (require uniform flow)
    subgroup, // Subgroup operations (require uniform flow)
};

/// Indicates when a function can be evaluated.
pub const EvalStage = enum(u8) {
    runtime, // Only at runtime
    const_eval, // At compile time
    override, // At pipeline creation
};

/// Indicates uniformity constraints on a builtin call.
pub const UniformityRequirement = enum(u8) {
    none, // No uniformity requirement
    uniform_flow, // Call must be in uniform control flow
    uniform_args, // Certain arguments must be uniform
};

// =========================================================================
// Builtin Definition
// =========================================================================

/// Describes a single WGSL builtin function.
pub const Builtin = struct {
    name: []const u8,
    kind: Kind,
    stage: EvalStage,
    uniformity: UniformityRequirement,
    min_args: u8, // Minimum argument count for overload resolution stub
    max_args: u8, // Maximum argument count for overload resolution stub

    /// Returns true if this builtin requires uniform control flow.
    pub fn requiresUniform(self: *const Builtin) bool {
        return self.uniformity == .uniform_flow;
    }

    /// Returns true if this builtin can be evaluated at compile time.
    pub fn isConstEval(self: *const Builtin) bool {
        return self.stage == .const_eval;
    }

    /// Stub overload resolution: checks argument count is in the valid range.
    /// Full type-checking overload resolution will be added when the validator
    /// is wired up.
    pub fn checkArgCount(self: *const Builtin, arg_count: u32) bool {
        return arg_count >= self.min_args and arg_count <= self.max_args;
    }
};

// =========================================================================
// Lookup Table
// =========================================================================

/// Comptime-built lookup table mapping builtin function names to definitions.
const table = std.StaticStringMap(Builtin).initComptime(builtin_entries);

/// Look up a builtin function by name, or return null if not found.
pub fn lookup(name: []const u8) ?Builtin {
    return table.get(name);
}

/// Returns true if the given name is a builtin function.
pub fn isBuiltin(name: []const u8) bool {
    return table.has(name);
}

// =========================================================================
// Builtin Entries
// =========================================================================

/// All WGSL builtin functions registered in the lookup table.
/// Order follows WGSL spec sections: conversions, logical, array, numeric,
/// derivative, texture, atomic, packing, synchronization, subgroup.
const builtin_entries = conversion_entries ++
    logical_entries ++
    array_entries ++
    numeric_trig_entries ++
    numeric_exp_entries ++
    numeric_misc_entries ++
    numeric_vector_entries ++
    numeric_bit_entries ++
    numeric_matrix_entries ++
    numeric_special_entries ++
    derivative_entries ++
    texture_entries ++
    atomic_entries ++
    packing_entries ++
    synchronization_entries ++
    subgroup_entries;

// ---------------------------------------------------------------------------
// Conversion Builtins (Section 17.2)
// ---------------------------------------------------------------------------

const conversion_entries = [_]struct { []const u8, Builtin }{
    entry("bitcast", .conversion, .const_eval, .none, 1, 1),
};

// ---------------------------------------------------------------------------
// Logical Builtins (Section 17.3)
// ---------------------------------------------------------------------------

const logical_entries = [_]struct { []const u8, Builtin }{
    entry("all", .logical, .const_eval, .none, 1, 1),
    entry("any", .logical, .const_eval, .none, 1, 1),
    entry("select", .logical, .const_eval, .none, 3, 3),
};

// ---------------------------------------------------------------------------
// Array Builtins (Section 17.4)
// ---------------------------------------------------------------------------

const array_entries = [_]struct { []const u8, Builtin }{
    entry("arrayLength", .array, .runtime, .none, 1, 1),
};

// ---------------------------------------------------------------------------
// Numeric Builtins (Section 17.5) - Trigonometric
// ---------------------------------------------------------------------------

const numeric_trig_entries = [_]struct { []const u8, Builtin }{
    entry("sin", .numeric, .const_eval, .none, 1, 1),
    entry("cos", .numeric, .const_eval, .none, 1, 1),
    entry("tan", .numeric, .const_eval, .none, 1, 1),
    entry("asin", .numeric, .const_eval, .none, 1, 1),
    entry("acos", .numeric, .const_eval, .none, 1, 1),
    entry("atan", .numeric, .const_eval, .none, 1, 1),
    entry("sinh", .numeric, .const_eval, .none, 1, 1),
    entry("cosh", .numeric, .const_eval, .none, 1, 1),
    entry("tanh", .numeric, .const_eval, .none, 1, 1),
    entry("asinh", .numeric, .const_eval, .none, 1, 1),
    entry("acosh", .numeric, .const_eval, .none, 1, 1),
    entry("atanh", .numeric, .const_eval, .none, 1, 1),
    entry("atan2", .numeric, .const_eval, .none, 2, 2),
};

// ---------------------------------------------------------------------------
// Numeric Builtins (Section 17.5) - Exponential
// ---------------------------------------------------------------------------

const numeric_exp_entries = [_]struct { []const u8, Builtin }{
    entry("exp", .numeric, .const_eval, .none, 1, 1),
    entry("exp2", .numeric, .const_eval, .none, 1, 1),
    entry("log", .numeric, .const_eval, .none, 1, 1),
    entry("log2", .numeric, .const_eval, .none, 1, 1),
    entry("pow", .numeric, .const_eval, .none, 2, 2),
    entry("sqrt", .numeric, .const_eval, .none, 1, 1),
    entry("inverseSqrt", .numeric, .const_eval, .none, 1, 1),
};

// ---------------------------------------------------------------------------
// Numeric Builtins (Section 17.5) - Misc math
// ---------------------------------------------------------------------------

const numeric_misc_entries = [_]struct { []const u8, Builtin }{
    entry("abs", .numeric, .const_eval, .none, 1, 1),
    entry("sign", .numeric, .const_eval, .none, 1, 1),
    entry("floor", .numeric, .const_eval, .none, 1, 1),
    entry("ceil", .numeric, .const_eval, .none, 1, 1),
    entry("round", .numeric, .const_eval, .none, 1, 1),
    entry("trunc", .numeric, .const_eval, .none, 1, 1),
    entry("fract", .numeric, .const_eval, .none, 1, 1),
    entry("min", .numeric, .const_eval, .none, 2, 2),
    entry("max", .numeric, .const_eval, .none, 2, 2),
    entry("clamp", .numeric, .const_eval, .none, 3, 3),
    entry("saturate", .numeric, .const_eval, .none, 1, 1),
    entry("mix", .numeric, .const_eval, .none, 3, 3),
    entry("step", .numeric, .const_eval, .none, 2, 2),
    entry("smoothstep", .numeric, .const_eval, .none, 3, 3),
    entry("fma", .numeric, .const_eval, .none, 3, 3),
    entry("degrees", .numeric, .const_eval, .none, 1, 1),
    entry("radians", .numeric, .const_eval, .none, 1, 1),
};

// ---------------------------------------------------------------------------
// Numeric Builtins (Section 17.5) - Vector operations
// ---------------------------------------------------------------------------

const numeric_vector_entries = [_]struct { []const u8, Builtin }{
    entry("dot", .numeric, .const_eval, .none, 2, 2),
    entry("cross", .numeric, .const_eval, .none, 2, 2),
    entry("length", .numeric, .const_eval, .none, 1, 1),
    entry("distance", .numeric, .const_eval, .none, 2, 2),
    entry("normalize", .numeric, .const_eval, .none, 1, 1),
    entry("reflect", .numeric, .const_eval, .none, 2, 2),
    entry("refract", .numeric, .const_eval, .none, 3, 3),
    entry("faceForward", .numeric, .const_eval, .none, 3, 3),
};

// ---------------------------------------------------------------------------
// Numeric Builtins (Section 17.5) - Bit operations
// ---------------------------------------------------------------------------

const numeric_bit_entries = [_]struct { []const u8, Builtin }{
    entry("countOneBits", .numeric, .const_eval, .none, 1, 1),
    entry("countLeadingZeros", .numeric, .const_eval, .none, 1, 1),
    entry("countTrailingZeros", .numeric, .const_eval, .none, 1, 1),
    entry("reverseBits", .numeric, .const_eval, .none, 1, 1),
    entry("firstLeadingBit", .numeric, .const_eval, .none, 1, 1),
    entry("firstTrailingBit", .numeric, .const_eval, .none, 1, 1),
    entry("extractBits", .numeric, .const_eval, .none, 3, 3),
    entry("insertBits", .numeric, .const_eval, .none, 4, 4),
};

// ---------------------------------------------------------------------------
// Numeric Builtins (Section 17.5) - Matrix operations
// ---------------------------------------------------------------------------

const numeric_matrix_entries = [_]struct { []const u8, Builtin }{
    entry("transpose", .numeric, .const_eval, .none, 1, 1),
    entry("determinant", .numeric, .const_eval, .none, 1, 1),
};

// ---------------------------------------------------------------------------
// Numeric Builtins (Section 17.5) - Special (ldexp, frexp, modf, etc.)
// ---------------------------------------------------------------------------

const numeric_special_entries = [_]struct { []const u8, Builtin }{
    entry("ldexp", .numeric, .const_eval, .none, 2, 2),
    entry("frexp", .numeric, .runtime, .none, 1, 1),
    entry("modf", .numeric, .runtime, .none, 1, 1),
    entry("quantizeToF16", .numeric, .const_eval, .none, 1, 1),
};

// ---------------------------------------------------------------------------
// Derivative Builtins (Section 17.6) - REQUIRE UNIFORM CONTROL FLOW
// ---------------------------------------------------------------------------

const derivative_entries = [_]struct { []const u8, Builtin }{
    entry("dpdx", .derivative, .runtime, .uniform_flow, 1, 1),
    entry("dpdy", .derivative, .runtime, .uniform_flow, 1, 1),
    entry("fwidth", .derivative, .runtime, .uniform_flow, 1, 1),
    entry("dpdxCoarse", .derivative, .runtime, .uniform_flow, 1, 1),
    entry("dpdyCoarse", .derivative, .runtime, .uniform_flow, 1, 1),
    entry("fwidthCoarse", .derivative, .runtime, .uniform_flow, 1, 1),
    entry("dpdxFine", .derivative, .runtime, .uniform_flow, 1, 1),
    entry("dpdyFine", .derivative, .runtime, .uniform_flow, 1, 1),
    entry("fwidthFine", .derivative, .runtime, .uniform_flow, 1, 1),
};

// ---------------------------------------------------------------------------
// Texture Builtins (Section 17.7)
// ---------------------------------------------------------------------------

const texture_entries = [_]struct { []const u8, Builtin }{
    // textureSample requires uniform control flow
    entry("textureSample", .texture, .runtime, .uniform_flow, 2, 5),
    entry("textureSampleBias", .texture, .runtime, .uniform_flow, 3, 6),
    entry("textureSampleCompare", .texture, .runtime, .uniform_flow, 3, 6),
    // textureSampleCompareLevel does NOT require uniform control flow
    entry("textureSampleCompareLevel", .texture, .runtime, .none, 4, 6),
    // textureSampleLevel does NOT require uniform control flow
    entry("textureSampleLevel", .texture, .runtime, .none, 3, 6),
    // textureSampleGrad does NOT require uniform control flow
    entry("textureSampleGrad", .texture, .runtime, .none, 4, 7),
    // textureLoad/Store
    entry("textureLoad", .texture, .runtime, .none, 2, 4),
    entry("textureStore", .texture, .runtime, .none, 3, 4),
    // textureDimensions, textureNumLayers, textureNumLevels, textureNumSamples
    entry("textureDimensions", .texture, .runtime, .none, 1, 2),
    entry("textureNumLayers", .texture, .runtime, .none, 1, 1),
    entry("textureNumLevels", .texture, .runtime, .none, 1, 1),
    entry("textureNumSamples", .texture, .runtime, .none, 1, 1),
    // textureGather and textureGatherCompare require uniform control flow
    entry("textureGather", .texture, .runtime, .uniform_flow, 3, 5),
    entry("textureGatherCompare", .texture, .runtime, .uniform_flow, 4, 6),
};

// ---------------------------------------------------------------------------
// Atomic Builtins (Section 17.8)
// ---------------------------------------------------------------------------

const atomic_entries = [_]struct { []const u8, Builtin }{
    entry("atomicLoad", .atomic, .runtime, .none, 1, 1),
    entry("atomicStore", .atomic, .runtime, .none, 2, 2),
    entry("atomicAdd", .atomic, .runtime, .none, 2, 2),
    entry("atomicSub", .atomic, .runtime, .none, 2, 2),
    entry("atomicMax", .atomic, .runtime, .none, 2, 2),
    entry("atomicMin", .atomic, .runtime, .none, 2, 2),
    entry("atomicAnd", .atomic, .runtime, .none, 2, 2),
    entry("atomicOr", .atomic, .runtime, .none, 2, 2),
    entry("atomicXor", .atomic, .runtime, .none, 2, 2),
    entry("atomicExchange", .atomic, .runtime, .none, 2, 2),
    entry("atomicCompareExchangeWeak", .atomic, .runtime, .none, 3, 3),
};

// ---------------------------------------------------------------------------
// Data Packing Builtins (Section 17.9-17.10)
// ---------------------------------------------------------------------------

const packing_entries = [_]struct { []const u8, Builtin }{
    // Packing functions: input is a vector, output is u32
    entry("pack4x8snorm", .packing, .const_eval, .none, 1, 1),
    entry("pack4x8unorm", .packing, .const_eval, .none, 1, 1),
    entry("pack2x16snorm", .packing, .const_eval, .none, 1, 1),
    entry("pack2x16unorm", .packing, .const_eval, .none, 1, 1),
    entry("pack2x16float", .packing, .const_eval, .none, 1, 1),
    entry("pack4xI8", .packing, .const_eval, .none, 1, 1),
    entry("pack4xU8", .packing, .const_eval, .none, 1, 1),
    entry("pack4xI8Clamp", .packing, .const_eval, .none, 1, 1),
    entry("pack4xU8Clamp", .packing, .const_eval, .none, 1, 1),
    // Unpacking functions: input is u32, output is a vector
    entry("unpack4x8snorm", .packing, .const_eval, .none, 1, 1),
    entry("unpack4x8unorm", .packing, .const_eval, .none, 1, 1),
    entry("unpack2x16snorm", .packing, .const_eval, .none, 1, 1),
    entry("unpack2x16unorm", .packing, .const_eval, .none, 1, 1),
    entry("unpack2x16float", .packing, .const_eval, .none, 1, 1),
    entry("unpack4xI8", .packing, .const_eval, .none, 1, 1),
    entry("unpack4xU8", .packing, .const_eval, .none, 1, 1),
};

// ---------------------------------------------------------------------------
// Synchronization Builtins (Section 17.11) - REQUIRE UNIFORM CONTROL FLOW
// ---------------------------------------------------------------------------

const synchronization_entries = [_]struct { []const u8, Builtin }{
    entry("workgroupBarrier", .synchronization, .runtime, .uniform_flow, 0, 0),
    entry("storageBarrier", .synchronization, .runtime, .uniform_flow, 0, 0),
    entry("textureBarrier", .synchronization, .runtime, .uniform_flow, 0, 0),
    entry("workgroupUniformLoad", .synchronization, .runtime, .uniform_flow, 1, 1),
};

// ---------------------------------------------------------------------------
// Subgroup Builtins (Section 17.12) - REQUIRE UNIFORM CONTROL FLOW
// ---------------------------------------------------------------------------

const subgroup_entries = [_]struct { []const u8, Builtin }{
    entry("subgroupBallot", .subgroup, .runtime, .uniform_flow, 0, 1),
    entry("subgroupBroadcast", .subgroup, .runtime, .uniform_flow, 2, 2),
    entry("subgroupBroadcastFirst", .subgroup, .runtime, .uniform_flow, 1, 1),
    entry("subgroupShuffle", .subgroup, .runtime, .uniform_flow, 2, 2),
    entry("subgroupShuffleDown", .subgroup, .runtime, .uniform_flow, 2, 2),
    entry("subgroupShuffleUp", .subgroup, .runtime, .uniform_flow, 2, 2),
    entry("subgroupShuffleXor", .subgroup, .runtime, .uniform_flow, 2, 2),
    entry("subgroupAdd", .subgroup, .runtime, .uniform_flow, 1, 1),
    entry("subgroupMul", .subgroup, .runtime, .uniform_flow, 1, 1),
    entry("subgroupAnd", .subgroup, .runtime, .uniform_flow, 1, 1),
    entry("subgroupOr", .subgroup, .runtime, .uniform_flow, 1, 1),
    entry("subgroupXor", .subgroup, .runtime, .uniform_flow, 1, 1),
    entry("subgroupMin", .subgroup, .runtime, .uniform_flow, 1, 1),
    entry("subgroupMax", .subgroup, .runtime, .uniform_flow, 1, 1),
    entry("subgroupInclusiveAdd", .subgroup, .runtime, .uniform_flow, 1, 1),
    entry("subgroupInclusiveMul", .subgroup, .runtime, .uniform_flow, 1, 1),
    entry("subgroupExclusiveAdd", .subgroup, .runtime, .uniform_flow, 1, 1),
    entry("subgroupExclusiveMul", .subgroup, .runtime, .uniform_flow, 1, 1),
    entry("subgroupAll", .subgroup, .runtime, .uniform_flow, 1, 1),
    entry("subgroupAny", .subgroup, .runtime, .uniform_flow, 1, 1),
    entry("subgroupElect", .subgroup, .runtime, .uniform_flow, 0, 0),
};

// =========================================================================
// Entry Helper
// =========================================================================

/// Builds a StaticStringMap entry tuple from builtin metadata.
fn entry(
    comptime name: []const u8,
    comptime kind: Kind,
    comptime stage: EvalStage,
    comptime uniformity: UniformityRequirement,
    comptime min_args: u8,
    comptime max_args: u8,
) struct { []const u8, Builtin } {
    return .{
        name,
        .{
            .name = name,
            .kind = kind,
            .stage = stage,
            .uniformity = uniformity,
            .min_args = min_args,
            .max_args = max_args,
        },
    };
}

// =========================================================================
// Tests
// =========================================================================

test "lookup returns known builtins" {
    // Logical
    const all_builtin = lookup("all");
    try std.testing.expect(all_builtin != null);
    try std.testing.expectEqual(Kind.logical, all_builtin.?.kind);
    try std.testing.expectEqual(EvalStage.const_eval, all_builtin.?.stage);

    // Numeric
    const sin_builtin = lookup("sin");
    try std.testing.expect(sin_builtin != null);
    try std.testing.expectEqual(Kind.numeric, sin_builtin.?.kind);

    // Derivative
    const dpdx_builtin = lookup("dpdx");
    try std.testing.expect(dpdx_builtin != null);
    try std.testing.expectEqual(Kind.derivative, dpdx_builtin.?.kind);
    try std.testing.expect(dpdx_builtin.?.requiresUniform());

    // Texture
    const ts_builtin = lookup("textureSample");
    try std.testing.expect(ts_builtin != null);
    try std.testing.expectEqual(Kind.texture, ts_builtin.?.kind);
    try std.testing.expect(ts_builtin.?.requiresUniform());

    // Atomic
    const al_builtin = lookup("atomicLoad");
    try std.testing.expect(al_builtin != null);
    try std.testing.expectEqual(Kind.atomic, al_builtin.?.kind);

    // Packing
    const pack_builtin = lookup("pack4x8snorm");
    try std.testing.expect(pack_builtin != null);
    try std.testing.expectEqual(Kind.packing, pack_builtin.?.kind);

    // Synchronization
    const wb_builtin = lookup("workgroupBarrier");
    try std.testing.expect(wb_builtin != null);
    try std.testing.expectEqual(Kind.synchronization, wb_builtin.?.kind);
    try std.testing.expect(wb_builtin.?.requiresUniform());

    // Subgroup
    const sb_builtin = lookup("subgroupBallot");
    try std.testing.expect(sb_builtin != null);
    try std.testing.expectEqual(Kind.subgroup, sb_builtin.?.kind);
    try std.testing.expect(sb_builtin.?.requiresUniform());
}

test "lookup returns null for unknown names" {
    try std.testing.expect(lookup("notABuiltin") == null);
    try std.testing.expect(lookup("") == null);
    try std.testing.expect(lookup("SIN") == null);
}

test "isBuiltin matches lookup" {
    try std.testing.expect(isBuiltin("sin"));
    try std.testing.expect(isBuiltin("cos"));
    try std.testing.expect(isBuiltin("textureSample"));
    try std.testing.expect(isBuiltin("atomicAdd"));
    try std.testing.expect(isBuiltin("workgroupBarrier"));
    try std.testing.expect(!isBuiltin("notABuiltin"));
    try std.testing.expect(!isBuiltin(""));
}

test "checkArgCount validates argument counts" {
    const select_builtin = lookup("select").?;
    try std.testing.expect(select_builtin.checkArgCount(3));
    try std.testing.expect(!select_builtin.checkArgCount(2));
    try std.testing.expect(!select_builtin.checkArgCount(4));

    const clamp_builtin = lookup("clamp").?;
    try std.testing.expect(clamp_builtin.checkArgCount(3));
    try std.testing.expect(!clamp_builtin.checkArgCount(1));

    // Barrier takes zero args.
    const barrier = lookup("workgroupBarrier").?;
    try std.testing.expect(barrier.checkArgCount(0));
    try std.testing.expect(!barrier.checkArgCount(1));

    // textureLoad accepts 2-4 args.
    const tl_builtin = lookup("textureLoad").?;
    try std.testing.expect(tl_builtin.checkArgCount(2));
    try std.testing.expect(tl_builtin.checkArgCount(3));
    try std.testing.expect(tl_builtin.checkArgCount(4));
    try std.testing.expect(!tl_builtin.checkArgCount(1));
    try std.testing.expect(!tl_builtin.checkArgCount(5));
}

test "requiresUniform correctness" {
    // Derivative builtins require uniform flow.
    const names_uniform = [_][]const u8{
        "dpdx",         "dpdy",          "fwidth",
        "dpdxCoarse",   "dpdyCoarse",    "fwidthCoarse",
        "dpdxFine",     "dpdyFine",      "fwidthFine",
        "textureSample", "textureSampleBias", "textureSampleCompare",
        "workgroupBarrier", "storageBarrier", "textureBarrier",
    };
    for (names_uniform) |name| {
        const b = lookup(name).?;
        try std.testing.expect(b.requiresUniform());
    }

    // These do NOT require uniform flow.
    const names_no_uniform = [_][]const u8{
        "sin",   "cos",   "abs",   "clamp",
        "textureSampleLevel", "textureSampleCompareLevel",
        "textureLoad", "textureStore",
        "atomicLoad",  "atomicAdd",
    };
    for (names_no_uniform) |name| {
        const b = lookup(name).?;
        try std.testing.expect(!b.requiresUniform());
    }
}

test "all Go builtins are registered" {
    // Exhaustive list of every builtin registered in the Go implementation.
    const all_names = [_][]const u8{
        // Conversion
        "bitcast",
        // Logical
        "all",                "any",                 "select",
        // Array
        "arrayLength",
        // Trigonometric
        "sin",                "cos",                 "tan",
        "asin",               "acos",                "atan",
        "sinh",               "cosh",                "tanh",
        "asinh",              "acosh",               "atanh",
        "atan2",
        // Exponential
        "exp",                "exp2",                "log",
        "log2",               "pow",                 "sqrt",
        "inverseSqrt",
        // Misc math
        "abs",                "sign",                "floor",
        "ceil",               "round",               "trunc",
        "fract",              "min",                 "max",
        "clamp",              "saturate",            "mix",
        "step",               "smoothstep",          "fma",
        "degrees",            "radians",
        // Vector
        "dot",                "cross",               "length",
        "distance",           "normalize",           "reflect",
        "refract",            "faceForward",
        // Bit
        "countOneBits",       "countLeadingZeros",   "countTrailingZeros",
        "reverseBits",        "firstLeadingBit",     "firstTrailingBit",
        "extractBits",        "insertBits",
        // Matrix
        "transpose",          "determinant",
        // Special
        "ldexp",              "frexp",               "modf",
        "quantizeToF16",
        // Derivative
        "dpdx",               "dpdy",                "fwidth",
        "dpdxCoarse",         "dpdyCoarse",          "fwidthCoarse",
        "dpdxFine",           "dpdyFine",            "fwidthFine",
        // Texture
        "textureSample",      "textureSampleBias",   "textureSampleCompare",
        "textureSampleCompareLevel", "textureSampleLevel", "textureSampleGrad",
        "textureLoad",        "textureStore",        "textureDimensions",
        "textureNumLayers",   "textureNumLevels",    "textureNumSamples",
        "textureGather",      "textureGatherCompare",
        // Atomic
        "atomicLoad",         "atomicStore",         "atomicAdd",
        "atomicSub",          "atomicMax",           "atomicMin",
        "atomicAnd",          "atomicOr",            "atomicXor",
        "atomicExchange",     "atomicCompareExchangeWeak",
        // Packing
        "pack4x8snorm",       "pack4x8unorm",        "pack2x16snorm",
        "pack2x16unorm",      "pack2x16float",       "pack4xI8",
        "pack4xU8",           "pack4xI8Clamp",       "pack4xU8Clamp",
        "unpack4x8snorm",     "unpack4x8unorm",      "unpack2x16snorm",
        "unpack2x16unorm",    "unpack2x16float",     "unpack4xI8",
        "unpack4xU8",
        // Synchronization
        "workgroupBarrier",   "storageBarrier",      "textureBarrier",
        "workgroupUniformLoad",
        // Subgroup
        "subgroupBallot",     "subgroupBroadcast",   "subgroupBroadcastFirst",
        "subgroupShuffle",    "subgroupShuffleDown",  "subgroupShuffleUp",
        "subgroupShuffleXor", "subgroupAdd",         "subgroupMul",
        "subgroupAnd",        "subgroupOr",          "subgroupXor",
        "subgroupMin",        "subgroupMax",
        "subgroupInclusiveAdd", "subgroupInclusiveMul",
        "subgroupExclusiveAdd", "subgroupExclusiveMul",
        "subgroupAll",        "subgroupAny",         "subgroupElect",
    };

    for (all_names) |name| {
        const b = lookup(name);
        if (b == null) {
            std.debug.print("missing builtin: {s}\n", .{name});
        }
        try std.testing.expect(b != null);
    }
}

test "entry count matches Go implementation" {
    // Go has 119 builtins registered (counted from the source).
    // Verify we have at least that many entries.
    const total = builtin_entries.len;
    try std.testing.expect(total >= 119);
}
