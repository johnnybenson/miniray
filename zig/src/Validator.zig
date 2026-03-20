//! WGSL semantic validator.
//!
//! Performs type checking, symbol resolution validation, control flow analysis,
//! and uniformity analysis to ensure shaders conform to the WGSL specification.
//! Ported from Go's internal/validator/validator.go and uniformity.go.
//!
//! Validation runs in five phases:
//!   1. collectTypeDeclarations — gather struct and alias names
//!   2. resolveStructLayouts  — resolve struct fields and compute layouts
//!   3. validateDeclarations  — validate const/override/var/let decls
//!   4. validateFunctions     — validate functions, statements, expressions
//!   5. analyzeUniformity     — detect non-uniform control flow violations

const std = @import("std");
const Ast = @import("Ast.zig");
const Types = @import("Types.zig");
const Builtins = @import("Builtins.zig");
const Diagnostic = @import("Diagnostic.zig");
const Allocator = std.mem.Allocator;

const Validator = @This();

// =========================================================================
// Public Types
// =========================================================================

/// Shader pipeline stage.
pub const ShaderStage = enum(u8) {
    none,
    vertex,
    fragment,
    compute,

    pub fn string(self: ShaderStage) []const u8 {
        return switch (self) {
            .vertex => "vertex",
            .fragment => "fragment",
            .compute => "compute",
            .none => "none",
        };
    }
};

/// Controls validation behaviour.
pub const Options = struct {
    /// StrictMode treats warnings as errors.
    strict_mode: bool = false,
    /// DiagnosticFilters control which diagnostics are reported.
    diagnostic_filters: ?*Diagnostic.DiagnosticFilter = null,
};

/// Validation result.
pub const Result = struct {
    valid: bool,
    diagnostics: *Diagnostic,
    _arena: ?std.heap.ArenaAllocator = null,

    /// Free all memory owned by this result. After calling deinit,
    /// the diagnostics pointer is invalid.
    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        _ = allocator;
        var arena = self._arena orelse return;
        arena.deinit();
        self._arena = null;
    }
};

// =========================================================================
// Validator State
// =========================================================================

allocator: Allocator,
module: *Ast.Module,
diags: *Diagnostic,
options: Options,

// Current function context
current_func: ?*Ast.FunctionDecl = null,
current_stage: ShaderStage = .none,
in_loop: bool = false,
in_switch: bool = false,
return_type: ?Types.Type = null,
has_return: bool = false,

// Symbol type cache: maps SymbolIndex -> resolved Types.Type
symbol_types: std.AutoHashMapUnmanaged(u32, Types.Type) = .{},

// Struct type cache: maps name -> resolved struct type
struct_types: std.StringHashMapUnmanaged(*Types.Struct) = .{},

// Alias type cache: maps name -> resolved type (null = placeholder)
alias_types: std.StringHashMapUnmanaged(?Types.Type) = .{},

// =========================================================================
// Public API
// =========================================================================

/// Validate a parsed WGSL module.
pub fn validate(allocator: Allocator, module: *Ast.Module, options: Options) Result {
    var diags = allocator.create(Diagnostic) catch {
        // If we cannot even allocate diagnostics, return invalid with a null-ish result.
        // In practice this should never happen.
        const fallback = allocator.create(Diagnostic) catch unreachable;
        fallback.* = Diagnostic.init(allocator, module.source);
        return .{ .valid = false, .diagnostics = fallback };
    };
    diags.* = Diagnostic.init(allocator, module.source);

    var v = Validator{
        .allocator = allocator,
        .module = module,
        .diags = diags,
        .options = options,
    };

    // Phase 1: Collect type declarations (structs, aliases)
    v.collectTypeDeclarations();

    // Phase 2: Resolve struct layouts
    v.resolveStructLayouts();

    // Phase 3: Validate declarations
    v.validateDeclarations();

    // Phase 4: Validate functions and statements
    v.validateFunctions();

    // Phase 5: Uniformity analysis
    v.analyzeUniformity();

    return .{
        .valid = !diags.hasErrors(),
        .diagnostics = diags,
    };
}

// =========================================================================
// Phase 1: Collect Type Declarations
// =========================================================================

fn collectTypeDeclarations(v: *Validator) void {
    for (v.module.declarations.items) |decl| {
        switch (decl) {
            .@"struct" => |d| {
                const name = v.symbolName(d.name);
                if (name.len == 0) continue;
                // Create struct type placeholder
                const st = v.allocator.create(Types.Struct) catch continue;
                st.* = .{
                    .name = name,
                    .fields = &.{},
                    .size_bytes = 0,
                    .align_bytes = 0,
                    .has_runtime_array = false,
                };
                v.struct_types.put(v.allocator, name, st) catch {};
            },
            .alias => |d| {
                const name = v.symbolName(d.name);
                if (name.len == 0) continue;
                // Placeholder — resolved in phase 2
                v.alias_types.put(v.allocator, name, null) catch {};
            },
            else => {},
        }
    }
}

// =========================================================================
// Phase 2: Resolve Struct Layouts
// =========================================================================

fn resolveStructLayouts(v: *Validator) void {
    for (v.module.declarations.items) |decl| {
        switch (decl) {
            .@"struct" => |d| {
                const name = v.symbolName(d.name);
                const st = v.struct_types.get(name) orelse continue;

                // Build fields list
                var fields: std.ArrayListUnmanaged(Types.StructField) = .empty;
                for (d.members.items) |member| {
                    const member_name = v.symbolName(member.name);
                    const member_type = v.resolveType(member.typ) orelse {
                        v.addError(0, "cannot resolve type for struct member");
                        continue;
                    };
                    fields.append(v.allocator, .{
                        .name = member_name,
                        .typ = member_type,
                        .offset = 0,
                    }) catch {};
                }

                st.fields = fields.items;
                st.computeLayout();
            },
            .alias => |d| {
                const name = v.symbolName(d.name);
                const alias_type = v.resolveType(d.typ);
                if (alias_type) |at| {
                    v.alias_types.put(v.allocator, name, at) catch {};
                } else {
                    v.addError(0, "cannot resolve type alias");
                }
            },
            else => {},
        }
    }
}

// =========================================================================
// Phase 3: Validate Declarations
// =========================================================================

fn validateDeclarations(v: *Validator) void {
    for (v.module.declarations.items) |decl| {
        switch (decl) {
            .@"const" => |d| v.validateConstDecl(d),
            .override => |d| v.validateOverrideDecl(d),
            .@"var" => |d| v.validateVarDecl(d),
            .let => |d| v.validateLetDecl(d),
            else => {},
        }
    }
}

fn validateConstDecl(v: *Validator, d: *Ast.ConstDecl) void {
    const name = v.symbolName(d.name);

    // const must have an initializer
    if (d.initializer == null) {
        v.addErrorWithCode(0, Diagnostic.Code.missing_initializer, "const declaration requires an initializer");
        return;
    }

    // Infer or check type
    const init_type = v.checkExpr(d.initializer.?) orelse return;

    var decl_type: ?Types.Type = null;
    if (d.typ) |ast_type| {
        decl_type = v.resolveType(ast_type);
        if (decl_type) |dt| {
            if (!Types.canConvertTo(init_type, dt)) {
                v.addErrorWithCode(0, Diagnostic.Code.type_mismatch, "cannot initialize const with incompatible type");
                return;
            }
        }
    } else {
        decl_type = init_type;
    }

    // const must have constructible type
    if (decl_type) |dt| {
        if (!dt.isConstructible()) {
            v.addErrorWithCode(0, Diagnostic.Code.invalid_const_expr, "const has non-constructible type");
            return;
        }
    }

    _ = name;
    v.setSymbolType(d.name, decl_type);
}

fn validateOverrideDecl(v: *Validator, d: *Ast.OverrideDecl) void {
    // override must be concrete scalar type
    var decl_type: ?Types.Type = null;
    if (d.typ) |ast_type| {
        decl_type = v.resolveType(ast_type);
    } else if (d.initializer) |init| {
        decl_type = v.checkExpr(init);
    }

    if (decl_type == null) {
        v.addErrorWithCode(0, Diagnostic.Code.invalid_override, "cannot determine type for override");
        return;
    }

    const dt = decl_type.?;
    // Must be concrete scalar
    switch (dt) {
        .scalar => |s| {
            if (!s.isConcrete()) {
                v.addErrorWithCode(0, Diagnostic.Code.invalid_override, "override must have concrete scalar type");
                return;
            }
        },
        else => {
            v.addErrorWithCode(0, Diagnostic.Code.invalid_override, "override must have concrete scalar type");
            return;
        },
    }

    if (d.initializer) |init| {
        const init_type = v.checkExpr(init);
        if (init_type) |it| {
            if (!Types.canConvertTo(it, dt)) {
                v.addErrorWithCode(0, Diagnostic.Code.type_mismatch, "cannot initialize override with incompatible type");
            }
        }
    }

    v.setSymbolType(d.name, decl_type);
}

