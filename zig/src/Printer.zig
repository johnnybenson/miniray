//! WGSL code printer.
//!
//! Walks the AST and emits WGSL text. Supports minified and pretty output.
//! The needs_space flag prevents token merging (e.g., > and = → >=).

const std = @import("std");
const Ast = @import("Ast.zig");
const Dce = @import("Dce.zig");
const SourceMap = @import("SourceMap.zig");

const Printer = @This();

pub const Options = struct {
    minify_whitespace: bool = false,
    minify_identifiers: bool = false,
    minify_syntax: bool = false,
    tree_shaking: bool = false,
    renamer: ?*const Renamer = null,
    source_map_gen: ?*SourceMap.Generator = null,
};

pub const Renamer = struct {
    ptr: *const anyopaque,
    nameForSymbolFn: *const fn (*const anyopaque, Ast.SymbolIndex) []const u8,

    pub fn nameForSymbol(self: *const Renamer, ref: Ast.SymbolIndex) []const u8 {
        return self.nameForSymbolFn(self.ptr, ref);
    }
};

options: Options,
symbols: []const Ast.Symbol,
allocator: std.mem.Allocator,
buf: std.ArrayListUnmanaged(u8) = .empty,
indent: u32 = 0,
needs_space: bool = false,
output_line: u32 = 0,
output_col: u32 = 0,

pub fn init(allocator: std.mem.Allocator, options: Options, symbols: []const Ast.Symbol) Printer {
    return .{
        .options = options,
        .symbols = symbols,
        .allocator = allocator,
    };
}

pub fn deinit(self: *Printer) void {
    self.buf.deinit(self.allocator);
}

pub fn print(self: *Printer, module: *const Ast.Module) ![]const u8 {
    self.buf.clearRetainingCapacity();
    try self.printModule(module);
    return self.buf.items;
}

// =========================================================================
// Output helpers
// =========================================================================

fn emit(self: *Printer, s: []const u8) !void {
    try self.buf.appendSlice(self.allocator, s);
    self.updatePosition(s);
    self.needs_space = false;
}

fn emitByte(self: *Printer, c: u8) !void {
    try self.buf.append(self.allocator, c);
    if (c == '\n') {
        self.output_line += 1;
        self.output_col = 0;
    } else {
        self.output_col += 1;
    }
    self.needs_space = false;
}

fn emitSpace(self: *Printer) !void {
    if (!self.options.minify_whitespace) {
        try self.buf.append(self.allocator, ' ');
        self.output_col += 1;
    } else if (self.needs_space) {
        try self.buf.append(self.allocator, ' ');
        self.output_col += 1;
    }
    self.needs_space = false;
}

fn emitNewline(self: *Printer) !void {
    if (!self.options.minify_whitespace) {
        try self.buf.append(self.allocator, '\n');
        self.output_line += 1;
        self.output_col = 0;
        var i: u32 = 0;
        while (i < self.indent) : (i += 1) {
            try self.buf.appendSlice(self.allocator, "    ");
            self.output_col += 4;
        }
    }
    self.needs_space = false;
}

fn emitSemicolon(self: *Printer) !void {
    try self.emit(";");
    try self.emitNewline();
}

fn emitName(self: *Printer, ref: Ast.SymbolIndex) !void {
    if (!ref.isValid()) return;
    const idx = ref.index();
    if (idx >= self.symbols.len) return;
    const sym = &self.symbols[idx];

    // Record source map mapping before printing
    if (self.options.source_map_gen) |gen| {
        var original_name: []const u8 = "";
        if (self.options.minify_identifiers) {
            if (self.options.renamer) |ren| {
                const renamed = ren.nameForSymbol(ref);
                if (!std.mem.eql(u8, renamed, sym.original_name)) {
                    original_name = sym.original_name;
                }
            }
        }
        gen.addMapping(self.output_line, self.output_col, sym.loc, original_name);
    }

    if (self.options.minify_identifiers) {
        if (self.options.renamer) |ren| {
            try self.emit(ren.nameForSymbol(ref));
            return;
        }
    }
    try self.emit(sym.original_name);
}

