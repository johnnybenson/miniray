//! WGSL minification pipeline.
//!
//! Orchestrates: Parse → Mark API-facing → DCE → Compute usage → Rename → Print.

const std = @import("std");
const Ast = @import("Ast.zig");
const Lexer = @import("Lexer.zig");
const Parser = @import("Parser.zig");
const Printer = @import("Printer.zig");
const RenamerMod = @import("Renamer.zig");
const Dce = @import("Dce.zig");
const SourceMap = @import("SourceMap.zig");

const Reflect = @import("Reflect.zig");

const Minifier = @This();

pub const SourceMapOptions = struct {
    file: []const u8 = "",
    source_name: []const u8 = "",
    include_source: bool = false,
};

pub const Options = struct {
    minify_whitespace: bool = true,
    minify_identifiers: bool = true,
    minify_syntax: bool = true,
    mangle_external_bindings: bool = false,
    tree_shaking: bool = true,
    preserve_uniform_struct_types: bool = false,
    keep_names: []const []const u8 = &.{},
    generate_source_map: bool = false,
    source_map_options: SourceMapOptions = .{},
};

pub const Result = struct {
    code: []const u8,
    errors: []const Parser.ParseError,
    original_size: usize,
    minified_size: usize,
    symbols_total: usize,
    symbols_dead: u32,
    source_map: ?SourceMap.Result = null,
};

/// Returns default minification options (all minification enabled).
pub fn defaultOptions() Options {
    return .{};
}

/// Minify WGSL source code. Returns the minified code and statistics.
/// The returned code is owned by the arena allocator.
pub fn minify(allocator: std.mem.Allocator, source: [:0]const u8, options: Options) !Result {
    var result = Result{
        .code = "",
        .errors = &.{},
        .original_size = source.len,
        .minified_size = 0,
        .symbols_total = 0,
        .symbols_dead = 0,
    };

    // 1. Tokenize
    var tokens = try Lexer.tokenize(allocator, source);
    defer tokens.deinit(allocator);

    // 2. Parse
    var parser = Parser.init(allocator, source, tokens);
    const module = parser.parse() catch {
        result.code = source;
        result.minified_size = source.len;
        result.errors = parser.errors.items;
        return result;
    };

    if (parser.errors.items.len > 0) {
        result.code = source;
        result.minified_size = source.len;
        result.errors = parser.errors.items;
        return result;
    }

    // 3. Mark API-facing symbols
    markAPIFacingSymbols(module, options);

    // 4. DCE
    if (options.tree_shaking) {
        result.symbols_dead = Dce.mark(allocator, module);
    } else {
        for (module.symbols.items) |*sym| {
            sym.flags.is_live = true;
        }
    }

    // 5. Compute usage
    var uses = computeSymbolUsage(allocator, module);
    defer uses.deinit(allocator);

    // 6. Build reserved names
    var reserved = RenamerMod.computeReservedNames(allocator);
    for (options.keep_names) |name| {
        reserved.put(allocator, name, {}) catch {};
    }

    // 7. Set up source map generator if requested
    const source_map_gen = try initSourceMapGen(allocator, source, options);

    // 8. Create renamer and print
    const print_result = try printWithRenamer(allocator, module, options, &uses, reserved, source_map_gen);
    result.code = print_result.code;

    // 9. Finalize source map
    if (source_map_gen) |gen| {
        result.source_map = gen.generate();
    }

    result.minified_size = result.code.len;
    result.symbols_total = module.symbols.items.len;
    return result;
}

pub const MinifyAndReflectResult = struct {
    minify: Result,
    reflect: Reflect.ReflectResult,
};