fn validateVarDecl(v: *Validator, d: *Ast.VarDecl) void {
    // Determine type
    var decl_type: ?Types.Type = null;
    if (d.typ) |ast_type| {
        decl_type = v.resolveType(ast_type);
    } else if (d.initializer) |init| {
        decl_type = v.checkExpr(init);
    }

    if (decl_type == null) {
        v.addErrorWithCode(0, Diagnostic.Code.type_mismatch, "cannot determine type for var");
        return;
    }

    const dt = decl_type.?;

    // Validate address space constraints
    v.validateAddressSpace(d, dt);

    // Check initializer compatibility
    if (d.initializer) |init| {
        const init_type = v.checkExpr(init);
        if (init_type) |it| {
            if (!Types.canConvertTo(it, dt)) {
                v.addErrorWithCode(0, Diagnostic.Code.type_mismatch, "cannot initialize var with incompatible type");
            }
        }
    }

    // Check for required @group/@binding on uniform/storage vars
    if (d.address_space == .uniform or d.address_space == .storage) {
        var has_group = false;
        var has_binding = false;
        for (d.attributes.items) |attr| {
            if (std.mem.eql(u8, attr.name, "group")) has_group = true;
            if (std.mem.eql(u8, attr.name, "binding")) has_binding = true;
        }
        if (!has_group or !has_binding) {
            v.addErrorWithCode(0, Diagnostic.Code.missing_binding, "var with address space requires @group and @binding attributes");
        }
    }

    v.setSymbolType(d.name, decl_type);
}

fn validateLetDecl(v: *Validator, d: *Ast.LetDecl) void {
    // let must have an initializer
    if (d.initializer == null) {
        v.addErrorWithCode(0, Diagnostic.Code.missing_initializer, "let declaration requires an initializer");
        return;
    }

    const init_type = v.checkExpr(d.initializer.?) orelse return;

    var decl_type: ?Types.Type = null;
    if (d.typ) |ast_type| {
        decl_type = v.resolveType(ast_type);
        if (decl_type) |dt| {
            if (!Types.canConvertTo(init_type, dt)) {
                v.addErrorWithCode(0, Diagnostic.Code.type_mismatch, "cannot initialize let with incompatible type");
                return;
            }
        }
    } else {
        // Infer type from initializer, converting abstract to concrete
        decl_type = Types.concreteType(init_type);
    }

    v.setSymbolType(d.name, decl_type);
}

fn validateAddressSpace(v: *Validator, d: *Ast.VarDecl, var_type: Types.Type) void {
    switch (d.address_space) {
        .workgroup => {
            if (!var_type.isStorable()) {
                v.addErrorWithCode(0, Diagnostic.Code.invalid_workgroup_var, "workgroup var must have storable type");
            }
        },
        .uniform => {
            if (!var_type.isHostShareable()) {
                v.addErrorWithCode(0, Diagnostic.Code.invalid_uniform_var, "uniform var must have host-shareable type");
            }
            if (d.initializer != null) {
                v.addErrorWithCode(0, Diagnostic.Code.invalid_initializer, "uniform var cannot have an initializer");
            }
        },
        .storage => {
            if (!var_type.isHostShareable()) {
                v.addErrorWithCode(0, Diagnostic.Code.invalid_storage_var, "storage var must have host-shareable type");
            }
            if (d.initializer != null) {
                v.addErrorWithCode(0, Diagnostic.Code.invalid_initializer, "storage var cannot have an initializer");
            }
        },
        else => {},
    }
}

// =========================================================================
// Phase 4: Validate Functions
// =========================================================================

fn validateFunctions(v: *Validator) void {
    for (v.module.declarations.items) |decl| {
        switch (decl) {
            .function => |fn_decl| v.validateFunction(fn_decl),
            else => {},
        }
    }
}

fn validateFunction(v: *Validator, fn_decl: *Ast.FunctionDecl) void {
    v.current_func = fn_decl;
    v.in_loop = false;
    v.in_switch = false;
    v.has_return = false;

    // Determine shader stage
    v.current_stage = .none;
    for (fn_decl.attributes.items) |attr| {
        if (std.mem.eql(u8, attr.name, "vertex")) {
            v.current_stage = .vertex;
        } else if (std.mem.eql(u8, attr.name, "fragment")) {
            v.current_stage = .fragment;
        } else if (std.mem.eql(u8, attr.name, "compute")) {
            v.current_stage = .compute;
        }
    }

    // Resolve return type
    if (fn_decl.return_type) |rt| {
        v.return_type = v.resolveType(rt);
    } else {
        v.return_type = null;
    }

    // Resolve parameter types and build function type
    var param_types: std.ArrayListUnmanaged(Types.Type) = .empty;
    for (fn_decl.parameters.items) |param| {
        const param_type = v.resolveType(param.typ);
        if (param_type) |pt| {
            v.setSymbolType(param.name, pt);
            param_types.append(v.allocator, pt) catch {};
        }
        v.validateParameterAttributes(param);
    }

    // Register function type in symbol_types so calls can resolve it
    if (fn_decl.name.isValid()) {
        const fn_type = Types.functionType(v.allocator, param_types.items, v.return_type) catch null;
        if (fn_type) |ft| {
            v.setSymbolType(fn_decl.name, ft);
        }
    }

    // Validate entry point requirements
    if (v.current_stage != .none) {
        v.validateEntryPoint(fn_decl);
    }

    // Validate function body
    if (fn_decl.body) |body| {
        v.validateCompoundStmt(body);
    }

    // Check for missing return
    if (v.return_type != null and !v.has_return) {
        v.addErrorWithCode(0, Diagnostic.Code.missing_return, "function must return a value");
    }

    v.current_func = null;
    v.return_type = null;
}

fn validateParameterAttributes(v: *Validator, param: Ast.Parameter) void {
    for (param.attributes.items) |attr| {
        if (std.mem.eql(u8, attr.name, "location")) {
            if (v.current_stage == .none) {
                v.addErrorWithCode(0, Diagnostic.Code.invalid_attribute, "@location is only valid on entry point parameters");
            }
        } else if (std.mem.eql(u8, attr.name, "builtin")) {
            if (attr.args.items.len > 0) {
                switch (attr.args.items[0]) {
                    .ident => |ident| {
                        v.validateBuiltinForStage(ident.name, true);
                    },
                    else => {},
                }
            }
        }
    }
}

fn validateEntryPoint(v: *Validator, fn_decl: *Ast.FunctionDecl) void {
    switch (v.current_stage) {
        .vertex => {
            // Must return @builtin(position) vec4<f32>
            // Simplified check — the Go version does a similar partial check
        },
        .fragment => {
            // Fragment can return void or typed output
        },
        .compute => {
            // Must have @workgroup_size
            var has_workgroup_size = false;
            for (fn_decl.attributes.items) |attr| {
                if (std.mem.eql(u8, attr.name, "workgroup_size")) {
                    has_workgroup_size = true;
                    if (attr.args.items.len == 0) {
                        v.addErrorWithCode(0, Diagnostic.Code.invalid_attribute, "@workgroup_size requires at least one argument");
                    }
                }
            }
            if (!has_workgroup_size) {
                v.addErrorWithCode(0, Diagnostic.Code.missing_attribute, "compute entry point requires @workgroup_size attribute");
            }

            // Must not return a value
            if (fn_decl.return_type != null) {
                v.addErrorWithCode(0, Diagnostic.Code.invalid_entry_point, "compute entry point must not return a value");
            }
        },
        .none => {},
    }
}

fn validateBuiltinForStage(v: *Validator, builtin_name: []const u8, is_input: bool) void {
    const valid = switch (v.current_stage) {
        .vertex => if (is_input)
            isVertexInput(builtin_name)
        else
            isVertexOutput(builtin_name),
        .fragment => if (is_input)
            isFragmentInput(builtin_name)
        else
            isFragmentOutput(builtin_name),
        .compute => if (is_input)
            isComputeInput(builtin_name)
        else
            false,
        .none => true, // Not an entry point, skip validation
    };

    if (!valid) {
        v.addErrorWithCode(0, Diagnostic.Code.invalid_builtin, "builtin is not valid for this shader stage");
    }
}