fn updatePosition(self: *Printer, s: []const u8) void {
    for (s) |c| {
        if (c == '\n') {
            self.output_line += 1;
            self.output_col = 0;
        } else {
            self.output_col += 1;
        }
    }
}

// =========================================================================
// Module
// =========================================================================

fn printModule(self: *Printer, m: *const Ast.Module) !void {
    for (m.directives.items) |dir| {
        try self.printDirective(dir);
    }
    if (m.directives.items.len > 0 and m.declarations.items.len > 0) {
        try self.emitNewline();
    }

    // Filter live declarations
    for (m.declarations.items) |decl| {
        if (!self.options.tree_shaking or Dce.isDeclarationLive(decl, self.symbols)) {
            try self.printDecl(decl);
        }
    }
}

fn printDirective(self: *Printer, d: Ast.Directive) !void {
    switch (d) {
        .enable => |dir| {
            try self.emit("enable ");
            for (dir.features.items, 0..) |feat, i| {
                if (i > 0) { try self.emit(","); try self.emitSpace(); }
                try self.emit(feat);
            }
            try self.emitSemicolon();
        },
        .requires => |dir| {
            try self.emit("requires ");
            for (dir.features.items, 0..) |feat, i| {
                if (i > 0) { try self.emit(","); try self.emitSpace(); }
                try self.emit(feat);
            }
            try self.emitSemicolon();
        },
        .diagnostic => |dir| {
            try self.emit("diagnostic(");
            try self.emit(dir.severity);
            try self.emit(",");
            try self.emitSpace();
            try self.emit(dir.rule);
            try self.emit(")");
            try self.emitSemicolon();
        },
    }
}

// =========================================================================
// Declarations
// =========================================================================

fn printDecl(self: *Printer, d: Ast.Decl) !void {
    switch (d) {
        .@"const" => |decl| {
            try self.emit("const ");
            try self.emitName(decl.name);
            if (decl.typ) |t| { try self.emit(":"); try self.emitSpace(); try self.printType(t); }
            try self.emitSpace(); try self.emit("="); try self.emitSpace();
            if (decl.initializer) |init_expr| try self.printExpr(init_expr);
            try self.emitSemicolon();
        },
        .override => |decl| {
            try self.printAttributes(decl.attributes.items);
            try self.emit("override ");
            try self.emitName(decl.name);
            if (decl.typ) |t| { try self.emit(":"); try self.emitSpace(); try self.printType(t); }
            if (decl.initializer) |init_expr| {
                try self.emitSpace(); try self.emit("="); try self.emitSpace();
                try self.printExpr(init_expr);
            }
            try self.emitSemicolon();
        },
        .@"var" => |decl| {
            try self.printAttributes(decl.attributes.items);
            try self.emit("var");
            if (decl.address_space != .none) {
                try self.emit("<");
                try self.emit(decl.address_space.string());
                if (decl.access_mode != .none) {
                    try self.emit(","); try self.emitSpace();
                    try self.emit(decl.access_mode.string());
                }
                try self.emit(">");
            }
            try self.emit(" ");
            try self.emitName(decl.name);
            if (decl.typ) |t| { try self.emit(":"); try self.emitSpace(); try self.printType(t); }
            if (decl.initializer) |init_expr| {
                try self.emitSpace(); try self.emit("="); try self.emitSpace();
                try self.printExpr(init_expr);
            }
            try self.emitSemicolon();
        },
        .let => |decl| {
            try self.emit("let ");
            try self.emitName(decl.name);
            if (decl.typ) |t| { try self.emit(":"); try self.emitSpace(); try self.printType(t); }
            try self.emitSpace(); try self.emit("="); try self.emitSpace();
            if (decl.initializer) |init_expr| try self.printExpr(init_expr);
            try self.emitSemicolon();
        },
        .function => |decl| {
            try self.printAttributes(decl.attributes.items);
            try self.emit("fn ");
            try self.emitName(decl.name);
            try self.emit("(");
            for (decl.parameters.items, 0..) |param, i| {
                if (i > 0) { try self.emit(","); try self.emitSpace(); }
                try self.printAttributes(param.attributes.items);
                try self.emitName(param.name);
                try self.emit(":"); try self.emitSpace();
                try self.printType(param.typ);
            }
            try self.emit(")");
            if (decl.return_type) |rt| {
                try self.emitSpace(); try self.emit("->"); try self.emitSpace();
                try self.printAttributes(decl.return_attr.items);
                try self.printType(rt);
            }
            try self.emitSpace();
            if (decl.body) |body| try self.printCompoundStmt(body);
            try self.emitNewline();
        },
        .@"struct" => |decl| {
            try self.emit("struct ");
            try self.emitName(decl.name);
            try self.emitSpace();
            try self.emit("{");
            self.indent += 1;
            for (decl.members.items, 0..) |member, i| {
                try self.emitNewline();
                try self.printAttributes(member.attributes.items);
                try self.emitName(member.name);
                try self.emit(":"); try self.emitSpace();
                try self.printType(member.typ);
                if (i < decl.members.items.len - 1) try self.emit(",");
            }
            self.indent -= 1;
            try self.emitNewline();
            try self.emit("}");
            try self.emitNewline();
        },
        .alias => |decl| {
            try self.emit("alias ");
            try self.emitName(decl.name);
            try self.emitSpace(); try self.emit("="); try self.emitSpace();
            try self.printType(decl.typ);
            try self.emitSemicolon();
        },
        .const_assert => |decl| {
            try self.emit("const_assert ");
            try self.printExpr(decl.expr);
            try self.emitSemicolon();
        },
    }
}

