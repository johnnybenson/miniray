//! WGSL Abstract Syntax Tree.
//!
//! Uses a Go-style interface-based AST (via tagged unions) rather than the
//! flat MultiArrayList approach from the Zig compiler. This keeps the port
//! close to the Go original for correctness verification against snapshots.
//! A future optimization pass can flatten to MultiArrayList.

const std = @import("std");
const Lexer = @import("Lexer.zig");

// =========================================================================
// Symbols and References
// =========================================================================

/// Index into the symbol table. `none` matches Go's InvalidRef().
pub const SymbolIndex = enum(u32) {
    none = std.math.maxInt(u32),
    _,

    pub fn isValid(self: SymbolIndex) bool {
        return self != .none;
    }

    pub fn index(self: SymbolIndex) u32 {
        std.debug.assert(self != .none);
        return @intFromEnum(self);
    }
};

pub const Symbol = struct {
    original_name: []const u8,
    kind: Kind,
    flags: Flags,
    nested_scope_slot: ?u32 = null,
    use_count: u32 = 0,
    loc: u32 = 0,

    pub const Kind = enum(u4) {
        unbound,
        @"const",
        override,
        let,
        @"var",
        function,
        @"struct",
        alias,
        parameter,
        builtin,
        member,
    };

    pub const Flags = packed struct(u16) {
        must_not_be_renamed: bool = false,
        is_entry_point: bool = false,
        is_api_facing: bool = false,
        is_builtin: bool = false,
        is_external_binding: bool = false,
        is_live: bool = false,
        _padding: u10 = 0,
    };
};

// =========================================================================
// Scope
// =========================================================================

pub const ScopeMember = struct {
    ref: SymbolIndex,
    loc: u32, // Source position for text-order scoping
};

pub const Scope = struct {
    parent: ?*Scope,
    children: std.ArrayListUnmanaged(*Scope),
    members: std.StringHashMapUnmanaged(ScopeMember),

    pub fn init(parent: ?*Scope) Scope {
        return .{
            .parent = parent,
            .children = .empty,
            .members = .{},
        };
    }
};

// =========================================================================
// Module (top level)
// =========================================================================

pub const Module = struct {
    source: [:0]const u8,
    directives: std.ArrayListUnmanaged(Directive),
    declarations: std.ArrayListUnmanaged(Decl),
    symbols: std.ArrayListUnmanaged(Symbol),
    scope: *Scope,

    pub fn init(scope: *Scope, source: [:0]const u8) Module {
        return .{
            .source = source,
            .directives = .empty,
            .declarations = .empty,
            .symbols = .empty,
            .scope = scope,
        };
    }
};

// =========================================================================
// Directives
// =========================================================================

pub const Directive = union(enum) {
    enable: EnableDirective,
    requires: RequiresDirective,
    diagnostic: DiagnosticDirective,
};

pub const EnableDirective = struct {
    features: std.ArrayListUnmanaged([]const u8),
};

pub const RequiresDirective = struct {
    features: std.ArrayListUnmanaged([]const u8),
};

pub const DiagnosticDirective = struct {
    severity: []const u8,
    rule: []const u8,
};

// =========================================================================
// Declarations
// =========================================================================

pub const Decl = union(enum) {
    @"const": *ConstDecl,
    override: *OverrideDecl,
    @"var": *VarDecl,
    let: *LetDecl,
    function: *FunctionDecl,
    @"struct": *StructDecl,
    alias: *AliasDecl,
    const_assert: *ConstAssertDecl,

    /// Returns the symbol index of the declaration's name, if any.
    pub fn nameRef(self: Decl) SymbolIndex {
        return switch (self) {
            .@"const" => |d| d.name,
            .override => |d| d.name,
            .@"var" => |d| d.name,
            .let => |d| d.name,
            .function => |d| d.name,
            .@"struct" => |d| d.name,
            .alias => |d| d.name,
            .const_assert => .none,
        };
    }
};