fn isVertexInput(name: []const u8) bool {
    return std.mem.eql(u8, name, "vertex_index") or
        std.mem.eql(u8, name, "instance_index");
}

fn isVertexOutput(name: []const u8) bool {
    return std.mem.eql(u8, name, "position");
}

fn isFragmentInput(name: []const u8) bool {
    return std.mem.eql(u8, name, "position") or
        std.mem.eql(u8, name, "front_facing") or
        std.mem.eql(u8, name, "sample_index") or
        std.mem.eql(u8, name, "sample_mask");
}

fn isFragmentOutput(name: []const u8) bool {
    return std.mem.eql(u8, name, "frag_depth") or
        std.mem.eql(u8, name, "sample_mask");
}

fn isComputeInput(name: []const u8) bool {
    return std.mem.eql(u8, name, "local_invocation_id") or
        std.mem.eql(u8, name, "local_invocation_index") or
        std.mem.eql(u8, name, "global_invocation_id") or
        std.mem.eql(u8, name, "workgroup_id") or
        std.mem.eql(u8, name, "num_workgroups");
}

// =========================================================================
// Statement Validation
// =========================================================================

fn validateStmt(v: *Validator, stmt: Ast.Stmt) void {
    switch (stmt) {
        .compound => |s| v.validateCompoundStmt(s),
        .@"return" => |s| v.validateReturnStmt(s),
        .@"if" => |s| v.validateIfStmt(s),
        .@"switch" => |s| v.validateSwitchStmt(s),
        .loop => |s| v.validateLoopStmt(s),
        .@"while" => |s| v.validateWhileStmt(s),
        .@"for" => |s| v.validateForStmt(s),
        .@"break" => v.validateBreakStmt(),
        .break_if => |s| v.validateBreakIfStmt(s),
        .@"continue" => v.validateContinueStmt(),
        .discard => v.validateDiscardStmt(),
        .assign => |s| v.validateAssignStmt(s),
        .incr_decr => |s| v.validateIncrDecrStmt(s),
        .call => |s| v.validateCallStmt(s),
        .decl => |s| v.validateDeclStmt(s),
    }
}

fn validateCompoundStmt(v: *Validator, s: *Ast.CompoundStmt) void {
    for (s.stmts.items) |stmt| {
        v.validateStmt(stmt);
    }
}

fn validateReturnStmt(v: *Validator, s: *Ast.ReturnStmt) void {
    v.has_return = true;

    if (s.value == null) {
        if (v.return_type != null) {
            v.addErrorWithCode(0, Diagnostic.Code.missing_return, "return statement must return a value");
        }
        return;
    }

    const expr_type = v.checkExpr(s.value.?) orelse return;

    if (v.return_type) |rt| {
        if (!Types.canConvertTo(expr_type, rt)) {
            v.addErrorWithCode(0, Diagnostic.Code.type_mismatch, "cannot return incompatible type");
        }
    } else {
        v.addErrorWithCode(0, Diagnostic.Code.invalid_return, "cannot return a value from a void function");
    }
}

fn validateIfStmt(v: *Validator, s: *Ast.IfStmt) void {
    const cond_type = v.checkExpr(s.condition);
    if (cond_type) |ct| {
        if (!ct.eql(Types.Bool)) {
            v.addErrorWithCode(0, Diagnostic.Code.type_mismatch, "if condition must be bool");
        }
    }

    v.validateCompoundStmt(s.body);
    if (s.else_branch) |else_stmt| {
        v.validateStmt(else_stmt);
    }
}

fn validateSwitchStmt(v: *Validator, s: *Ast.SwitchStmt) void {
    const selector_type = v.checkExpr(s.expr);
    if (selector_type) |st| {
        if (!Types.isInteger(st)) {
            v.addErrorWithCode(0, Diagnostic.Code.type_mismatch, "switch selector must be integer type");
        }
    }

    const prev_in_switch = v.in_switch;
    v.in_switch = true;

    for (s.cases.items) |case| {
        for (case.selectors.items) |sel| {
            const sel_type = v.checkExpr(sel);
            if (sel_type != null and selector_type != null) {
                if (!Types.canConvertTo(sel_type.?, selector_type.?)) {
                    v.addErrorWithCode(0, Diagnostic.Code.type_mismatch, "case selector type doesn't match switch selector type");
                }
            }
        }
        v.validateCompoundStmt(case.body);
    }

    v.in_switch = prev_in_switch;
}

fn validateLoopStmt(v: *Validator, s: *Ast.LoopStmt) void {
    const prev_in_loop = v.in_loop;
    v.in_loop = true;

    v.validateCompoundStmt(s.body);
    if (s.continuing) |cont| {
        v.validateCompoundStmt(cont);
    }

    v.in_loop = prev_in_loop;
}

fn validateWhileStmt(v: *Validator, s: *Ast.WhileStmt) void {
    const cond_type = v.checkExpr(s.condition);
    if (cond_type) |ct| {
        if (!ct.eql(Types.Bool)) {
            v.addErrorWithCode(0, Diagnostic.Code.type_mismatch, "while condition must be bool");
        }
    }

    const prev_in_loop = v.in_loop;
    v.in_loop = true;
    v.validateCompoundStmt(s.body);
    v.in_loop = prev_in_loop;
}

fn validateForStmt(v: *Validator, s: *Ast.ForStmt) void {
    if (s.init_stmt) |init| {
        v.validateStmt(init);
    }
    if (s.condition) |cond| {
        const cond_type = v.checkExpr(cond);
        if (cond_type) |ct| {
            if (!ct.eql(Types.Bool)) {
                v.addErrorWithCode(0, Diagnostic.Code.type_mismatch, "for condition must be bool");
            }
        }
    }
    if (s.update) |update| {
        v.validateStmt(update);
    }

    const prev_in_loop = v.in_loop;
    v.in_loop = true;
    v.validateCompoundStmt(s.body);
    v.in_loop = prev_in_loop;
}

fn validateBreakStmt(v: *Validator) void {
    if (!v.in_loop and !v.in_switch) {
        v.addErrorWithCode(0, Diagnostic.Code.break_outside_loop, "break statement must be inside a loop or switch");
    }
}

fn validateBreakIfStmt(v: *Validator, s: *Ast.BreakIfStmt) void {
    const cond_type = v.checkExpr(s.condition);
    if (cond_type) |ct| {
        if (!ct.eql(Types.Bool)) {
            v.addErrorWithCode(0, Diagnostic.Code.type_mismatch, "break if condition must be bool");
        }
    }
}

fn validateContinueStmt(v: *Validator) void {
    if (!v.in_loop) {
        v.addErrorWithCode(0, Diagnostic.Code.continue_outside_loop, "continue statement must be inside a loop");
    }
}

fn validateDiscardStmt(v: *Validator) void {
    if (v.current_stage != .fragment) {
        v.addErrorWithCode(0, Diagnostic.Code.discard_outside_fragment, "discard statement is only valid in fragment shaders");
    }
}

fn validateAssignStmt(v: *Validator, s: *Ast.AssignStmt) void {
    const lhs_type = v.checkExpr(s.left);
    const rhs_type = v.checkExpr(s.right);

    if (lhs_type == null or rhs_type == null) return;

    if (!Types.canConvertTo(rhs_type.?, lhs_type.?)) {
        v.addErrorWithCode(0, Diagnostic.Code.type_mismatch, "cannot assign incompatible type");
    }
}

fn validateIncrDecrStmt(v: *Validator, s: *Ast.IncrDecrStmt) void {
    const expr_type = v.checkExpr(s.expr) orelse return;
    if (!Types.isInteger(expr_type)) {
        v.addErrorWithCode(0, Diagnostic.Code.type_mismatch, "increment/decrement requires integer type");
    }
}

fn validateCallStmt(v: *Validator, s: *Ast.CallStmt) void {
    _ = v.checkCallExpr(s.call);
}

fn validateDeclStmt(v: *Validator, s: *Ast.DeclStmt) void {
    switch (s.decl) {
        .@"const" => |d| v.validateConstDecl(d),
        .let => |d| v.validateLetDecl(d),
        .@"var" => |d| v.validateVarDecl(d),
        else => {},
    }
}

// =========================================================================
// Expression Type Checking
// =========================================================================

fn checkExpr(v: *Validator, expr: Ast.Expr) ?Types.Type {
    return switch (expr) {
        .literal => |e| v.checkLiteral(e),
        .ident => |e| v.checkIdent(e),
        .binary => |e| v.checkBinary(e),
        .unary => |e| v.checkUnary(e),
        .call => |e| v.checkCallExpr(e),
        .index => |e| v.checkIndex(e),
        .member => |e| v.checkMember(e),
        .paren => |e| v.checkExpr(e.expr),
    };
}