fn printAttributes(self: *Printer, attrs: []const Ast.Attribute) !void {
    for (attrs) |attr| {
        try self.emit("@");
        try self.emit(attr.name);
        if (attr.args.items.len > 0) {
            try self.emit("(");
            for (attr.args.items, 0..) |arg, i| {
                if (i > 0) { try self.emit(","); try self.emitSpace(); }
                try self.printExpr(arg);
            }
            try self.emit(")");
        }
        self.needs_space = true;
        try self.emitSpace();
    }
}

// =========================================================================
// Types
// =========================================================================

fn printType(self: *Printer, t: Ast.Type) error{OutOfMemory}!void {
    switch (t) {
        .ident => |typ| {
            if (typ.ref.isValid()) {
                try self.emitName(typ.ref);
            } else {
                try self.emit(typ.name);
            }
        },
        .vec => |typ| {
            if (typ.shorthand.len > 0) {
                try self.emit(typ.shorthand);
            } else {
                try self.emit("vec");
                try self.emitByte('0' + typ.size);
                try self.emit("<");
                if (typ.elem_type) |et| try self.printType(et);
                try self.emit(">");
                self.needs_space = true;
            }
        },
        .mat => |typ| {
            if (typ.shorthand.len > 0) {
                try self.emit(typ.shorthand);
            } else {
                try self.emit("mat");
                try self.emitByte('0' + typ.cols);
                try self.emit("x");
                try self.emitByte('0' + typ.rows);
                try self.emit("<");
                if (typ.elem_type) |et| try self.printType(et);
                try self.emit(">");
                self.needs_space = true;
            }
        },
        .array => |typ| {
            try self.emit("array<");
            if (typ.elem_type) |et| try self.printType(et);
            if (typ.size) |s| { try self.emit(","); try self.emitSpace(); try self.printExpr(s); }
            try self.emit(">");
            self.needs_space = true;
        },
        .ptr => |typ| {
            try self.emit("ptr<");
            try self.emit(typ.address_space.string());
            try self.emit(","); try self.emitSpace();
            try self.printType(typ.elem_type);
            if (typ.access_mode != .none) {
                try self.emit(","); try self.emitSpace();
                try self.emit(typ.access_mode.string());
            }
            try self.emit(">");
            self.needs_space = true;
        },
        .atomic => |typ| {
            try self.emit("atomic<");
            try self.printType(typ.elem_type);
            try self.emit(">");
            self.needs_space = true;
        },
        .sampler => |typ| {
            if (typ.comparison) {
                try self.emit("sampler_comparison");
            } else {
                try self.emit("sampler");
            }
        },
        .texture => |typ| try self.printTextureType(typ),
    }
}