/// Minify and reflect in a single pass, sharing the parsed module and renamer.
/// Reflection uses the minified names so callers can map bindings to the
/// minified output.
pub fn minifyAndReflect(allocator: std.mem.Allocator, source: [:0]const u8, options: Options) !MinifyAndReflectResult {
    var result = MinifyAndReflectResult{
        .minify = .{
            .code = "",
            .errors = &.{},
            .original_size = source.len,
            .minified_size = 0,
            .symbols_total = 0,
            .symbols_dead = 0,
        },
        .reflect = .{},
    };

    // 1. Tokenize
    var tokens = try Lexer.tokenize(allocator, source);
    defer tokens.deinit(allocator);

    // 2. Parse
    var parser = Parser.init(allocator, source, tokens);
    const module = parser.parse() catch {
        result.minify.code = source;
        result.minify.minified_size = source.len;
        result.minify.errors = parser.errors.items;
        for (parser.errors.items) |err| {
            result.reflect.errors.append(allocator, err.message) catch {};
        }
        return result;
    };

    if (parser.errors.items.len > 0) {
        result.minify.code = source;
        result.minify.minified_size = source.len;
        result.minify.errors = parser.errors.items;
        for (parser.errors.items) |err| {
            result.reflect.errors.append(allocator, err.message) catch {};
        }
        return result;
    }

    // 3–6. Mark API-facing, DCE, compute usage, build reserved names
    markAPIFacingSymbols(module, options);

    if (options.tree_shaking) {
        result.minify.symbols_dead = Dce.mark(allocator, module);
    } else {
        for (module.symbols.items) |*sym| {
            sym.flags.is_live = true;
        }
    }

    var uses = computeSymbolUsage(allocator, module);
    defer uses.deinit(allocator);

    var reserved = RenamerMod.computeReservedNames(allocator);
    for (options.keep_names) |name| {
        reserved.put(allocator, name, {}) catch {};
    }

    // 7. Source map
    const source_map_gen = try initSourceMapGen(allocator, source, options);

    // 8. Create renamer and print
    const print_result = try printWithRenamer(allocator, module, options, &uses, reserved, source_map_gen);
    result.minify.code = print_result.code;

    // 9. Finalize source map
    if (source_map_gen) |gen| {
        result.minify.source_map = gen.generate();
    }

    result.minify.minified_size = result.minify.code.len;
    result.minify.symbols_total = module.symbols.items.len;

    // 10. Reflect using the same module and renamer
    result.reflect = Reflect.reflectWithRenamer(allocator, module, print_result.renamer);

    return result;
}

fn initSourceMapGen(allocator: std.mem.Allocator, source: [:0]const u8, options: Options) !?*SourceMap.Generator {
    if (!options.generate_source_map) return null;
    const gen = try allocator.create(SourceMap.Generator);
    gen.* = SourceMap.Generator.init(allocator, source);
    gen.setFile(options.source_map_options.file);
    gen.setSourceName(options.source_map_options.source_name);
    gen.setIncludeSource(options.source_map_options.include_source);
    return gen;
}

const PrintResult = struct {
    code: []const u8,
    renamer: *const Printer.Renamer,
};