fn checkLiteral(v: *Validator, e: *Ast.LiteralExpr) ?Types.Type {
    _ = v;
    const val = e.value;
    if (val.len == 0) return Types.AbstractInt;

    // Boolean literals
    if (std.mem.eql(u8, val, "true") or std.mem.eql(u8, val, "false")) {
        return Types.Bool;
    }

    // Check for float indicators
    if (hasByteAny(val, ".eE")) {
        if (val[val.len - 1] == 'h') return Types.F16;
        if (val[val.len - 1] == 'f') return Types.F32;
        return Types.AbstractFloat;
    }

    // Suffix-based typing
    if (val[val.len - 1] == 'h') return Types.F16;
    if (val[val.len - 1] == 'f') return Types.F32;
    if (val[val.len - 1] == 'u') return Types.U32;
    if (val[val.len - 1] == 'i') return Types.I32;

    return Types.AbstractInt;
}

fn checkIdent(v: *Validator, e: *Ast.IdentExpr) ?Types.Type {
    // Check if it's a type name being used as expression (constructor)
    if (v.lookupType(e.name)) |t| {
        return t;
    }

    // Check symbol table
    if (e.ref.isValid()) {
        if (v.symbol_types.get(e.ref.index())) |t| {
            return t;
        }
    }

    // Check if it's a builtin function — return null, type comes from call resolution
    if (Builtins.isBuiltin(e.name)) {
        return null;
    }

    // Check if it's a user-defined function (by looking up symbols in module)
    if (e.ref.isValid()) {
        const idx = e.ref.index();
        if (idx < v.module.symbols.items.len) {
            // Symbol exists but no type assigned yet — might be a function
            if (v.module.symbols.items[idx].kind == .function) {
                return null; // Function type resolved at call site
            }
        }
    }

    // Undefined identifier
    v.addErrorWithCode(0, Diagnostic.Code.undefined_symbol, "use of undeclared identifier");
    return null;
}

fn checkBinary(v: *Validator, e: *Ast.BinaryExpr) ?Types.Type {
    const left_type = v.checkExpr(e.left) orelse return null;
    const right_type = v.checkExpr(e.right) orelse return null;

    switch (e.op) {
        .logical_and, .logical_or => {
            if (!left_type.eql(Types.Bool) or !right_type.eql(Types.Bool)) {
                v.addErrorWithCode(0, Diagnostic.Code.invalid_operand, "logical operator requires bool operands");
                return null;
            }
            return Types.Bool;
        },
        .eq, .ne => {
            if (!left_type.eql(right_type) and
                !Types.canConvertTo(left_type, right_type) and
                !Types.canConvertTo(right_type, left_type))
            {
                v.addErrorWithCode(0, Diagnostic.Code.invalid_operand, "comparison requires compatible types");
                return null;
            }
            return Types.Bool;
        },
        .lt, .le, .gt, .ge => {
            if (!Types.isNumeric(left_type) or !Types.isNumeric(right_type)) {
                v.addErrorWithCode(0, Diagnostic.Code.invalid_operand, "relational operator requires numeric operands");
                return null;
            }
            return Types.Bool;
        },
        .add, .sub => {
            const result = Types.addSubResultType(v.allocator, left_type, right_type) catch return null;
            if (result) |r| {
                return r;
            }
            v.addErrorWithCode(0, Diagnostic.Code.invalid_operand, "arithmetic operator requires compatible numeric types");
            return null;
        },
        .mul => {
            const result = Types.multiplyResultType(v.allocator, left_type, right_type) catch return null;
            if (result) |r| {
                return r;
            }
            v.addErrorWithCode(0, Diagnostic.Code.invalid_operand, "multiplication requires compatible types");
            return null;
        },
        .div => {
            const result = Types.divResultType(v.allocator, left_type, right_type) catch return null;
            if (result) |r| {
                return r;
            }
            v.addErrorWithCode(0, Diagnostic.Code.invalid_operand, "division requires compatible numeric types");
            return null;
        },
        .mod => {
            if (!Types.isInteger(left_type) or !Types.isInteger(right_type)) {
                v.addErrorWithCode(0, Diagnostic.Code.invalid_operand, "modulo operator requires integer operands");
                return null;
            }
            return Types.commonType(left_type, right_type);
        },
        .@"and", .@"or", .xor => {
            if (left_type.eql(Types.Bool) and right_type.eql(Types.Bool)) {
                return Types.Bool;
            }
            if (Types.isInteger(left_type) and Types.isInteger(right_type)) {
                return Types.commonType(left_type, right_type);
            }
            v.addErrorWithCode(0, Diagnostic.Code.invalid_operand, "bitwise operator requires integer or bool operands");
            return null;
        },
        .shl, .shr => {
            if (!Types.isInteger(left_type)) {
                v.addErrorWithCode(0, Diagnostic.Code.invalid_operand, "shift operator requires integer left operand");
                return null;
            }
            if (!right_type.eql(Types.U32) and !Types.canConvertTo(right_type, Types.U32)) {
                v.addErrorWithCode(0, Diagnostic.Code.invalid_operand, "shift amount must be u32");
                return null;
            }
            return left_type;
        },
    }
}

fn checkUnary(v: *Validator, e: *Ast.UnaryExpr) ?Types.Type {
    const operand_type = v.checkExpr(e.operand) orelse return null;

    switch (e.op) {
        .neg => {
            if (!Types.isNumeric(operand_type)) {
                v.addErrorWithCode(0, Diagnostic.Code.invalid_operand, "negation requires numeric type");
                return null;
            }
            return operand_type;
        },
        .not => {
            if (!operand_type.eql(Types.Bool)) {
                // Also allow vector<bool>
                if (operand_type == .vector and operand_type.vector.element.kind == .bool) {
                    return operand_type;
                }
                v.addErrorWithCode(0, Diagnostic.Code.invalid_operand, "logical not requires bool");
                return null;
            }
            return Types.Bool;
        },
        .bit_not => {
            if (!Types.isInteger(operand_type)) {
                v.addErrorWithCode(0, Diagnostic.Code.invalid_operand, "bitwise not requires integer type");
                return null;
            }
            return operand_type;
        },
        .deref => {
            switch (operand_type) {
                .pointer => |p| return p.element,
                .reference => |r| return r.element,
                else => {
                    v.addErrorWithCode(0, Diagnostic.Code.invalid_operand, "dereference requires pointer type");
                    return null;
                },
            }
        },
        .addr => {
            // Creates a pointer to the operand (simplified — actual address space detection is complex)
            const p = v.allocator.create(Types.Pointer) catch return null;
            p.* = .{
                .address_space = .function,
                .element = operand_type,
                .access_mode = .read_write,
            };
            return .{ .pointer = p };
        },
    }
}