fn printTextureType(self: *Printer, t: *const Ast.TextureType) !void {
    const prefix: []const u8 = switch (t.kind) {
        .sampled => "texture_",
        .multisampled => "texture_multisampled_",
        .storage => "texture_storage_",
        .depth => "texture_depth_",
        .depth_multisampled => "texture_depth_multisampled_",
        .external => {
            try self.emit("texture_external");
            return;
        },
    };
    try self.emit(prefix);
    try self.emit(switch (t.dimension) {
        .@"1d" => "1d",
        .@"2d" => "2d",
        .@"2d_array" => "2d_array",
        .@"3d" => "3d",
        .cube => "cube",
        .cube_array => "cube_array",
    });

    if (t.sampled_type) |st| {
        try self.emit("<"); try self.printType(st); try self.emit(">");
        self.needs_space = true;
    } else if (t.texel_format.len > 0) {
        try self.emit("<"); try self.emit(t.texel_format);
        try self.emit(","); try self.emitSpace();
        try self.emit(t.access_mode.string());
        try self.emit(">");
        self.needs_space = true;
    }
}

// =========================================================================
// Expressions
// =========================================================================

fn printExpr(self: *Printer, e: Ast.Expr) !void {
    switch (e) {
        .ident => |expr| {
            if (expr.ref.isValid()) {
                try self.emitName(expr.ref);
            } else {
                try self.emit(expr.name);
            }
        },
        .literal => |expr| try self.emit(expr.value),
        .binary => |expr| {
            try self.printExpr(expr.left);
            try self.emitSpace();
            try self.emit(expr.op.string());
            try self.emitSpace();
            try self.printExpr(expr.right);
        },
        .unary => |expr| {
            try self.emit(expr.op.string());
            try self.printExpr(expr.operand);
        },
        .call => |expr| {
            if (expr.template_type) |tt| {
                try self.printType(tt);
            } else if (expr.func) |f| {
                try self.printExpr(f);
            }
            try self.emit("(");
            for (expr.args.items, 0..) |arg, i| {
                if (i > 0) { try self.emit(","); try self.emitSpace(); }
                try self.printExpr(arg);
            }
            try self.emit(")");
        },
        .index => |expr| {
            try self.printExpr(expr.base);
            try self.emit("["); try self.printExpr(expr.idx); try self.emit("]");
        },
        .member => |expr| {
            try self.printExpr(expr.base);
            try self.emit("."); try self.emit(expr.member_name);
        },
        .paren => |expr| {
            try self.emit("("); try self.printExpr(expr.expr); try self.emit(")");
        },
    }
}

// =========================================================================
// Statements
// =========================================================================

fn printCompoundStmt(self: *Printer, stmt: *const Ast.CompoundStmt) !void {
    try self.emit("{");
    self.indent += 1;
    for (stmt.stmts.items) |s| {
        try self.emitNewline();
        try self.printStmt(s);
    }
    self.indent -= 1;
    try self.emitNewline();
    try self.emit("}");
}