pub const ConstDecl = struct {
    name: SymbolIndex,
    typ: ?Type = null,
    initializer: ?Expr = null,
};

pub const OverrideDecl = struct {
    attributes: std.ArrayListUnmanaged(Attribute),
    name: SymbolIndex,
    typ: ?Type = null,
    initializer: ?Expr = null,
};

pub const VarDecl = struct {
    attributes: std.ArrayListUnmanaged(Attribute),
    address_space: AddressSpace = .none,
    access_mode: AccessMode = .none,
    name: SymbolIndex,
    typ: ?Type = null,
    initializer: ?Expr = null,
};

pub const LetDecl = struct {
    name: SymbolIndex,
    typ: ?Type = null,
    initializer: ?Expr = null,
};

pub const FunctionDecl = struct {
    attributes: std.ArrayListUnmanaged(Attribute),
    name: SymbolIndex,
    parameters: std.ArrayListUnmanaged(Parameter),
    return_type: ?Type = null,
    return_attr: std.ArrayListUnmanaged(Attribute),
    body: ?*CompoundStmt = null,
};

pub const Parameter = struct {
    attributes: std.ArrayListUnmanaged(Attribute),
    name: SymbolIndex,
    typ: Type,
};

pub const StructDecl = struct {
    name: SymbolIndex,
    members: std.ArrayListUnmanaged(StructMember),
};

pub const StructMember = struct {
    attributes: std.ArrayListUnmanaged(Attribute),
    name: SymbolIndex,
    typ: Type,
};

pub const AliasDecl = struct {
    name: SymbolIndex,
    typ: Type,
};

pub const ConstAssertDecl = struct {
    expr: Expr,
};

// =========================================================================
// Address Spaces and Access Modes
// =========================================================================

pub const AddressSpace = enum(u8) {
    none,
    function,
    private,
    workgroup,
    uniform,
    storage,
    handle,

    pub fn string(self: AddressSpace) []const u8 {
        return switch (self) {
            .function => "function",
            .private => "private",
            .workgroup => "workgroup",
            .uniform => "uniform",
            .storage => "storage",
            .handle => "handle",
            .none => "",
        };
    }
};

pub const AccessMode = enum(u8) {
    none,
    read,
    write,
    read_write,

    pub fn string(self: AccessMode) []const u8 {
        return switch (self) {
            .read => "read",
            .write => "write",
            .read_write => "read_write",
            .none => "",
        };
    }
};

// =========================================================================
// Attributes
// =========================================================================

pub const Attribute = struct {
    name: []const u8,
    args: std.ArrayListUnmanaged(Expr),
};

// =========================================================================
// Types
// =========================================================================

pub const Type = union(enum) {
    ident: *IdentType,
    vec: *VecType,
    mat: *MatType,
    array: *ArrayType,
    ptr: *PtrType,
    atomic: *AtomicType,
    sampler: *SamplerType,
    texture: *TextureType,
};

pub const IdentType = struct {
    name: []const u8,
    ref: SymbolIndex = .none,
};

pub const VecType = struct {
    size: u8, // 2, 3, or 4
    elem_type: ?Type = null,
    shorthand: []const u8 = "",
};

pub const MatType = struct {
    cols: u8,
    rows: u8,
    elem_type: ?Type = null,
    shorthand: []const u8 = "",
};

pub const ArrayType = struct {
    elem_type: ?Type = null,
    size: ?Expr = null,
};

pub const PtrType = struct {
    address_space: AddressSpace,
    elem_type: Type,
    access_mode: AccessMode = .none,
};

pub const AtomicType = struct {
    elem_type: Type,
};

pub const SamplerType = struct {
    comparison: bool,
};

pub const TextureType = struct {
    kind: TextureKind,
    dimension: TextureDimension,
    sampled_type: ?Type = null,
    texel_format: []const u8 = "",
    access_mode: AccessMode = .none,
};