fn checkCallExpr(v: *Validator, e: *Ast.CallExpr) ?Types.Type {
    // First check if it's a template type constructor
    if (e.template_type) |tt| {
        return v.resolveType(tt);
    }

    // Get callee name
    var callee_name: []const u8 = "";
    if (e.func) |func| {
        switch (func) {
            .ident => |ident| {
                callee_name = ident.name;
            },
            .member => {
                // Method call — simplified, treat as unknown
                callee_name = "";
            },
            else => {
                v.addErrorWithCode(0, Diagnostic.Code.not_callable, "expression is not callable");
                return null;
            },
        }
    }

    // Check argument types
    for (e.args.items) |arg| {
        _ = v.checkExpr(arg);
    }

    // Check if it's a builtin function
    if (Builtins.lookup(callee_name)) |builtin| {
        // Check argument count
        const arg_count: u32 = @intCast(e.args.items.len);
        if (!builtin.checkArgCount(arg_count)) {
            v.addErrorWithCode(0, Diagnostic.Code.invalid_arg_count, "wrong number of arguments for builtin");
            return null;
        }

        // Collect argument types
        var arg_types: [8]?Types.Type = .{null} ** 8;
        const max_check = @min(e.args.items.len, 8);
        for (0..max_check) |i| {
            arg_types[i] = v.checkExpr(e.args.items[i]);
        }

        // Type check arguments based on builtin kind
        switch (builtin.kind) {
            .numeric, .derivative => {
                // Numeric and derivative builtins require numeric arguments
                for (0..max_check) |i| {
                    if (arg_types[i]) |at| {
                        if (!Types.isNumeric(at) and !Types.isFloat(at)) {
                            v.addErrorWithCode(0, Diagnostic.Code.invalid_arg_type, "builtin requires numeric argument");
                            return null;
                        }
                    }
                }
            },
            .logical => {
                // Logical builtins (all, any) require bool args
                if (arg_types[0]) |at| {
                    if (!at.eql(Types.Bool) and !Types.isVector(at)) {
                        v.addErrorWithCode(0, Diagnostic.Code.invalid_arg_type, "builtin requires bool argument");
                        return null;
                    }
                }
            },
            else => {},
        }

        return v.inferBuiltinReturnType(callee_name, e);
    }

    // Check if it's a type constructor
    if (v.lookupType(callee_name)) |t| {
        return v.checkTypeConstructor(e, t);
    }

    // Check if it's a user-defined function
    if (e.func) |func| {
        switch (func) {
            .ident => |ident| {
                if (ident.ref.isValid()) {
                    const idx = ident.ref.index();
                    if (v.symbol_types.get(idx)) |sym_type| {
                        switch (sym_type) {
                            .function => |fn_type| {
                                // Check argument count
                                if (e.args.items.len != fn_type.parameters.len) {
                                    v.addErrorWithCode(0, Diagnostic.Code.invalid_arg_count, "wrong number of arguments");
                                    return null;
                                }
                                // Check argument types
                                for (e.args.items, 0..) |arg, ai| {
                                    if (ai < fn_type.parameters.len) {
                                        const arg_type = v.checkExpr(arg);
                                        if (arg_type) |at| {
                                            const param_type = fn_type.parameters[ai];
                                            if (!at.eql(param_type) and !Types.canConvertTo(at, param_type)) {
                                                v.addErrorWithCode(0, Diagnostic.Code.invalid_arg_type, "argument type mismatch");
                                                return null;
                                            }
                                        }
                                    }
                                }
                                return fn_type.return_type;
                            },
                            else => {
                                // Symbol exists but is not a function
                                v.addErrorWithCode(0, Diagnostic.Code.not_callable, "expression is not a function or type constructor");
                                return null;
                            },
                        }
                    }
                    // Symbol exists but no type — check if it's a function symbol
                    if (idx < v.module.symbols.items.len and
                        v.module.symbols.items[idx].kind == .function)
                    {
                        // User function — check argument count against parameters
                        return null; // Can't fully type-check without function type
                    }
                }

                // Not resolvable — report error
                if (callee_name.len > 0 and !Builtins.isBuiltin(callee_name)) {
                    v.addErrorWithCode(0, Diagnostic.Code.not_callable, "is not a function or type constructor");
                    return null;
                }
            },
            else => {},
        }
    }

    // Unresolved call — if we have a name and it's not a builtin, error
    if (callee_name.len > 0) {
        v.addErrorWithCode(0, Diagnostic.Code.not_callable, "is not a function or type constructor");
    }
    return null;
}

fn inferBuiltinReturnType(v: *Validator, name: []const u8, e: *Ast.CallExpr) ?Types.Type {
    _ = v;
    _ = e;

    // Texture sampling functions return vec4<f32>
    if (std.mem.startsWith(u8, name, "textureSample")) {
        return .{ .vector = &texture_sample_return_vec };
    }
    // textureLoad returns vec4<T> where T depends on texture type
    if (std.mem.eql(u8, name, "textureLoad")) {
        return .{ .vector = &texture_sample_return_vec };
    }
    // textureDimensions returns u32 or vec2<u32> or vec3<u32>
    if (std.mem.eql(u8, name, "textureDimensions")) {
        return Types.U32;
    }
    // textureNumLayers, textureNumLevels, textureNumSamples return u32
    if (std.mem.startsWith(u8, name, "textureNum")) {
        return Types.U32;
    }
    // Atomic operations return the element type
    if (std.mem.startsWith(u8, name, "atomic")) {
        // Simplified — return u32 by default
        return Types.U32;
    }
    // arrayLength returns u32
    if (std.mem.eql(u8, name, "arrayLength")) {
        return Types.U32;
    }
    // Boolean builtins
    if (std.mem.eql(u8, name, "all") or std.mem.eql(u8, name, "any")) {
        return Types.Bool;
    }
    // Barrier builtins return void
    if (std.mem.eql(u8, name, "workgroupBarrier") or
        std.mem.eql(u8, name, "storageBarrier") or
        std.mem.eql(u8, name, "textureBarrier"))
    {
        return Types.Void;
    }
    // Pack/unpack
    if (std.mem.startsWith(u8, name, "pack")) {
        return Types.U32;
    }
    if (std.mem.startsWith(u8, name, "unpack")) {
        return .{ .vector = &texture_sample_return_vec }; // vec4<f32> or vec2<f32>
    }
    // Subgroup builtins — various return types
    if (std.mem.startsWith(u8, name, "subgroup")) {
        return null; // TODO: proper return type inference
    }

    // For numeric builtins (sin, cos, etc.), return type matches first argument
    // TODO: implement proper overload resolution
    return null;
}

// Singleton for texture sample return type (vec4<f32>)
const texture_sample_return_vec = Types.Vector{
    .width = 4,
    .element = Types.scalar_f32_ptr,
};

fn checkTypeConstructor(v: *Validator, e: *Ast.CallExpr, t: Types.Type) ?Types.Type {
    const arg_count = e.args.items.len;

    switch (t) {
        .scalar => {
            if (arg_count != 1) {
                v.addErrorWithCode(0, Diagnostic.Code.invalid_arg_count, "scalar constructor expects 1 argument");
                return null;
            }
            return t;
        },
        .vector => {
            // Vector constructors can take various forms — simplified
            return t;
        },
        .matrix => {
            // Matrix constructors can take columns or scalars
            return t;
        },
        .@"struct" => |st| {
            if (arg_count != st.fields.len) {
                v.addErrorWithCode(0, Diagnostic.Code.invalid_arg_count, "struct constructor argument count mismatch");
                return null;
            }
            return t;
        },
        .array => {
            // Array constructors
            return t;
        },
        else => return t,
    }
}

fn checkIndex(v: *Validator, e: *Ast.IndexExpr) ?Types.Type {
    const base_type = v.checkExpr(e.base) orelse return null;
    const index_type = v.checkExpr(e.idx);

    // Check index type
    if (index_type) |it| {
        if (!Types.isInteger(it)) {
            v.addErrorWithCode(0, Diagnostic.Code.type_mismatch, "array index must be integer type");
        }
    }

    // Get element type
    switch (base_type) {
        .array => |a| return a.element,
        .vector => |ve| return .{ .scalar = ve.element },
        .matrix => |m| {
            // Indexing a matrix gives a column vector
            const col_vec = v.allocator.create(Types.Vector) catch return null;
            col_vec.* = .{ .width = m.rows, .element = m.element };
            return .{ .vector = col_vec };
        },
        .pointer => |p| {
            // Indexing through pointer to array
            switch (p.element) {
                .array => |a| return a.element,
                else => {},
            }
        },
        .reference => |r| {
            switch (r.element) {
                .array => |a| return a.element,
                else => {},
            }
        },
        else => {},
    }

    v.addErrorWithCode(0, Diagnostic.Code.not_indexable, "type is not indexable");
    return null;
}

fn checkMember(v: *Validator, e: *Ast.MemberExpr) ?Types.Type {
    var base_type = v.checkExpr(e.base) orelse return null;

    // Auto-dereference pointers/references
    while (true) {
        switch (base_type) {
            .pointer => |p| base_type = p.element,
            .reference => |r| base_type = r.element,
            else => break,
        }
    }

    switch (base_type) {
        .@"struct" => |st| {
            if (st.getField(e.member_name)) |field| {
                return field.typ;
            }
            v.addErrorWithCode(0, Diagnostic.Code.no_such_member, "struct has no such member");
            return null;
        },
        .vector => |ve| {
            // Swizzle access
            if (e.member_name.len == 1) {
                return .{ .scalar = ve.element };
            }
            // Multi-component swizzle
            if (e.member_name.len >= 2 and e.member_name.len <= 4) {
                const swiz_vec = v.allocator.create(Types.Vector) catch return null;
                swiz_vec.* = .{
                    .width = @intCast(e.member_name.len),
                    .element = ve.element,
                };
                return .{ .vector = swiz_vec };
            }
            v.addErrorWithCode(0, Diagnostic.Code.no_such_member, "invalid swizzle");
            return null;
        },
        else => {
            v.addErrorWithCode(0, Diagnostic.Code.no_such_member, "type has no members");
            return null;
        },
    }
}