fn printStmt(self: *Printer, s: Ast.Stmt) error{OutOfMemory}!void {
    switch (s) {
        .compound => |stmt| {
            try self.emit("{");
            self.indent += 1;
            for (stmt.stmts.items) |sub| {
                try self.emitNewline();
                try self.printStmt(sub);
            }
            self.indent -= 1;
            try self.emitNewline();
            try self.emit("}");
        },
        .@"return" => |stmt| {
            try self.emit("return");
            if (stmt.value) |v| { try self.emit(" "); try self.printExpr(v); }
            try self.emit(";");
        },
        .@"if" => |stmt| try self.printIfStmt(stmt),
        .@"switch" => |stmt| {
            try self.emit("switch ");
            try self.printExpr(stmt.expr);
            try self.emitSpace(); try self.emit("{");
            self.indent += 1;
            for (stmt.cases.items) |c| {
                try self.emitNewline();
                if (c.selectors.items.len == 0) {
                    try self.emit("default");
                } else {
                    try self.emit("case ");
                    for (c.selectors.items, 0..) |sel, i| {
                        if (i > 0) { try self.emit(","); try self.emitSpace(); }
                        try self.printExpr(sel);
                    }
                }
                try self.emit(":"); try self.emitSpace();
                try self.printCompoundStmt(c.body);
            }
            self.indent -= 1;
            try self.emitNewline(); try self.emit("}");
        },
        .@"for" => |stmt| try self.printForStmt(stmt),
        .@"while" => |stmt| {
            try self.emit("while ");
            try self.printExpr(stmt.condition);
            try self.emitSpace();
            try self.printCompoundStmt(stmt.body);
        },
        .loop => |stmt| {
            try self.emit("loop"); try self.emitSpace();
            try self.printCompoundStmt(stmt.body);
            if (stmt.continuing) |c| {
                try self.emit(" continuing"); try self.emitSpace();
                try self.printCompoundStmt(c);
            }
        },
        .@"break" => try self.emit("break;"),
        .break_if => |stmt| {
            try self.emit("break if ");
            try self.printExpr(stmt.condition);
            try self.emit(";");
        },
        .@"continue" => try self.emit("continue;"),
        .discard => try self.emit("discard;"),
        .assign => |stmt| {
            try self.printExpr(stmt.left); try self.emitSpace();
            try self.emit(stmt.op.string()); try self.emitSpace();
            try self.printExpr(stmt.right); try self.emit(";");
        },
        .incr_decr => |stmt| {
            try self.printExpr(stmt.expr);
            if (stmt.increment) try self.emit("++") else try self.emit("--");
            try self.emit(";");
        },
        .call => |stmt| {
            try self.printExpr(.{ .call = stmt.call });
            try self.emit(";");
        },
        .decl => |stmt| try self.printDeclStmt(stmt.decl),
    }
}

fn printIfStmt(self: *Printer, stmt: *const Ast.IfStmt) !void {
    try self.emit("if ");
    try self.printExpr(stmt.condition);
    try self.emitSpace();
    try self.printCompoundStmt(stmt.body);
    if (stmt.else_branch) |eb| {
        switch (eb) {
            .@"if" => |else_if| {
                try self.emit(" else if ");
                try self.printExpr(else_if.condition);
                try self.emitSpace();
                try self.printCompoundStmt(else_if.body);
                if (else_if.else_branch) |eb2| {
                    try self.printElseChain(eb2);
                }
            },
            else => {
                try self.emit(" else"); try self.emitSpace();
                try self.printStmt(eb);
            },
        }
    }
}

fn printElseChain(self: *Printer, s: Ast.Stmt) !void {
    if (s == .@"if") {
        const if_stmt = s.@"if";
        try self.emit(" else if ");
        try self.printExpr(if_stmt.condition);
        try self.emitSpace();
        try self.printCompoundStmt(if_stmt.body);
        if (if_stmt.else_branch) |eb| try self.printElseChain(eb);
    } else {
        try self.emit(" else"); try self.emitSpace();
        try self.printStmt(s);
    }
}