fn printWithRenamer(
    allocator: std.mem.Allocator,
    module: *Ast.Module,
    options: Options,
    uses: *const std.AutoHashMapUnmanaged(Ast.SymbolIndex, u32),
    reserved: std.StringHashMapUnmanaged(void),
    source_map_gen: ?*SourceMap.Generator,
) !PrintResult {
    if (options.minify_identifiers) {
        const min_renamer = try allocator.create(RenamerMod.MinifyRenamer);
        min_renamer.* = RenamerMod.MinifyRenamer.init(allocator, module.symbols.items, reserved);
        min_renamer.accumulateSymbolUseCounts(uses);
        min_renamer.allocateSlots();
        min_renamer.reserveUnrenamedSymbolNames();
        min_renamer.assignNames();
        // Fix self-referential pointer after heap allocation
        min_renamer.renamer.ptr = @ptrCast(min_renamer);

        var printer = Printer.init(allocator, .{
            .minify_whitespace = options.minify_whitespace,
            .minify_identifiers = true,
            .minify_syntax = options.minify_syntax,
            .tree_shaking = options.tree_shaking,
            .renamer = &min_renamer.renamer,
            .source_map_gen = source_map_gen,
        }, module.symbols.items);
        return .{ .code = try printer.print(module), .renamer = &min_renamer.renamer };
    } else {
        const noop = try allocator.create(RenamerMod.NoOpRenamer);
        noop.* = RenamerMod.NoOpRenamer.init(module.symbols.items);
        // Fix self-referential pointer after heap allocation
        noop.renamer.ptr = @ptrCast(noop);

        var printer = Printer.init(allocator, .{
            .minify_whitespace = options.minify_whitespace,
            .minify_identifiers = false,
            .minify_syntax = options.minify_syntax,
            .tree_shaking = options.tree_shaking,
            .renamer = &noop.renamer,
            .source_map_gen = source_map_gen,
        }, module.symbols.items);
        return .{ .code = try printer.print(module), .renamer = &noop.renamer };
    }
}

fn markAPIFacingSymbols(module: *Ast.Module, options: Options) void {
    for (module.symbols.items) |*sym| {
        if (sym.flags.is_entry_point) sym.flags.must_not_be_renamed = true;
        if (sym.kind == .builtin) sym.flags.must_not_be_renamed = true;
        if (sym.kind == .override) sym.flags.must_not_be_renamed = true;
        if (sym.flags.is_external_binding and !options.mangle_external_bindings) {
            sym.flags.must_not_be_renamed = true;
        }
        // Check keep_names
        for (options.keep_names) |name| {
            if (std.mem.eql(u8, sym.original_name, name)) {
                sym.flags.must_not_be_renamed = true;
                break;
            }
        }
    }

    // Preserve uniform struct types
    if (options.preserve_uniform_struct_types) {
        for (module.declarations.items) |decl| {
            if (decl != .@"var") continue;
            const var_decl = decl.@"var";
            if (!var_decl.name.isValid()) continue;
            const sym = &module.symbols.items[var_decl.name.index()];
            if (!sym.flags.is_external_binding) continue;
            if (var_decl.typ) |typ| {
                if (typ == .ident) {
                    const ident_type = typ.ident;
                    if (ident_type.ref.isValid() and ident_type.ref.index() < module.symbols.items.len) {
                        module.symbols.items[ident_type.ref.index()].flags.must_not_be_renamed = true;
                    }
                }
            }
        }
    }
}

fn computeSymbolUsage(allocator: std.mem.Allocator, module: *const Ast.Module) std.AutoHashMapUnmanaged(Ast.SymbolIndex, u32) {
    var uses: std.AutoHashMapUnmanaged(Ast.SymbolIndex, u32) = .empty;
    for (module.declarations.items) |decl| {
        countDeclUsage(allocator, decl, &uses);
    }
    return uses;
}

fn countDeclUsage(allocator: std.mem.Allocator, decl: Ast.Decl, uses: *std.AutoHashMapUnmanaged(Ast.SymbolIndex, u32)) void {
    switch (decl) {
        .@"const" => |d| {
            if (d.initializer) |init_expr| countExprUsage(allocator, init_expr, uses);
        },
        .override => |d| {
            if (d.initializer) |init_expr| countExprUsage(allocator, init_expr, uses);
        },
        .@"var" => |d| {
            if (d.initializer) |init_expr| countExprUsage(allocator, init_expr, uses);
        },
        .let => |d| {
            if (d.initializer) |init_expr| countExprUsage(allocator, init_expr, uses);
        },
        .function => |d| {
            // Count function name itself
            if (d.name.isValid()) {
                const entry = uses.getOrPutValue(allocator, d.name, 0) catch return;
                entry.value_ptr.* += 1;
            }
            if (d.body) |body| countStmtUsage(allocator, .{ .compound = body }, uses);
        },
        .@"struct", .alias, .const_assert => {},
    }
}