// =========================================================================
// Phase 5: Uniformity Analysis
// =========================================================================

fn analyzeUniformity(v: *Validator) void {
    var ua = UniformityAnalyzer{
        .module = v.module,
        .diags = v.diags,
        .allocator = v.allocator,
        .filters = if (v.options.diagnostic_filters) |f| f else null,
    };
    ua.analyze();
}

/// Uniformity analysis detects non-uniform control flow violations.
/// Implements WGSL spec section 15.
const UniformityAnalyzer = struct {
    module: *Ast.Module,
    diags: *Diagnostic,
    allocator: Allocator,
    filters: ?*Diagnostic.DiagnosticFilter,

    // Current function context
    current_func: ?*Ast.FunctionDecl = null,
    current_stage: ShaderStage = .none,

    // Current uniformity state
    state: UniformityState = .uniform,

    // Sources of non-uniformity
    non_uniform_sources: std.ArrayListUnmanaged(NonUniformSource) = .empty,

    const UniformityState = enum(u8) {
        uniform,
        may_be_non_uniform,
        non_uniform,
    };

    const NonUniformSource = struct {
        loc: u32,
        reason: []const u8,
        builtin_name: []const u8,
    };

    fn analyze(ua: *UniformityAnalyzer) void {
        for (ua.module.declarations.items) |decl| {
            switch (decl) {
                .function => |fn_decl| ua.analyzeFunction(fn_decl),
                else => {},
            }
        }
    }

    fn analyzeFunction(ua: *UniformityAnalyzer, fn_decl: *Ast.FunctionDecl) void {
        ua.current_func = fn_decl;
        ua.state = .uniform;
        ua.non_uniform_sources = .empty;

        // Determine shader stage
        ua.current_stage = .none;
        for (fn_decl.attributes.items) |attr| {
            if (std.mem.eql(u8, attr.name, "vertex")) {
                ua.current_stage = .vertex;
            } else if (std.mem.eql(u8, attr.name, "fragment")) {
                ua.current_stage = .fragment;
            } else if (std.mem.eql(u8, attr.name, "compute")) {
                ua.current_stage = .compute;
            }
        }

        // Parameters may introduce non-uniformity
        ua.analyzeParameters(fn_decl.parameters.items);

        // Analyze function body
        if (fn_decl.body) |body| {
            ua.analyzeCompoundStmt(body);
        }

        ua.current_func = null;
    }

    fn analyzeParameters(ua: *UniformityAnalyzer, params: []const Ast.Parameter) void {
        for (params) |param| {
            for (param.attributes.items) |attr| {
                if (std.mem.eql(u8, attr.name, "builtin") and attr.args.items.len > 0) {
                    switch (attr.args.items[0]) {
                        .ident => |ident| {
                            if (isNonUniformBuiltin(ident.name)) {
                                ua.non_uniform_sources.append(ua.allocator, .{
                                    .loc = ident.loc,
                                    .reason = "builtin input is non-uniform",
                                    .builtin_name = ident.name,
                                }) catch {};
                            }
                        },
                        else => {},
                    }
                }
            }
        }
    }

    fn analyzeCompoundStmt(ua: *UniformityAnalyzer, s: *Ast.CompoundStmt) void {
        for (s.stmts.items) |stmt| {
            ua.analyzeStmt(stmt);
        }
    }

    fn analyzeStmt(ua: *UniformityAnalyzer, stmt: Ast.Stmt) void {
        switch (stmt) {
            .compound => |s| ua.analyzeCompoundStmt(s),
            .@"if" => |s| ua.analyzeIfStmt(s),
            .@"switch" => |s| ua.analyzeSwitchStmt(s),
            .loop => |s| ua.analyzeLoopStmt(s),
            .@"while" => |s| ua.analyzeWhileStmt(s),
            .@"for" => |s| ua.analyzeForStmt(s),
            .@"return" => |s| {
                if (s.value) |val| ua.analyzeExpr(val);
            },
            .assign => |s| {
                ua.analyzeExpr(s.left);
                ua.analyzeExpr(s.right);
            },
            .call => |s| ua.analyzeExpr(.{ .call = s.call }),
            .decl => |s| {
                switch (s.decl) {
                    .@"var" => |d| {
                        if (d.initializer) |init| ua.analyzeExpr(init);
                    },
                    .let => |d| {
                        if (d.initializer) |init| ua.analyzeExpr(init);
                    },
                    .@"const" => |d| {
                        if (d.initializer) |init| ua.analyzeExpr(init);
                    },
                    else => {},
                }
            },
            .incr_decr => |s| ua.analyzeExpr(s.expr),
            .break_if => |s| ua.analyzeExpr(s.condition),
            .@"break", .@"continue", .discard => {},
        }
    }

    fn analyzeIfStmt(ua: *UniformityAnalyzer, s: *Ast.IfStmt) void {
        const cond_non_uniform = ua.analyzeExprUniformity(s.condition);

        const prev_state = ua.state;
        if (cond_non_uniform) {
            ua.state = .non_uniform;
        }

        ua.analyzeCompoundStmt(s.body);
        if (s.else_branch) |else_stmt| {
            ua.analyzeStmt(else_stmt);
        }

        ua.state = prev_state;
    }

    fn analyzeSwitchStmt(ua: *UniformityAnalyzer, s: *Ast.SwitchStmt) void {
        const cond_non_uniform = ua.analyzeExprUniformity(s.expr);

        const prev_state = ua.state;
        if (cond_non_uniform) {
            ua.state = .non_uniform;
        }

        for (s.cases.items) |case| {
            for (case.selectors.items) |sel| {
                ua.analyzeExpr(sel);
            }
            ua.analyzeCompoundStmt(case.body);
        }

        ua.state = prev_state;
    }

    fn analyzeLoopStmt(ua: *UniformityAnalyzer, s: *Ast.LoopStmt) void {
        const prev_state = ua.state;
        ua.analyzeCompoundStmt(s.body);
        if (s.continuing) |cont| {
            ua.analyzeCompoundStmt(cont);
        }
        ua.state = prev_state;
    }

    fn analyzeWhileStmt(ua: *UniformityAnalyzer, s: *Ast.WhileStmt) void {
        const cond_non_uniform = ua.analyzeExprUniformity(s.condition);

        const prev_state = ua.state;
        if (cond_non_uniform) {
            ua.state = .non_uniform;
        }
        ua.analyzeCompoundStmt(s.body);
        ua.state = prev_state;
    }

    fn analyzeForStmt(ua: *UniformityAnalyzer, s: *Ast.ForStmt) void {
        if (s.init_stmt) |init| {
            ua.analyzeStmt(init);
        }

        var cond_non_uniform = false;
        if (s.condition) |cond| {
            cond_non_uniform = ua.analyzeExprUniformity(cond);
        }

        const prev_state = ua.state;
        if (cond_non_uniform) {
            ua.state = .non_uniform;
        }

        ua.analyzeCompoundStmt(s.body);

        if (s.update) |update| {
            ua.analyzeStmt(update);
        }

        ua.state = prev_state;
    }

    fn analyzeExpr(ua: *UniformityAnalyzer, expr: Ast.Expr) void {
        switch (expr) {
            .call => |e| ua.analyzeCallExpr(e),
            .binary => |e| {
                ua.analyzeExpr(e.left);
                ua.analyzeExpr(e.right);
            },
            .unary => |e| ua.analyzeExpr(e.operand),
            .index => |e| {
                ua.analyzeExpr(e.base);
                ua.analyzeExpr(e.idx);
            },
            .member => |e| ua.analyzeExpr(e.base),
            .paren => |e| ua.analyzeExpr(e.expr),
            .ident, .literal => {},
        }
    }

    fn analyzeCallExpr(ua: *UniformityAnalyzer, e: *Ast.CallExpr) void {
        var callee_name: []const u8 = "";
        if (e.func) |func| {
            switch (func) {
                .ident => |ident| callee_name = ident.name,
                else => {},
            }
        }

        // Check arguments
        for (e.args.items) |arg| {
            ua.analyzeExpr(arg);
        }

        // Check if this is a builtin that requires uniform control flow
        if (Builtins.lookup(callee_name)) |builtin| {
            if (builtin.requiresUniform() and ua.state != .uniform) {
                ua.reportUniformityError(e, callee_name, builtin.kind);
            }
        }
    }

    fn analyzeExprUniformity(ua: *UniformityAnalyzer, expr: Ast.Expr) bool {
        switch (expr) {
            .ident => |e| {
                // Check if identifier refers to non-uniform source
                for (ua.non_uniform_sources.items) |src| {
                    if (std.mem.eql(u8, src.builtin_name, e.name)) {
                        return true;
                    }
                }
                if (isNonUniformBuiltin(e.name)) {
                    return true;
                }
                return false;
            },
            .call => |e| {
                // Some builtins produce non-uniform results
                var callee_name: []const u8 = "";
                if (e.func) |func| {
                    switch (func) {
                        .ident => |ident| callee_name = ident.name,
                        else => {},
                    }
                }
                if (Builtins.lookup(callee_name)) |builtin| {
                    if (builtin.kind == .texture) {
                        return true; // Simplified
                    }
                }
                for (e.args.items) |arg| {
                    if (ua.analyzeExprUniformity(arg)) {
                        return true;
                    }
                }
                return false;
            },
            .binary => |e| {
                return ua.analyzeExprUniformity(e.left) or ua.analyzeExprUniformity(e.right);
            },
            .unary => |e| return ua.analyzeExprUniformity(e.operand),
            .index => |e| {
                return ua.analyzeExprUniformity(e.base) or ua.analyzeExprUniformity(e.idx);
            },
            .member => |e| return ua.analyzeExprUniformity(e.base),
            .paren => |e| return ua.analyzeExprUniformity(e.expr),
            .literal => return false,
        }
    }

    fn reportUniformityError(ua: *UniformityAnalyzer, e: *Ast.CallExpr, func_name: []const u8, kind: Builtins.Kind) void {
        // Determine the location
        var loc: u32 = 0;
        if (e.func) |func| {
            switch (func) {
                .ident => |ident| loc = ident.loc,
                else => {},
            }
        }

        // Determine the diagnostic rule and code
        var rule: []const u8 = "";
        var code: []const u8 = "";

        switch (kind) {
            .derivative => {
                rule = Diagnostic.rule_derivative_uniformity;
                code = Diagnostic.Code.non_uniform_derivative;
            },
            .synchronization => {
                rule = ""; // Always an error, cannot be filtered
                code = Diagnostic.Code.non_uniform_barrier;
            },
            .texture => {
                rule = Diagnostic.rule_derivative_uniformity;
                code = Diagnostic.Code.non_uniform_texture;
            },
            .subgroup => {
                rule = Diagnostic.rule_subgroup_uniformity;
                code = Diagnostic.Code.non_uniform_subgroup;
            },
            else => return,
        }

        // Check if this rule is filtered
        if (rule.len > 0 and ua.filters != null) {
            if (ua.filters.?.isDisabled(rule)) {
                return;
            }
        }

        // Determine severity
        var severity = Diagnostic.Severity.@"error";
        if (rule.len > 0 and ua.filters != null) {
            severity = ua.filters.?.getSeverity(rule, .@"error");
        }

        // Build message
        const message = switch (kind) {
            .derivative => "derivative function must only be called from uniform control flow",
            .synchronization => "barrier function must only be called from uniform control flow",
            .texture => "texture sampling with implicit LOD must only be called from uniform control flow",
            .subgroup => "subgroup operation requires uniform control flow",
            else => "function requires uniform control flow",
        };

        _ = func_name;

        ua.diags.add(ua.allocator, .{
            .severity = severity,
            .code = code,
            .message = message,
            .range = ua.diags.makeRange(loc, loc + 1),
            .spec_ref = "15",
        });
    }
};