fn printForStmt(self: *Printer, stmt: *const Ast.ForStmt) !void {
    try self.emit("for"); try self.emitSpace(); try self.emit("(");
    if (stmt.init_stmt) |is| try self.printForInit(is);
    try self.emit(";"); try self.emitSpace();
    if (stmt.condition) |c| try self.printExpr(c);
    try self.emit(";"); try self.emitSpace();
    if (stmt.update) |u| try self.printForUpdate(u);
    try self.emit(")"); try self.emitSpace();
    try self.printCompoundStmt(stmt.body);
}

fn printForInit(self: *Printer, s: Ast.Stmt) !void {
    switch (s) {
        .decl => |ds| {
            switch (ds.decl) {
                .@"var" => |decl| {
                    try self.emit("var ");
                    try self.emitName(decl.name);
                    if (decl.typ) |t| { try self.emit(":"); try self.emitSpace(); try self.printType(t); }
                    if (decl.initializer) |init_expr| {
                        try self.emitSpace(); try self.emit("="); try self.emitSpace();
                        try self.printExpr(init_expr);
                    }
                },
                .let => |decl| {
                    try self.emit("let ");
                    try self.emitName(decl.name);
                    if (decl.typ) |t| { try self.emit(":"); try self.emitSpace(); try self.printType(t); }
                    try self.emitSpace(); try self.emit("="); try self.emitSpace();
                    if (decl.initializer) |init_expr| try self.printExpr(init_expr);
                },
                else => {},
            }
        },
        .assign => |stmt| {
            try self.printExpr(stmt.left); try self.emitSpace();
            try self.emit(stmt.op.string()); try self.emitSpace();
            try self.printExpr(stmt.right);
        },
        else => {},
    }
}

fn printForUpdate(self: *Printer, s: Ast.Stmt) !void {
    switch (s) {
        .incr_decr => |stmt| {
            try self.printExpr(stmt.expr);
            if (stmt.increment) try self.emit("++") else try self.emit("--");
        },
        .assign => |stmt| {
            try self.printExpr(stmt.left); try self.emitSpace();
            try self.emit(stmt.op.string()); try self.emitSpace();
            try self.printExpr(stmt.right);
        },
        .call => |stmt| try self.printExpr(.{ .call = stmt.call }),
        else => {},
    }
}

fn printDeclStmt(self: *Printer, d: Ast.Decl) !void {
    switch (d) {
        .@"const" => |decl| {
            try self.emit("const ");
            try self.emitName(decl.name);
            if (decl.typ) |t| { try self.emit(":"); try self.emitSpace(); try self.printType(t); }
            try self.emitSpace(); try self.emit("="); try self.emitSpace();
            if (decl.initializer) |init_expr| try self.printExpr(init_expr);
            try self.emit(";");
        },
        .let => |decl| {
            try self.emit("let ");
            try self.emitName(decl.name);
            if (decl.typ) |t| { try self.emit(":"); try self.emitSpace(); try self.printType(t); }
            try self.emitSpace(); try self.emit("="); try self.emitSpace();
            if (decl.initializer) |init_expr| try self.printExpr(init_expr);
            try self.emit(";");
        },
        .@"var" => |decl| {
            try self.printAttributes(decl.attributes.items);
            try self.emit("var");
            if (decl.address_space != .none) {
                try self.emit("<"); try self.emit(decl.address_space.string());
                if (decl.access_mode != .none) {
                    try self.emit(","); try self.emitSpace();
                    try self.emit(decl.access_mode.string());
                }
                try self.emit(">");
            }
            try self.emit(" ");
            try self.emitName(decl.name);
            if (decl.typ) |t| { try self.emit(":"); try self.emitSpace(); try self.printType(t); }
            if (decl.initializer) |init_expr| {
                try self.emitSpace(); try self.emit("="); try self.emitSpace();
                try self.printExpr(init_expr);
            }
            try self.emit(";");
        },
        else => try self.printDecl(d),
    }
}