fn countExprUsage(allocator: std.mem.Allocator, expr: Ast.Expr, uses: *std.AutoHashMapUnmanaged(Ast.SymbolIndex, u32)) void {
    switch (expr) {
        .ident => |e| {
            if (e.ref.isValid()) {
                const entry = uses.getOrPutValue(allocator, e.ref, 0) catch return;
                entry.value_ptr.* += 1;
            }
        },
        .binary => |e| {
            countExprUsage(allocator, e.left, uses);
            countExprUsage(allocator, e.right, uses);
        },
        .unary => |e| countExprUsage(allocator, e.operand, uses),
        .call => |e| {
            if (e.func) |f| countExprUsage(allocator, f, uses);
            for (e.args.items) |arg| countExprUsage(allocator, arg, uses);
        },
        .index => |e| {
            countExprUsage(allocator, e.base, uses);
            countExprUsage(allocator, e.idx, uses);
        },
        .member => |e| countExprUsage(allocator, e.base, uses),
        .paren => |e| countExprUsage(allocator, e.expr, uses),
        .literal => {},
    }
}

fn countStmtUsage(allocator: std.mem.Allocator, stmt: Ast.Stmt, uses: *std.AutoHashMapUnmanaged(Ast.SymbolIndex, u32)) void {
    switch (stmt) {
        .compound => |s| {
            for (s.stmts.items) |inner| countStmtUsage(allocator, inner, uses);
        },
        .@"return" => |s| {
            if (s.value) |v| countExprUsage(allocator, v, uses);
        },
        .@"if" => |s| {
            countExprUsage(allocator, s.condition, uses);
            countStmtUsage(allocator, .{ .compound = s.body }, uses);
            if (s.else_branch) |eb| countStmtUsage(allocator, eb, uses);
        },
        .@"switch" => |s| {
            countExprUsage(allocator, s.expr, uses);
            for (s.cases.items) |c| {
                for (c.selectors.items) |sel| countExprUsage(allocator, sel, uses);
                countStmtUsage(allocator, .{ .compound = c.body }, uses);
            }
        },
        .@"for" => |s| {
            if (s.init_stmt) |is| countStmtUsage(allocator, is, uses);
            if (s.condition) |c| countExprUsage(allocator, c, uses);
            if (s.update) |u| countStmtUsage(allocator, u, uses);
            countStmtUsage(allocator, .{ .compound = s.body }, uses);
        },
        .@"while" => |s| {
            countExprUsage(allocator, s.condition, uses);
            countStmtUsage(allocator, .{ .compound = s.body }, uses);
        },
        .loop => |s| {
            countStmtUsage(allocator, .{ .compound = s.body }, uses);
            if (s.continuing) |c| countStmtUsage(allocator, .{ .compound = c }, uses);
        },
        .break_if => |s| countExprUsage(allocator, s.condition, uses),
        .assign => |s| {
            countExprUsage(allocator, s.left, uses);
            countExprUsage(allocator, s.right, uses);
        },
        .incr_decr => |s| countExprUsage(allocator, s.expr, uses),
        .call => |s| {
            if (s.call.func) |f| countExprUsage(allocator, f, uses);
            for (s.call.args.items) |arg| countExprUsage(allocator, arg, uses);
        },
        .decl => |s| countDeclUsage(allocator, s.decl, uses),
        .@"break", .@"continue", .discard => {},
    }
}

test "minify OOM returns error" {
    const source: [:0]const u8 = "fn main() { let x = 1; }";
    // Iterate through allocation failure points
    for (0..50) |fail_at| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
            .fail_index = fail_at,
        });
        const result = minify(failing.allocator(), source, .{});
        if (result) |_| {
            // If it succeeds, we've exhausted failure points
            break;
        } else |_| {
            // Expected: OOM error propagated, no crash
        }
    }
}