pub const TextureKind = enum(u8) {
    sampled,
    multisampled,
    storage,
    depth,
    depth_multisampled,
    external,
};

pub const TextureDimension = enum(u8) {
    @"1d",
    @"2d",
    @"2d_array",
    @"3d",
    cube,
    cube_array,
};

// =========================================================================
// Expressions
// =========================================================================

pub const Expr = union(enum) {
    ident: *IdentExpr,
    literal: *LiteralExpr,
    binary: *BinaryExpr,
    unary: *UnaryExpr,
    call: *CallExpr,
    index: *IndexExpr,
    member: *MemberExpr,
    paren: *ParenExpr,
};

pub const IdentExpr = struct {
    loc: u32 = 0,
    name: []const u8,
    ref: SymbolIndex = .none,
    flags: ExprFlags = .{},
};

pub const LiteralExpr = struct {
    kind: Lexer.Tag,
    value: []const u8,
    flags: ExprFlags = .{},
};

pub const BinaryExpr = struct {
    op: BinaryOp,
    left: Expr,
    right: Expr,
    flags: ExprFlags = .{},
};

pub const BinaryOp = enum(u8) {
    add, // +
    sub, // -
    mul, // *
    div, // /
    mod, // %
    @"and", // &
    @"or", // |
    xor, // ^
    shl, // <<
    shr, // >>
    logical_and, // &&
    logical_or, // ||
    eq, // ==
    ne, // !=
    lt, // <
    le, // <=
    gt, // >
    ge, // >=

    pub fn string(self: BinaryOp) []const u8 {
        return switch (self) {
            .add => "+",
            .sub => "-",
            .mul => "*",
            .div => "/",
            .mod => "%",
            .@"and" => "&",
            .@"or" => "|",
            .xor => "^",
            .shl => "<<",
            .shr => ">>",
            .logical_and => "&&",
            .logical_or => "||",
            .eq => "==",
            .ne => "!=",
            .lt => "<",
            .le => "<=",
            .gt => ">",
            .ge => ">=",
        };
    }
};

pub const UnaryExpr = struct {
    op: UnaryOp,
    operand: Expr,
    flags: ExprFlags = .{},
};

pub const UnaryOp = enum(u8) {
    neg, // -
    not, // !
    bit_not, // ~
    deref, // *
    addr, // &

    pub fn string(self: UnaryOp) []const u8 {
        return switch (self) {
            .neg => "-",
            .not => "!",
            .bit_not => "~",
            .deref => "*",
            .addr => "&",
        };
    }
};

pub const CallExpr = struct {
    func: ?Expr = null,
    template_type: ?Type = null,
    args: std.ArrayListUnmanaged(Expr),
    flags: ExprFlags = .{},
};

pub const IndexExpr = struct {
    base: Expr,
    idx: Expr,
    flags: ExprFlags = .{},
};

pub const MemberExpr = struct {
    base: Expr,
    member_name: []const u8,
    flags: ExprFlags = .{},
};

pub const ParenExpr = struct {
    expr: Expr,
    flags: ExprFlags = .{},
};

pub const ExprFlags = packed struct(u8) {
    can_be_removed_if_unused: bool = false,
    call_can_be_unwrapped_if_unused: bool = false,
    is_constant: bool = false,
    from_pure_function: bool = false,
    _padding: u4 = 0,
};

// =========================================================================
// Statements
// =========================================================================

pub const Stmt = union(enum) {
    compound: *CompoundStmt,
    @"return": *ReturnStmt,
    @"if": *IfStmt,
    @"switch": *SwitchStmt,
    @"for": *ForStmt,
    @"while": *WhileStmt,
    loop: *LoopStmt,
    @"break": *BreakStmt,
    break_if: *BreakIfStmt,
    @"continue": *ContinueStmt,
    discard: *DiscardStmt,
    assign: *AssignStmt,
    incr_decr: *IncrDecrStmt,
    call: *CallStmt,
    decl: *DeclStmt,
};

