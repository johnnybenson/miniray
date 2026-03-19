//! Dead code elimination for WGSL modules.
//!
//! Marks symbols reachable from entry points as live using BFS.
//! If no entry points exist, all symbols are conservatively marked live.

const std = @import("std");
const Ast = @import("Ast.zig");

/// Perform dead code elimination. Returns the number of dead symbols.
pub fn mark(allocator: std.mem.Allocator, module: *Ast.Module) u32 {
    if (module.symbols.items.len == 0) return 0;

    // Build dependency graph
    var deps: std.AutoHashMapUnmanaged(u32, std.ArrayListUnmanaged(u32)) = .empty;
    defer {
        var it = deps.valueIterator();
        while (it.next()) |list| list.deinit(allocator);
        deps.deinit(allocator);
    }
    buildDependencyGraph(allocator, module, &deps);

    // Find entry points
    var entry_points: std.ArrayListUnmanaged(u32) = .empty;
    defer entry_points.deinit(allocator);
    for (module.symbols.items, 0..) |sym, i| {
        if (sym.flags.is_entry_point) {
            entry_points.append(allocator, @intCast(i)) catch {};
        }
    }

    // Conservative: no entry points → mark all live
    if (entry_points.items.len == 0) {
        for (module.symbols.items) |*sym| {
            sym.flags.is_live = true;
        }
        return 0;
    }

    // BFS from entry points
    var visited: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer visited.deinit(allocator);

    var queue: std.ArrayListUnmanaged(u32) = .empty;
    defer queue.deinit(allocator);
    for (entry_points.items) |ep| {
        queue.append(allocator, ep) catch {};
    }

    while (queue.items.len > 0) {
        const idx = queue.orderedRemove(0);
        if (visited.contains(idx)) continue;
        visited.put(allocator, idx, {}) catch {};

        if (idx < module.symbols.items.len) {
            module.symbols.items[idx].flags.is_live = true;
        }

        if (deps.get(idx)) |dep_list| {
            for (dep_list.items) |dep_idx| {
                if (!visited.contains(dep_idx)) {
                    queue.append(allocator, dep_idx) catch {};
                }
            }
        }
    }

    // Count dead
    var dead: u32 = 0;
    for (module.symbols.items) |sym| {
        if (!sym.flags.is_live) dead += 1;
    }
    return dead;
}

fn buildDependencyGraph(allocator: std.mem.Allocator, module: *const Ast.Module, deps: *std.AutoHashMapUnmanaged(u32, std.ArrayListUnmanaged(u32))) void {
    for (module.declarations.items) |decl| {
        collectDeclDeps(allocator, decl, deps);
    }
}

fn collectDeclDeps(allocator: std.mem.Allocator, decl: Ast.Decl, deps: *std.AutoHashMapUnmanaged(u32, std.ArrayListUnmanaged(u32))) void {
    const name_ref = decl.nameRef();
    if (!name_ref.isValid()) return;
    const sym_idx = name_ref.index();

    var refs: std.ArrayListUnmanaged(u32) = .empty;

    switch (decl) {
        .@"const" => |d| {
            if (d.initializer) |init_expr| collectExprRefs(allocator, init_expr, &refs);
            if (d.typ) |t| collectTypeRefs(allocator, t, &refs);
        },
        .override => |d| {
            if (d.initializer) |init_expr| collectExprRefs(allocator, init_expr, &refs);
            if (d.typ) |t| collectTypeRefs(allocator, t, &refs);
        },
        .@"var" => |d| {
            if (d.initializer) |init_expr| collectExprRefs(allocator, init_expr, &refs);
            if (d.typ) |t| collectTypeRefs(allocator, t, &refs);
        },
        .let => |d| {
            if (d.initializer) |init_expr| collectExprRefs(allocator, init_expr, &refs);
            if (d.typ) |t| collectTypeRefs(allocator, t, &refs);
        },
        .function => |d| {
            for (d.parameters.items) |param| collectTypeRefs(allocator, param.typ, &refs);
            if (d.return_type) |rt| collectTypeRefs(allocator, rt, &refs);
            if (d.body) |body| collectStmtRefs(allocator, .{ .compound = body }, &refs);
        },
        .@"struct" => |d| {
            for (d.members.items) |member| collectTypeRefs(allocator, member.typ, &refs);
        },
        .alias => |d| collectTypeRefs(allocator, d.typ, &refs),
        .const_assert => {},
    }

    deps.put(allocator, sym_idx, refs) catch {};
}