/// Returns true if the builtin input is known to be non-uniform.
fn isNonUniformBuiltin(name: []const u8) bool {
    const non_uniform = std.StaticStringMap(void).initComptime(.{
        .{ "vertex_index", {} },
        .{ "instance_index", {} },
        .{ "position", {} },
        .{ "front_facing", {} },
        .{ "sample_index", {} },
        .{ "sample_mask", {} },
        .{ "local_invocation_id", {} },
        .{ "local_invocation_index", {} },
        .{ "global_invocation_id", {} },
    });
    return non_uniform.has(name);
}

// =========================================================================
// Type Resolution Helpers
// =========================================================================

fn resolveType(v: *Validator, ast_type: Ast.Type) ?Types.Type {
    switch (ast_type) {
        .ident => |t| return v.lookupType(t.name),
        .vec => |t| {
            var elem_scalar: *const Types.Scalar = Types.scalar_f32_ptr;
            if (t.elem_type) |et| {
                if (v.resolveType(et)) |resolved| {
                    switch (resolved) {
                        .scalar => |s| elem_scalar = s,
                        else => {},
                    }
                }
            } else if (t.shorthand.len > 0) {
                elem_scalar = shorthandElement(t.shorthand);
            }
            const result = v.allocator.create(Types.Vector) catch return null;
            result.* = .{ .width = t.size, .element = elem_scalar };
            return .{ .vector = result };
        },
        .mat => |t| {
            var elem_scalar: *const Types.Scalar = Types.scalar_f32_ptr;
            if (t.elem_type) |et| {
                if (v.resolveType(et)) |resolved| {
                    switch (resolved) {
                        .scalar => |s| elem_scalar = s,
                        else => {},
                    }
                }
            } else if (t.shorthand.len > 0) {
                elem_scalar = shorthandElement(t.shorthand);
            }
            const result = v.allocator.create(Types.Matrix) catch return null;
            result.* = .{ .cols = t.cols, .rows = t.rows, .element = elem_scalar };
            return .{ .matrix = result };
        },
        .array => |t| {
            const elem_type = if (t.elem_type) |et| (v.resolveType(et) orelse return null) else return null;
            var count: u32 = 0;
            if (t.size) |size_expr| {
                // Try to evaluate constant expression for array size
                switch (size_expr) {
                    .literal => |lit| {
                        count = std.fmt.parseInt(u32, lit.value, 10) catch 0;
                    },
                    else => {
                        // TODO: Evaluate constant expression for array size
                        count = 0;
                    },
                }
            }
            const result = v.allocator.create(Types.Array) catch return null;
            result.* = .{ .element = elem_type, .count = count };
            return .{ .array = result };
        },
        .ptr => |t| {
            const elem_type = v.resolveType(t.elem_type) orelse return null;
            const result = v.allocator.create(Types.Pointer) catch return null;
            result.* = .{
                .address_space = t.address_space,
                .element = elem_type,
                .access_mode = t.access_mode,
            };
            return .{ .pointer = result };
        },
        .atomic => |t| {
            const elem_type = v.resolveType(t.elem_type) orelse return null;
            switch (elem_type) {
                .scalar => |s| {
                    const result = v.allocator.create(Types.Atomic) catch return null;
                    result.* = .{ .element = s };
                    return .{ .atomic = result };
                },
                else => return null,
            }
        },
        .sampler => |t| {
            const result = v.allocator.create(Types.Sampler) catch return null;
            result.* = .{ .comparison = t.comparison };
            return .{ .sampler = result };
        },
        .texture => |t| {
            var sampled_scalar: ?*const Types.Scalar = null;
            if (t.sampled_type) |st| {
                if (v.resolveType(st)) |resolved| {
                    switch (resolved) {
                        .scalar => |s| sampled_scalar = s,
                        else => {},
                    }
                }
            }
            const result = v.allocator.create(Types.Texture) catch return null;
            result.* = .{
                .kind = astTextureKindToType(t.kind),
                .dimension = astTextureDimToType(t.dimension),
                .sampled_type = sampled_scalar,
                .texel_format = t.texel_format,
                .access_mode = t.access_mode,
            };
            return .{ .texture = result };
        },
    }
}

fn lookupType(v: *Validator, name: []const u8) ?Types.Type {
    // Built-in scalar types
    if (std.mem.eql(u8, name, "bool")) return Types.Bool;
    if (std.mem.eql(u8, name, "i32")) return Types.I32;
    if (std.mem.eql(u8, name, "u32")) return Types.U32;
    if (std.mem.eql(u8, name, "f32")) return Types.F32;
    if (std.mem.eql(u8, name, "f16")) return Types.F16;
    if (std.mem.eql(u8, name, "sampler")) {
        const s = v.allocator.create(Types.Sampler) catch return null;
        s.* = .{ .comparison = false };
        return .{ .sampler = s };
    }
    if (std.mem.eql(u8, name, "sampler_comparison")) {
        const s = v.allocator.create(Types.Sampler) catch return null;
        s.* = .{ .comparison = true };
        return .{ .sampler = s };
    }

    // Vector shorthand (vec2f, vec3i, etc.) and bare constructors (vec2, vec3, vec4)
    if (name.len >= 4 and std.mem.startsWith(u8, name, "vec")) {
        return v.parseVectorShorthand(name);
    }

    // Matrix shorthand (mat2x2f, mat3x3f, etc.) and bare constructors (mat2x2, mat3x3, etc.)
    if (name.len >= 5 and std.mem.startsWith(u8, name, "mat")) {
        return v.parseMatrixShorthand(name);
    }

    // Bare array constructor
    if (std.mem.eql(u8, name, "array")) {
        const arr = v.allocator.create(Types.Array) catch return null;
        arr.* = .{ .element = Types.F32, .count = 0 };
        return .{ .array = arr };
    }

    // Check struct types
    if (v.struct_types.get(name)) |st| {
        return .{ .@"struct" = st };
    }

    // Check type aliases
    if (v.alias_types.get(name)) |maybe_type| {
        return maybe_type;
    }

    return null;
}