pub const CompoundStmt = struct {
    stmts: std.ArrayListUnmanaged(Stmt),
};

pub const ReturnStmt = struct {
    value: ?Expr = null,
};

pub const IfStmt = struct {
    condition: Expr,
    body: *CompoundStmt,
    else_branch: ?Stmt = null,
};

pub const SwitchStmt = struct {
    expr: Expr,
    cases: std.ArrayListUnmanaged(SwitchCase),
};

pub const SwitchCase = struct {
    selectors: std.ArrayListUnmanaged(Expr),
    body: *CompoundStmt,
};

pub const ForStmt = struct {
    init_stmt: ?Stmt = null,
    condition: ?Expr = null,
    update: ?Stmt = null,
    body: *CompoundStmt,
};

pub const WhileStmt = struct {
    condition: Expr,
    body: *CompoundStmt,
};

pub const LoopStmt = struct {
    body: *CompoundStmt,
    continuing: ?*CompoundStmt = null,
};

pub const BreakStmt = struct {};

pub const BreakIfStmt = struct {
    condition: Expr,
};

pub const ContinueStmt = struct {};

pub const DiscardStmt = struct {};

pub const AssignStmt = struct {
    op: AssignOp,
    left: Expr,
    right: Expr,
};

pub const AssignOp = enum(u8) {
    simple, // =
    add, // +=
    sub, // -=
    mul, // *=
    div, // /=
    mod, // %=
    @"and", // &=
    @"or", // |=
    xor, // ^=
    shl, // <<=
    shr, // >>=

    pub fn string(self: AssignOp) []const u8 {
        return switch (self) {
            .simple => "=",
            .add => "+=",
            .sub => "-=",
            .mul => "*=",
            .div => "/=",
            .mod => "%=",
            .@"and" => "&=",
            .@"or" => "|=",
            .xor => "^=",
            .shl => "<<=",
            .shr => ">>=",
        };
    }
};

pub const IncrDecrStmt = struct {
    expr: Expr,
    increment: bool, // true = ++, false = --
};

pub const CallStmt = struct {
    call: *CallExpr,
};

pub const DeclStmt = struct {
    decl: Decl,
};

// =========================================================================
// Purity
// =========================================================================