fn collectExprRefs(allocator: std.mem.Allocator, expr: Ast.Expr, refs: *std.ArrayListUnmanaged(u32)) void {
    switch (expr) {
        .ident => |e| {
            if (e.ref.isValid()) refs.append(allocator, e.ref.index()) catch {};
        },
        .binary => |e| {
            collectExprRefs(allocator, e.left, refs);
            collectExprRefs(allocator, e.right, refs);
        },
        .unary => |e| collectExprRefs(allocator, e.operand, refs),
        .call => |e| {
            if (e.func) |f| collectExprRefs(allocator, f, refs);
            for (e.args.items) |arg| collectExprRefs(allocator, arg, refs);
        },
        .index => |e| {
            collectExprRefs(allocator, e.base, refs);
            collectExprRefs(allocator, e.idx, refs);
        },
        .member => |e| collectExprRefs(allocator, e.base, refs),
        .paren => |e| collectExprRefs(allocator, e.expr, refs),
        .literal => {},
    }
}

fn collectTypeRefs(allocator: std.mem.Allocator, typ: Ast.Type, refs: *std.ArrayListUnmanaged(u32)) void {
    switch (typ) {
        .ident => |t| {
            if (t.ref.isValid()) refs.append(allocator, t.ref.index()) catch {};
        },
        .vec => |t| { if (t.elem_type) |et| collectTypeRefs(allocator, et, refs); },
        .mat => |t| { if (t.elem_type) |et| collectTypeRefs(allocator, et, refs); },
        .array => |t| {
            if (t.elem_type) |et| collectTypeRefs(allocator, et, refs);
            if (t.size) |s| collectExprRefs(allocator, s, refs);
        },
        .ptr => |t| collectTypeRefs(allocator, t.elem_type, refs),
        .atomic => |t| collectTypeRefs(allocator, t.elem_type, refs),
        .texture => |t| { if (t.sampled_type) |st| collectTypeRefs(allocator, st, refs); },
        .sampler => {},
    }
}

fn collectStmtRefs(allocator: std.mem.Allocator, stmt: Ast.Stmt, refs: *std.ArrayListUnmanaged(u32)) void {
    switch (stmt) {
        .compound => |s| {
            for (s.stmts.items) |inner| collectStmtRefs(allocator, inner, refs);
        },
        .@"return" => |s| {
            if (s.value) |v| collectExprRefs(allocator, v, refs);
        },
        .@"if" => |s| {
            collectExprRefs(allocator, s.condition, refs);
            collectStmtRefs(allocator, .{ .compound = s.body }, refs);
            if (s.else_branch) |eb| collectStmtRefs(allocator, eb, refs);
        },
        .@"switch" => |s| {
            collectExprRefs(allocator, s.expr, refs);
            for (s.cases.items) |c| {
                for (c.selectors.items) |sel| collectExprRefs(allocator, sel, refs);
                collectStmtRefs(allocator, .{ .compound = c.body }, refs);
            }
        },
        .@"for" => |s| {
            if (s.init_stmt) |is| collectStmtRefs(allocator, is, refs);
            if (s.condition) |c| collectExprRefs(allocator, c, refs);
            if (s.update) |u| collectStmtRefs(allocator, u, refs);
            collectStmtRefs(allocator, .{ .compound = s.body }, refs);
        },
        .@"while" => |s| {
            collectExprRefs(allocator, s.condition, refs);
            collectStmtRefs(allocator, .{ .compound = s.body }, refs);
        },
        .loop => |s| {
            collectStmtRefs(allocator, .{ .compound = s.body }, refs);
            if (s.continuing) |c| collectStmtRefs(allocator, .{ .compound = c }, refs);
        },
        .break_if => |s| collectExprRefs(allocator, s.condition, refs),
        .assign => |s| {
            collectExprRefs(allocator, s.left, refs);
            collectExprRefs(allocator, s.right, refs);
        },
        .incr_decr => |s| collectExprRefs(allocator, s.expr, refs),
        .call => |s| {
            if (s.call.func) |f| collectExprRefs(allocator, f, refs);
            for (s.call.args.items) |arg| collectExprRefs(allocator, arg, refs);
        },
        .decl => |s| {
            switch (s.decl) {
                .@"const" => |d| {
                    if (d.initializer) |init_expr| collectExprRefs(allocator, init_expr, refs);
                    if (d.typ) |t| collectTypeRefs(allocator, t, refs);
                },
                .let => |d| {
                    if (d.initializer) |init_expr| collectExprRefs(allocator, init_expr, refs);
                    if (d.typ) |t| collectTypeRefs(allocator, t, refs);
                },
                .@"var" => |d| {
                    if (d.initializer) |init_expr| collectExprRefs(allocator, init_expr, refs);
                    if (d.typ) |t| collectTypeRefs(allocator, t, refs);
                },
                else => {},
            }
        },
        .@"break", .@"continue", .discard => {},
    }
}

/// Check if a declaration is live (for use by printer).
pub fn isDeclarationLive(decl: Ast.Decl, symbols: []const Ast.Symbol) bool {
    const ref = decl.nameRef();
    if (ref == .none) {
        // const_assert is always kept
        return true;
    }
    if (!ref.isValid()) return true;
    const idx = ref.index();
    if (idx >= symbols.len) return true;
    return symbols[idx].flags.is_live;
}