fn parseVectorShorthand(v: *Validator, name: []const u8) ?Types.Type {
    if (name.len < 4) return null;

    const size: u8 = switch (name[3]) {
        '2' => 2,
        '3' => 3,
        '4' => 4,
        else => return null,
    };

    var elem: *const Types.Scalar = Types.scalar_f32_ptr;
    if (name.len == 5) {
        elem = switch (name[4]) {
            'i' => Types.scalar_i32_ptr,
            'u' => Types.scalar_u32_ptr,
            'f' => Types.scalar_f32_ptr,
            'h' => Types.scalar_f16_ptr,
            else => return null,
        };
    } else if (name.len == 4) {
        elem = Types.scalar_f32_ptr; // Default to f32
    } else {
        return null;
    }

    const result = v.allocator.create(Types.Vector) catch return null;
    result.* = .{ .width = size, .element = elem };
    return .{ .vector = result };
}

fn parseMatrixShorthand(v: *Validator, name: []const u8) ?Types.Type {
    if (name.len < 6) return null;

    const cols = name[3] -| '0';
    if (name[4] != 'x') return null;
    const rows = name[5] -| '0';

    if (cols < 2 or cols > 4 or rows < 2 or rows > 4) return null;

    var elem: *const Types.Scalar = Types.scalar_f32_ptr;
    if (name.len > 6) {
        elem = switch (name[6]) {
            'f' => Types.scalar_f32_ptr,
            'h' => Types.scalar_f16_ptr,
            else => return null,
        };
    }

    const result = v.allocator.create(Types.Matrix) catch return null;
    result.* = .{ .cols = @intCast(cols), .rows = @intCast(rows), .element = elem };
    return .{ .matrix = result };
}

fn shorthandElement(shorthand: []const u8) *const Types.Scalar {
    if (shorthand.len == 0) return Types.scalar_f32_ptr;
    return switch (shorthand[shorthand.len - 1]) {
        'i' => Types.scalar_i32_ptr,
        'u' => Types.scalar_u32_ptr,
        'f' => Types.scalar_f32_ptr,
        'h' => Types.scalar_f16_ptr,
        else => Types.scalar_f32_ptr,
    };
}

// =========================================================================
// AST Enum Conversions
// =========================================================================

fn astTextureKindToType(kind: Ast.TextureKind) Types.TextureKind {
    return switch (kind) {
        .sampled => .sampled,
        .multisampled => .multisampled,
        .storage => .storage,
        .depth => .depth,
        .depth_multisampled => .depth_multisampled,
        .external => .external,
    };
}

fn astTextureDimToType(dim: Ast.TextureDimension) Types.TextureDimension {
    return switch (dim) {
        .@"1d" => .@"1d",
        .@"2d" => .@"2d",
        .@"2d_array" => .@"2d_array",
        .@"3d" => .@"3d",
        .cube => .cube,
        .cube_array => .cube_array,
    };
}

// =========================================================================
// Internal Helpers
// =========================================================================

fn symbolName(v: *Validator, sym_idx: Ast.SymbolIndex) []const u8 {
    if (!sym_idx.isValid()) return "";
    const idx = sym_idx.index();
    if (idx < v.module.symbols.items.len) {
        return v.module.symbols.items[idx].original_name;
    }
    return "";
}

fn setSymbolType(v: *Validator, sym_idx: Ast.SymbolIndex, typ: ?Types.Type) void {
    if (!sym_idx.isValid()) return;
    if (typ) |t| {
        v.symbol_types.put(v.allocator, sym_idx.index(), t) catch {};
    }
}

fn addError(v: *Validator, offset: u32, message: []const u8) void {
    v.diags.addError(v.allocator, offset, message);
}

fn addErrorWithCode(v: *Validator, offset: u32, code: []const u8, message: []const u8) void {
    v.diags.addErrorWithCode(v.allocator, offset, code, message);
}

fn addWarning(v: *Validator, offset: u32, message: []const u8) void {
    if (v.options.strict_mode) {
        v.diags.addError(v.allocator, offset, message);
    } else {
        v.diags.addWarning(v.allocator, offset, message);
    }
}

/// Check if a byte slice contains any of the given bytes.
fn hasByteAny(s: []const u8, chars: []const u8) bool {
    for (s) |c| {
        for (chars) |ch| {
            if (c == ch) return true;
        }
    }
    return false;
}

// =========================================================================
// Tests
// =========================================================================

test "ShaderStage string" {
    try std.testing.expectEqualStrings("vertex", ShaderStage.vertex.string());
    try std.testing.expectEqualStrings("fragment", ShaderStage.fragment.string());
    try std.testing.expectEqualStrings("compute", ShaderStage.compute.string());
    try std.testing.expectEqualStrings("none", ShaderStage.none.string());
}

test "isNonUniformBuiltin" {
    try std.testing.expect(isNonUniformBuiltin("vertex_index"));
    try std.testing.expect(isNonUniformBuiltin("instance_index"));
    try std.testing.expect(isNonUniformBuiltin("position"));
    try std.testing.expect(isNonUniformBuiltin("front_facing"));
    try std.testing.expect(isNonUniformBuiltin("sample_index"));
    try std.testing.expect(isNonUniformBuiltin("local_invocation_id"));
    try std.testing.expect(isNonUniformBuiltin("global_invocation_id"));
    // Uniform builtins
    try std.testing.expect(!isNonUniformBuiltin("workgroup_id"));
    try std.testing.expect(!isNonUniformBuiltin("num_workgroups"));
    try std.testing.expect(!isNonUniformBuiltin("not_a_builtin"));
}

test "isVertexInput" {
    try std.testing.expect(isVertexInput("vertex_index"));
    try std.testing.expect(isVertexInput("instance_index"));
    try std.testing.expect(!isVertexInput("position"));
}

test "isFragmentInput" {
    try std.testing.expect(isFragmentInput("position"));
    try std.testing.expect(isFragmentInput("front_facing"));
    try std.testing.expect(isFragmentInput("sample_index"));
    try std.testing.expect(!isFragmentInput("vertex_index"));
}

test "isComputeInput" {
    try std.testing.expect(isComputeInput("local_invocation_id"));
    try std.testing.expect(isComputeInput("global_invocation_id"));
    try std.testing.expect(isComputeInput("workgroup_id"));
    try std.testing.expect(isComputeInput("num_workgroups"));
    try std.testing.expect(!isComputeInput("position"));
}

test "shorthandElement" {
    try std.testing.expectEqual(Types.ScalarKind.i32, shorthandElement("vec3i").kind);
    try std.testing.expectEqual(Types.ScalarKind.u32, shorthandElement("vec4u").kind);
    try std.testing.expectEqual(Types.ScalarKind.f32, shorthandElement("vec2f").kind);
    try std.testing.expectEqual(Types.ScalarKind.f16, shorthandElement("mat3x3h").kind);
    try std.testing.expectEqual(Types.ScalarKind.f32, shorthandElement("").kind);
}

test "hasByteAny" {
    try std.testing.expect(hasByteAny("hello.world", ".eE"));
    try std.testing.expect(hasByteAny("1e5", ".eE"));
    try std.testing.expect(hasByteAny("3.14", ".eE"));
    try std.testing.expect(!hasByteAny("42", ".eE"));
    try std.testing.expect(!hasByteAny("", ".eE"));
}

test "validate empty module" {
    const allocator = std.testing.allocator;
    var scope = Ast.Scope.init(null);
    var module = Ast.Module.init(&scope, "");
    const result = validate(allocator, &module, .{});
    defer allocator.destroy(result.diagnostics);
    defer result.diagnostics.deinit(allocator);
    try std.testing.expect(result.valid);
    try std.testing.expect(!result.diagnostics.hasErrors());
}