pub const pure_builtins = std.StaticStringMap(void).initComptime(.{
    // Math functions
    .{ "abs", {} },          .{ "acos", {} },         .{ "acosh", {} },
    .{ "asin", {} },         .{ "asinh", {} },        .{ "atan", {} },
    .{ "atanh", {} },        .{ "atan2", {} },        .{ "ceil", {} },
    .{ "clamp", {} },        .{ "cos", {} },          .{ "cosh", {} },
    .{ "cross", {} },        .{ "degrees", {} },      .{ "determinant", {} },
    .{ "distance", {} },     .{ "dot", {} },          .{ "exp", {} },
    .{ "exp2", {} },         .{ "faceForward", {} },  .{ "floor", {} },
    .{ "fma", {} },          .{ "fract", {} },        .{ "frexp", {} },
    .{ "inverseSqrt", {} },  .{ "ldexp", {} },        .{ "length", {} },
    .{ "log", {} },          .{ "log2", {} },         .{ "max", {} },
    .{ "min", {} },          .{ "mix", {} },          .{ "modf", {} },
    .{ "normalize", {} },    .{ "pow", {} },          .{ "quantizeToF16", {} },
    .{ "radians", {} },      .{ "reflect", {} },      .{ "refract", {} },
    .{ "round", {} },        .{ "saturate", {} },     .{ "sign", {} },
    .{ "sin", {} },          .{ "sinh", {} },         .{ "smoothstep", {} },
    .{ "sqrt", {} },         .{ "step", {} },         .{ "tan", {} },
    .{ "tanh", {} },         .{ "transpose", {} },    .{ "trunc", {} },
    // Integer functions
    .{ "countLeadingZeros", {} }, .{ "countOneBits", {} }, .{ "countTrailingZeros", {} },
    .{ "extractBits", {} },  .{ "firstLeadingBit", {} }, .{ "firstTrailingBit", {} },
    .{ "insertBits", {} },   .{ "reverseBits", {} },
    // Logical
    .{ "all", {} },          .{ "any", {} },          .{ "select", {} },
    // Constructors
    .{ "vec2", {} },         .{ "vec3", {} },         .{ "vec4", {} },
    .{ "vec2f", {} },        .{ "vec3f", {} },        .{ "vec4f", {} },
    .{ "vec2i", {} },        .{ "vec3i", {} },        .{ "vec4i", {} },
    .{ "vec2u", {} },        .{ "vec3u", {} },        .{ "vec4u", {} },
    .{ "vec2h", {} },        .{ "vec3h", {} },        .{ "vec4h", {} },
    .{ "mat2x2", {} },       .{ "mat2x3", {} },      .{ "mat2x4", {} },
    .{ "mat3x2", {} },       .{ "mat3x3", {} },      .{ "mat3x4", {} },
    .{ "mat4x2", {} },       .{ "mat4x3", {} },      .{ "mat4x4", {} },
    .{ "mat2x2f", {} },      .{ "mat2x3f", {} },     .{ "mat2x4f", {} },
    .{ "mat3x2f", {} },      .{ "mat3x3f", {} },     .{ "mat3x4f", {} },
    .{ "mat4x2f", {} },      .{ "mat4x3f", {} },     .{ "mat4x4f", {} },
    .{ "mat2x2h", {} },      .{ "mat2x3h", {} },     .{ "mat2x4h", {} },
    .{ "mat3x2h", {} },      .{ "mat3x3h", {} },     .{ "mat3x4h", {} },
    .{ "mat4x2h", {} },      .{ "mat4x3h", {} },     .{ "mat4x4h", {} },
    .{ "array", {} },        .{ "bool", {} },         .{ "i32", {} },
    .{ "u32", {} },          .{ "f32", {} },          .{ "f16", {} },
    // Pack/unpack
    .{ "pack2x16float", {} }, .{ "pack2x16snorm", {} }, .{ "pack2x16unorm", {} },
    .{ "pack4x8snorm", {} }, .{ "pack4x8unorm", {} }, .{ "pack4xI8", {} },
    .{ "pack4xU8", {} },     .{ "pack4xI8Clamp", {} }, .{ "pack4xU8Clamp", {} },
    .{ "unpack2x16float", {} }, .{ "unpack2x16snorm", {} }, .{ "unpack2x16unorm", {} },
    .{ "unpack4x8snorm", {} }, .{ "unpack4x8unorm", {} }, .{ "unpack4xI8", {} },
    .{ "unpack4xU8", {} },
    // Derivatives
    .{ "dpdx", {} },         .{ "dpdxCoarse", {} },   .{ "dpdxFine", {} },
    .{ "dpdy", {} },         .{ "dpdyCoarse", {} },   .{ "dpdyFine", {} },
    .{ "fwidth", {} },       .{ "fwidthCoarse", {} }, .{ "fwidthFine", {} },
});

// =========================================================================
// Tests
// =========================================================================

test "SymbolIndex none is max u32" {
    try std.testing.expectEqual(@as(u32, std.math.maxInt(u32)), @intFromEnum(SymbolIndex.none));
}

test "SymbolIndex valid" {
    const s: SymbolIndex = @enumFromInt(5);
    try std.testing.expect(s.isValid());
    try std.testing.expectEqual(@as(u32, 5), s.index());
}

test "SymbolIndex none is not valid" {
    try std.testing.expect(!SymbolIndex.none.isValid());
}

test "Symbol.Flags packed size" {
    try std.testing.expectEqual(@as(usize, 2), @sizeOf(Symbol.Flags));
}
