//! Two-pass WGSL parser.
//!
//! Pass 1 (parse): Build AST, declare symbols with use_count = 0.
//! Pass 2 (visit): Bind identifiers to symbols, increment use_count, mark purity.

const std = @import("std");
const Ast = @import("Ast.zig");
const Lexer = @import("Lexer.zig");

const Parser = @This();

const Tag = Lexer.Tag;

allocator: std.mem.Allocator,
source: [:0]const u8,
token_tags: []const Tag,
token_starts: []const u32,
pos: u32,

// Symbol table
symbols: std.ArrayListUnmanaged(Ast.Symbol),
scope: *Ast.Scope,

// Two-pass tracking
scopes_in_order: std.ArrayListUnmanaged(*Ast.Scope),
scope_index: u32,
current_loc: u32,

// Errors
errors: std.ArrayListUnmanaged(ParseError),

pub const ParseError = struct {
    message: []const u8,
    pos: u32,
};

// =========================================================================
// Initialization
// =========================================================================

pub fn init(allocator: std.mem.Allocator, source: [:0]const u8, tokens: std.MultiArrayList(Lexer.Token)) Parser {
    const scope = allocator.create(Ast.Scope) catch @panic("OOM");
    scope.* = Ast.Scope.init(null);

    return .{
        .allocator = allocator,
        .source = source,
        .token_tags = tokens.items(.tag),
        .token_starts = tokens.items(.start),
        .pos = 0,
        .symbols = .empty,
        .scope = scope,
        .scopes_in_order = .empty,
        .scope_index = 0,
        .current_loc = 0,
        .errors = .empty,
    };
}

/// Parse source into a Module. Caller owns the returned module via the arena.
pub fn parse(self: *Parser) !*Ast.Module {
    const module = try self.allocator.create(Ast.Module);
    module.* = Ast.Module.init(self.scope, self.source);

    // Pass 1: Parse
    try self.parseTranslationUnit(module);

    // Pass 2: Visit
    self.visitModule(module);

    // Copy symbols to module
    module.symbols = self.symbols;

    return module;
}

// =========================================================================
// Token helpers
// =========================================================================

fn currentTag(self: *const Parser) Tag {
    if (self.pos >= self.token_tags.len) return .eof;
    return self.token_tags[self.pos];
}

fn peekTag(self: *const Parser, offset: u32) Tag {
    const p = self.pos + offset;
    if (p >= self.token_tags.len) return .eof;
    return self.token_tags[p];
}

fn advance(self: *Parser) void {
    if (self.pos < self.token_tags.len) self.pos += 1;
}

fn eat(self: *Parser, tag: Tag) bool {
    if (self.currentTag() == tag) {
        self.advance();
        return true;
    }
    return false;
}

fn expect(self: *Parser, tag: Tag) bool {
    if (self.currentTag() != tag) {
        self.addError("expected token");
        return false;
    }
    self.advance();
    return true;
}

fn tokenText(self: *const Parser, pos: u32) []const u8 {
    if (pos >= self.token_tags.len) return "";
    const start = self.token_starts[pos];
    const tag = self.token_tags[pos];
    _ = tag;
    // Scan to find end of this token's text
    var end = start;
    const src = self.source;
    if (end >= src.len) return "";
    const ch = src[end];
    if (Lexer.isIdentStart(ch)) {
        end += 1;
        while (end < src.len and Lexer.isIdentContinue(src[end])) end += 1;
    } else if (Lexer.isDigit(ch) or (ch == '.' and end + 1 < src.len and Lexer.isDigit(src[end + 1]))) {
        return self.scanNumberText(start);
    } else {
        // operator - advance 1-3 chars
        end += 1;
        if (end < src.len) {
            const nc = src[end];
            switch (ch) {
                '+' => if (nc == '+' or nc == '=') { end += 1; },
                '-' => if (nc == '-' or nc == '=' or nc == '>') { end += 1; },
                '*', '/', '%' => if (nc == '=') { end += 1; },
                '&' => if (nc == '&' or nc == '=') { end += 1; },
                '|' => if (nc == '|' or nc == '=') { end += 1; },
                '^' => if (nc == '=') { end += 1; },
                '<' => {
                    if (nc == '<') {
                        end += 1;
                        if (end < src.len and src[end] == '=') end += 1;
                    } else if (nc == '=') end += 1;
                },
                '>' => {
                    if (nc == '>') {
                        end += 1;
                        if (end < src.len and src[end] == '=') end += 1;
                    } else if (nc == '=') end += 1;
                },
                '=', '!' => if (nc == '=') { end += 1; },
                else => {},
            }
        }
    }
    return src[start..end];
}

fn scanNumberText(self: *const Parser, start: u32) []const u8 {
    var pos = start;
    const src = self.source;
    // Hex
    if (pos + 1 < src.len and src[pos] == '0' and (src[pos + 1] == 'x' or src[pos + 1] == 'X')) {
        pos += 2;
        while (pos < src.len and Lexer.isHexDigit(src[pos])) pos += 1;
        if (pos < src.len and src[pos] == '.') {
            pos += 1;
            while (pos < src.len and Lexer.isHexDigit(src[pos])) pos += 1;
        }
        if (pos < src.len and (src[pos] == 'p' or src[pos] == 'P')) {
            pos += 1;
            if (pos < src.len and (src[pos] == '+' or src[pos] == '-')) pos += 1;
            while (pos < src.len and Lexer.isDigit(src[pos])) pos += 1;
        }
    } else {
        while (pos < src.len and Lexer.isDigit(src[pos])) pos += 1;
        if (pos < src.len and src[pos] == '.') {
            const nid = pos + 1 < src.len and Lexer.isDigit(src[pos + 1]);
            const nie = pos + 1 < src.len and Lexer.isIdentStart(src[pos + 1]);
            const ae = pos + 1 >= src.len;
            if (nid or ae or !nie) {
                pos += 1;
                while (pos < src.len and Lexer.isDigit(src[pos])) pos += 1;
            }
        }
        if (pos < src.len and (src[pos] == 'e' or src[pos] == 'E')) {
            pos += 1;
            if (pos < src.len and (src[pos] == '+' or src[pos] == '-')) pos += 1;
            while (pos < src.len and Lexer.isDigit(src[pos])) pos += 1;
        }
    }
    if (pos < src.len and (src[pos] == 'i' or src[pos] == 'u' or src[pos] == 'f' or src[pos] == 'h')) pos += 1;
    return src[start..pos];
}

fn currentText(self: *const Parser) []const u8 {
    return self.tokenText(self.pos);
}

fn currentStart(self: *const Parser) u32 {
    if (self.pos >= self.token_starts.len) return @intCast(self.source.len);
    return self.token_starts[self.pos];
}

fn addError(self: *Parser, message: []const u8) void {
    self.errors.append(self.allocator, .{ .message = message, .pos = self.currentStart() }) catch {};
}

// =========================================================================
// Symbol table (Pass 1)
// =========================================================================

fn declareSymbol(self: *Parser, name: []const u8, kind: Ast.Symbol.Kind, flags: Ast.Symbol.Flags, loc: u32) Ast.SymbolIndex {
    const idx: u32 = @intCast(self.symbols.items.len);
    self.symbols.append(self.allocator, .{
        .original_name = name,
        .kind = kind,
        .flags = flags,
        .use_count = 0,
        .loc = loc,
    }) catch @panic("OOM");
    self.scope.members.put(self.allocator, name, .{
        .ref = @enumFromInt(idx),
        .loc = loc,
    }) catch @panic("OOM");
    return @enumFromInt(idx);
}

fn lookupSymbol(self: *const Parser, name: []const u8) ?Ast.SymbolIndex {
    var scope_iter: ?*Ast.Scope = self.scope;
    while (scope_iter) |s| {
        if (s.members.get(name)) |member| {
            // Module scope (no parent) is always visible.
            // Local symbols visible only if declared before current_loc.
            // During parse pass (current_loc == 0), allow all.
            if (s.parent == null or self.current_loc == 0 or member.loc < self.current_loc) {
                return member.ref;
            }
        }
        scope_iter = s.parent;
    }
    return null;
}

fn pushScope(self: *Parser) void {
    const new_scope = self.allocator.create(Ast.Scope) catch @panic("OOM");
    new_scope.* = Ast.Scope.init(self.scope);
    self.scope.children.append(self.allocator, new_scope) catch @panic("OOM");
    self.scope = new_scope;
    self.scopes_in_order.append(self.allocator, new_scope) catch @panic("OOM");
}

fn popScope(self: *Parser) void {
    if (self.scope.parent) |p| self.scope = p;
}

// =========================================================================
// Pass 2: Visit
// =========================================================================

fn visitModule(self: *Parser, module: *Ast.Module) void {
    self.scope = module.scope;
    self.scope_index = 0;

    for (module.declarations.items) |decl| {
        self.visitDecl(decl);
    }
}

fn visitDecl(self: *Parser, d: Ast.Decl) void {
    switch (d) {
        .@"const" => |decl| {
            if (decl.typ) |t| self.visitType(t);
            if (decl.initializer) |init_expr| decl.initializer = self.visitExpr(init_expr);
        },
        .override => |decl| {
            if (decl.typ) |t| self.visitType(t);
            if (decl.initializer) |init_expr| decl.initializer = self.visitExpr(init_expr);
        },
        .@"var" => |decl| {
            if (decl.typ) |t| self.visitType(t);
            if (decl.initializer) |init_expr| decl.initializer = self.visitExpr(init_expr);
        },
        .let => |decl| {
            if (decl.typ) |t| self.visitType(t);
            if (decl.initializer) |init_expr| decl.initializer = self.visitExpr(init_expr);
        },
        .function => |decl| self.visitFunctionDecl(decl),
        .@"struct" => |decl| {
            for (decl.members.items) |member| {
                self.visitType(member.typ);
            }
        },
        .alias => |decl| self.visitType(decl.typ),
        .const_assert => |decl| decl.expr = self.visitExpr(decl.expr),
    }
}

fn visitFunctionDecl(self: *Parser, decl: *Ast.FunctionDecl) void {
    for (decl.parameters.items) |param| {
        self.visitType(param.typ);
    }
    if (decl.return_type) |rt| self.visitType(rt);
    self.enterNextScope();
    if (decl.body) |body| self.visitCompoundStmt(body);
    self.exitScope();
}

fn visitStmt(self: *Parser, s: Ast.Stmt) void {
    switch (s) {
        .compound => |stmt| self.visitCompoundStmt(stmt),
        .@"return" => |stmt| {
            if (stmt.value) |v| stmt.value = self.visitExpr(v);
        },
        .@"if" => |stmt| {
            stmt.condition = self.visitExpr(stmt.condition);
            self.visitCompoundStmt(stmt.body);
            if (stmt.else_branch) |eb| self.visitStmt(eb);
        },
        .@"switch" => |stmt| {
            stmt.expr = self.visitExpr(stmt.expr);
            for (stmt.cases.items) |*c| {
                for (c.selectors.items, 0..) |sel, j| {
                    c.selectors.items[j] = self.visitExpr(sel);
                }
                self.visitCompoundStmt(c.body);
            }
        },
        .@"for" => |stmt| {
            self.enterNextScope();
            if (stmt.init_stmt) |is| self.visitStmt(is);
            if (stmt.condition) |cond| stmt.condition = self.visitExpr(cond);
            if (stmt.update) |upd| self.visitStmt(upd);
            self.visitCompoundStmt(stmt.body);
            self.exitScope();
        },
        .@"while" => |stmt| {
            stmt.condition = self.visitExpr(stmt.condition);
            self.visitCompoundStmt(stmt.body);
        },
        .loop => |stmt| {
            self.visitCompoundStmt(stmt.body);
            if (stmt.continuing) |c| self.visitCompoundStmt(c);
        },
        .break_if => |stmt| {
            stmt.condition = self.visitExpr(stmt.condition);
        },
        .assign => |stmt| {
            stmt.left = self.visitExpr(stmt.left);
            stmt.right = self.visitExpr(stmt.right);
        },
        .incr_decr => |stmt| {
            stmt.expr = self.visitExpr(stmt.expr);
        },
        .call => |stmt| {
            // Visit the inner CallExpr's func and args
            if (stmt.call.func) |f| stmt.call.func = self.visitExpr(f);
            if (stmt.call.template_type) |tt| self.visitType(tt);
            for (stmt.call.args.items, 0..) |arg, j| {
                stmt.call.args.items[j] = self.visitExpr(arg);
            }
        },
        .decl => |stmt| self.visitDecl(stmt.decl),
        .@"break", .@"continue", .discard => {},
    }
}

fn visitCompoundStmt(self: *Parser, stmt: *Ast.CompoundStmt) void {
    self.enterNextScope();
    for (stmt.stmts.items) |s| {
        self.visitStmt(s);
    }
    self.exitScope();
}

fn visitExpr(self: *Parser, e: Ast.Expr) Ast.Expr {
    switch (e) {
        .ident => |expr| {
            self.current_loc = expr.loc;
            if (self.lookupSymbol(expr.name)) |ref| {
                expr.ref = ref;
                if (ref.isValid()) {
                    const idx = ref.index();
                    if (idx < self.symbols.items.len) {
                        self.symbols.items[idx].use_count += 1;
                    }
                }
            }
            return e;
        },
        .literal => return e,
        .binary => |expr| {
            expr.left = self.visitExpr(expr.left);
            expr.right = self.visitExpr(expr.right);
            return e;
        },
        .unary => |expr| {
            expr.operand = self.visitExpr(expr.operand);
            return e;
        },
        .call => |expr| {
            if (expr.func) |f| expr.func = self.visitExpr(f);
            if (expr.template_type) |tt| self.visitType(tt);
            for (expr.args.items, 0..) |arg, j| {
                expr.args.items[j] = self.visitExpr(arg);
            }
            return e;
        },
        .index => |expr| {
            expr.base = self.visitExpr(expr.base);
            expr.idx = self.visitExpr(expr.idx);
            return e;
        },
        .member => |expr| {
            expr.base = self.visitExpr(expr.base);
            return e;
        },
        .paren => |expr| {
            expr.expr = self.visitExpr(expr.expr);
            return e;
        },
    }
}

fn visitType(self: *Parser, t: Ast.Type) void {
    switch (t) {
        .ident => |typ| {
            self.current_loc = 0; // Types don't have text-order restrictions at module scope
            if (self.lookupSymbol(typ.name)) |ref| {
                typ.ref = ref;
                if (ref.isValid()) {
                    const idx = ref.index();
                    if (idx < self.symbols.items.len) {
                        self.symbols.items[idx].use_count += 1;
                    }
                }
            }
        },
        .vec => |typ| {
            if (typ.elem_type) |et| self.visitType(et);
        },
        .mat => |typ| {
            if (typ.elem_type) |et| self.visitType(et);
        },
        .array => |typ| {
            if (typ.elem_type) |et| self.visitType(et);
            if (typ.size) |s| _ = self.visitExpr(s);
        },
        .ptr => |typ| self.visitType(typ.elem_type),
        .atomic => |typ| self.visitType(typ.elem_type),
        .sampler => {},
        .texture => |typ| {
            if (typ.sampled_type) |st| self.visitType(st);
        },
    }
}

fn enterNextScope(self: *Parser) void {
    if (self.scope_index < self.scopes_in_order.items.len) {
        self.scope = self.scopes_in_order.items[self.scope_index];
        self.scope_index += 1;
    }
}

fn exitScope(self: *Parser) void {
    if (self.scope.parent) |p| self.scope = p;
}

// =========================================================================
// Pass 1: Parse
// =========================================================================

fn parseTranslationUnit(self: *Parser, module: *Ast.Module) !void {
    // Parse directives
    while (true) {
        switch (self.currentTag()) {
            .keyword_enable => {
                const dir = try self.parseEnableDirective();
                try module.directives.append(self.allocator, dir);
            },
            .keyword_requires => {
                const dir = try self.parseRequiresDirective();
                try module.directives.append(self.allocator, dir);
            },
            .keyword_diagnostic => {
                const dir = try self.parseDiagnosticDirective();
                try module.directives.append(self.allocator, dir);
            },
            else => break,
        }
    }

    // Parse declarations
    while (self.currentTag() != .eof) {
        if (try self.parseDeclaration()) |decl| {
            try module.declarations.append(self.allocator, decl);
        } else {
            self.advance();
        }
    }
}

fn parseEnableDirective(self: *Parser) !Ast.Directive {
    _ = self.expect(.keyword_enable);
    var features: std.ArrayListUnmanaged([]const u8) = .empty;
    while (true) {
        if (self.currentTag() == .ident) {
            try features.append(self.allocator, self.currentText());
            self.advance();
        }
        if (!self.eat(.comma)) break;
    }
    _ = self.expect(.semicolon);
    return .{ .enable = .{ .features = features } };
}

fn parseRequiresDirective(self: *Parser) !Ast.Directive {
    _ = self.expect(.keyword_requires);
    var features: std.ArrayListUnmanaged([]const u8) = .empty;
    while (true) {
        if (self.currentTag() == .ident) {
            try features.append(self.allocator, self.currentText());
            self.advance();
        }
        if (!self.eat(.comma)) break;
    }
    _ = self.expect(.semicolon);
    return .{ .requires = .{ .features = features } };
}

fn parseDiagnosticDirective(self: *Parser) !Ast.Directive {
    _ = self.expect(.keyword_diagnostic);
    _ = self.expect(.l_paren);
    const severity = if (self.currentTag() == .ident) blk: {
        const text = self.currentText();
        self.advance();
        break :blk text;
    } else "";
    _ = self.expect(.comma);
    const rule = if (self.currentTag() == .ident) blk: {
        const text = self.currentText();
        self.advance();
        break :blk text;
    } else "";
    _ = self.expect(.r_paren);
    _ = self.expect(.semicolon);
    return .{ .diagnostic = .{ .severity = severity, .rule = rule } };
}

fn parseDeclaration(self: *Parser) !?Ast.Decl {
    var attrs = try self.parseAttributes();

    switch (self.currentTag()) {
        .keyword_const => {
            if (self.peekTag(1) == .ident) return .{ .@"const" = try self.parseConstDecl() };
            return .{ .const_assert = try self.parseConstAssert() };
        },
        .keyword_const_assert => return .{ .const_assert = try self.parseConstAssert() },
        .keyword_override => return .{ .override = try self.parseOverrideDecl(&attrs) },
        .keyword_var => return .{ .@"var" = try self.parseVarDecl(&attrs) },
        .keyword_let => return .{ .let = try self.parseLetDecl() },
        .keyword_fn => return .{ .function = try self.parseFunctionDecl(&attrs) },
        .keyword_struct => return .{ .@"struct" = try self.parseStructDecl() },
        .keyword_alias => return .{ .alias = try self.parseAliasDecl() },
        else => {
            if (attrs.items.len > 0) self.addError("unexpected attributes");
            return null;
        },
    }
}

fn parseAttributes(self: *Parser) !std.ArrayListUnmanaged(Ast.Attribute) {
    var attrs: std.ArrayListUnmanaged(Ast.Attribute) = .empty;
    while (self.currentTag() == .at) {
        self.advance();
        var attr = Ast.Attribute{ .name = "", .args = .empty };
        if (self.currentTag() == .ident) {
            attr.name = self.currentText();
            self.advance();
        }
        if (self.eat(.l_paren)) {
            attr.args = try self.parseExpressionList();
            _ = self.expect(.r_paren);
        }
        try attrs.append(self.allocator, attr);
    }
    return attrs;
}

fn parseConstDecl(self: *Parser) !*Ast.ConstDecl {
    _ = self.expect(.keyword_const);
    const decl = try self.allocator.create(Ast.ConstDecl);
    decl.* = .{ .name = .none };

    if (self.currentTag() == .ident) {
        const text = self.currentText();
        const loc = self.currentStart();
        self.advance();
        decl.name = self.declareSymbol(text, .@"const", .{}, loc);
    }

    if (self.eat(.colon)) decl.typ = try self.parseType();
    _ = self.expect(.eq);
    decl.initializer = try self.parseExpression();
    _ = self.expect(.semicolon);
    return decl;
}

fn parseOverrideDecl(self: *Parser, attrs: *std.ArrayListUnmanaged(Ast.Attribute)) !*Ast.OverrideDecl {
    _ = self.expect(.keyword_override);
    const decl = try self.allocator.create(Ast.OverrideDecl);
    decl.* = .{ .attributes = attrs.*, .name = .none };

    if (self.currentTag() == .ident) {
        const text = self.currentText();
        const loc = self.currentStart();
        self.advance();
        decl.name = self.declareSymbol(text, .override, .{}, loc);
    }

    if (self.eat(.colon)) decl.typ = try self.parseType();
    if (self.eat(.eq)) decl.initializer = try self.parseExpression();
    _ = self.expect(.semicolon);
    return decl;
}

fn parseVarDecl(self: *Parser, attrs: *std.ArrayListUnmanaged(Ast.Attribute)) !*Ast.VarDecl {
    _ = self.expect(.keyword_var);
    const decl = try self.allocator.create(Ast.VarDecl);
    decl.* = .{ .attributes = attrs.*, .name = .none };

    // Optional <address_space, access_mode>
    if (self.eat(.lt)) {
        decl.address_space = self.parseAddressSpace();
        if (self.eat(.comma)) decl.access_mode = self.parseAccessMode();
        _ = self.expect(.gt);
    }

    var flags = Ast.Symbol.Flags{};
    if (decl.address_space == .uniform or decl.address_space == .storage) {
        flags.is_external_binding = true;
    }

    if (self.currentTag() == .ident) {
        const text = self.currentText();
        const loc = self.currentStart();
        self.advance();
        decl.name = self.declareSymbol(text, .@"var", flags, loc);
    }

    if (self.eat(.colon)) decl.typ = try self.parseType();
    if (self.eat(.eq)) decl.initializer = try self.parseExpression();
    _ = self.expect(.semicolon);
    return decl;
}

fn parseLetDecl(self: *Parser) !*Ast.LetDecl {
    _ = self.expect(.keyword_let);
    const decl = try self.allocator.create(Ast.LetDecl);
    decl.* = .{ .name = .none };

    if (self.currentTag() == .ident) {
        const text = self.currentText();
        const loc = self.currentStart();
        self.advance();
        decl.name = self.declareSymbol(text, .let, .{}, loc);
    }

    if (self.eat(.colon)) decl.typ = try self.parseType();
    _ = self.expect(.eq);
    decl.initializer = try self.parseExpression();
    _ = self.expect(.semicolon);
    return decl;
}

fn parseFunctionDecl(self: *Parser, attrs: *std.ArrayListUnmanaged(Ast.Attribute)) !*Ast.FunctionDecl {
    _ = self.expect(.keyword_fn);
    const decl = try self.allocator.create(Ast.FunctionDecl);
    decl.* = .{
        .attributes = attrs.*,
        .name = .none,
        .parameters = .empty,
        .return_attr = .empty,
    };

    // Check entry point
    var is_entry_point = false;
    for (attrs.items) |attr| {
        if (std.mem.eql(u8, attr.name, "vertex") or
            std.mem.eql(u8, attr.name, "fragment") or
            std.mem.eql(u8, attr.name, "compute"))
        {
            is_entry_point = true;
            break;
        }
    }

    var flags = Ast.Symbol.Flags{};
    if (is_entry_point) {
        flags.is_entry_point = true;
        flags.must_not_be_renamed = true;
    }

    if (self.currentTag() == .ident) {
        const text = self.currentText();
        const loc = self.currentStart();
        self.advance();
        decl.name = self.declareSymbol(text, .function, flags, loc);
    }

    self.pushScope();

    _ = self.expect(.l_paren);
    if (self.currentTag() != .r_paren) {
        decl.parameters = try self.parseParameters();
    }
    _ = self.expect(.r_paren);

    if (self.eat(.arrow)) {
        decl.return_attr = try self.parseAttributes();
        decl.return_type = try self.parseType();
    }

    decl.body = try self.parseCompoundStmt();
    self.popScope();
    return decl;
}

fn parseParameters(self: *Parser) !std.ArrayListUnmanaged(Ast.Parameter) {
    var params: std.ArrayListUnmanaged(Ast.Parameter) = .empty;
    while (true) {
        const param_attrs = try self.parseAttributes();
        if (self.currentTag() != .ident) break;
        const text = self.currentText();
        const loc = self.currentStart();
        self.advance();
        const name = self.declareSymbol(text, .parameter, .{}, loc);
        _ = self.expect(.colon);
        const typ = try self.parseType();
        try params.append(self.allocator, .{ .attributes = param_attrs, .name = name, .typ = typ });
        if (!self.eat(.comma)) break;
        if (self.currentTag() == .r_paren) break;
    }
    return params;
}

fn parseStructDecl(self: *Parser) !*Ast.StructDecl {
    _ = self.expect(.keyword_struct);
    const decl = try self.allocator.create(Ast.StructDecl);
    decl.* = .{ .name = .none, .members = .empty };

    if (self.currentTag() == .ident) {
        const text = self.currentText();
        const loc = self.currentStart();
        self.advance();
        decl.name = self.declareSymbol(text, .@"struct", .{}, loc);
    }

    _ = self.expect(.l_brace);
    while (self.currentTag() != .r_brace and self.currentTag() != .eof) {
        const member_attrs = try self.parseAttributes();
        if (self.currentTag() != .ident) break;
        const text = self.currentText();
        const loc = self.currentStart();
        self.advance();
        const name = self.declareSymbol(text, .member, .{}, loc);
        _ = self.expect(.colon);
        const typ = try self.parseType();
        try decl.members.append(self.allocator, .{ .attributes = member_attrs, .name = name, .typ = typ });
        _ = self.eat(.comma);
    }
    _ = self.expect(.r_brace);
    return decl;
}

fn parseAliasDecl(self: *Parser) !*Ast.AliasDecl {
    _ = self.expect(.keyword_alias);
    const decl = try self.allocator.create(Ast.AliasDecl);
    var name: Ast.SymbolIndex = .none;
    if (self.currentTag() == .ident) {
        const text = self.currentText();
        const loc = self.currentStart();
        self.advance();
        name = self.declareSymbol(text, .alias, .{}, loc);
    }
    _ = self.expect(.eq);
    const typ = try self.parseType();
    _ = self.expect(.semicolon);
    decl.* = .{ .name = name, .typ = typ };
    return decl;
}

fn parseConstAssert(self: *Parser) !*Ast.ConstAssertDecl {
    if (self.currentTag() == .keyword_const) self.advance();
    _ = self.expect(.keyword_const_assert);
    const decl = try self.allocator.create(Ast.ConstAssertDecl);
    decl.* = .{ .expr = (try self.parseExpression()) orelse return error.ParseFailed };
    _ = self.expect(.semicolon);
    return decl;
}

// =========================================================================
// Types
// =========================================================================

fn parseType(self: *Parser) error{OutOfMemory, ParseFailed}!Ast.Type {
    if (self.currentTag() == .ident) {
        const name = self.currentText();
        self.advance();
        if (self.currentTag() == .lt) {
            return self.parseTemplatedType(name);
        }
        const typ = try self.allocator.create(Ast.IdentType);
        typ.* = .{ .name = name, .ref = .none };
        return .{ .ident = typ };
    }

    self.addError("expected type");
    self.advance();
    const typ = try self.allocator.create(Ast.IdentType);
    typ.* = .{ .name = "error", .ref = .none };
    return .{ .ident = typ };
}

fn parseTemplatedType(self: *Parser, name: []const u8) !Ast.Type {
    _ = self.expect(.lt);

    if (isVecName(name)) {
        const size = name[3] - '0';
        const elem = try self.parseType();
        _ = self.expect(.gt);
        const typ = try self.allocator.create(Ast.VecType);
        typ.* = .{ .size = size, .elem_type = elem };
        return .{ .vec = typ };
    }

    if (isMatName(name)) {
        const cols = name[3] - '0';
        const rows = name[5] - '0';
        const elem = try self.parseType();
        _ = self.expect(.gt);
        const typ = try self.allocator.create(Ast.MatType);
        typ.* = .{ .cols = cols, .rows = rows, .elem_type = elem };
        return .{ .mat = typ };
    }

    if (std.mem.eql(u8, name, "array")) {
        const elem = try self.parseType();
        var size: ?Ast.Expr = null;
        if (self.eat(.comma)) size = try self.parseTemplateArgExpr();
        _ = self.expect(.gt);
        const typ = try self.allocator.create(Ast.ArrayType);
        typ.* = .{ .elem_type = elem, .size = size };
        return .{ .array = typ };
    }

    if (std.mem.eql(u8, name, "ptr")) {
        const addr = self.parseAddressSpace();
        _ = self.expect(.comma);
        const elem = try self.parseType();
        var access: Ast.AccessMode = .none;
        if (self.eat(.comma)) access = self.parseAccessMode();
        _ = self.expect(.gt);
        const typ = try self.allocator.create(Ast.PtrType);
        typ.* = .{ .address_space = addr, .elem_type = elem, .access_mode = access };
        return .{ .ptr = typ };
    }

    if (std.mem.eql(u8, name, "atomic")) {
        const elem = try self.parseType();
        _ = self.expect(.gt);
        const typ = try self.allocator.create(Ast.AtomicType);
        typ.* = .{ .elem_type = elem };
        return .{ .atomic = typ };
    }

    // Texture types
    if (parseTextureTypeInfo(name)) |info| {
        const typ = try self.allocator.create(Ast.TextureType);
        typ.* = .{ .kind = info.kind, .dimension = info.dim };
        if (info.kind == .storage) {
            if (self.currentTag() == .ident) {
                typ.texel_format = self.currentText();
                self.advance();
            }
            if (self.eat(.comma)) typ.access_mode = self.parseAccessMode();
        } else if (info.kind != .depth and info.kind != .depth_multisampled) {
            typ.sampled_type = try self.parseType();
        }
        _ = self.expect(.gt);
        return .{ .texture = typ };
    }

    // Generic templated type
    _ = try self.parseType();
    while (self.eat(.comma)) _ = try self.parseType();
    _ = self.expect(.gt);
    const typ = try self.allocator.create(Ast.IdentType);
    typ.* = .{ .name = name, .ref = .none };
    return .{ .ident = typ };
}

const TextureInfo = struct { kind: Ast.TextureKind, dim: Ast.TextureDimension };

fn parseTextureTypeInfo(name: []const u8) ?TextureInfo {
    const map = std.StaticStringMap(TextureInfo).initComptime(.{
        .{ "texture_1d", TextureInfo{ .kind = .sampled, .dim = .@"1d" } },
        .{ "texture_2d", TextureInfo{ .kind = .sampled, .dim = .@"2d" } },
        .{ "texture_2d_array", TextureInfo{ .kind = .sampled, .dim = .@"2d_array" } },
        .{ "texture_3d", TextureInfo{ .kind = .sampled, .dim = .@"3d" } },
        .{ "texture_cube", TextureInfo{ .kind = .sampled, .dim = .cube } },
        .{ "texture_cube_array", TextureInfo{ .kind = .sampled, .dim = .cube_array } },
        .{ "texture_multisampled_2d", TextureInfo{ .kind = .multisampled, .dim = .@"2d" } },
        .{ "texture_storage_1d", TextureInfo{ .kind = .storage, .dim = .@"1d" } },
        .{ "texture_storage_2d", TextureInfo{ .kind = .storage, .dim = .@"2d" } },
        .{ "texture_storage_2d_array", TextureInfo{ .kind = .storage, .dim = .@"2d_array" } },
        .{ "texture_storage_3d", TextureInfo{ .kind = .storage, .dim = .@"3d" } },
        .{ "texture_depth_2d", TextureInfo{ .kind = .depth, .dim = .@"2d" } },
        .{ "texture_depth_2d_array", TextureInfo{ .kind = .depth, .dim = .@"2d_array" } },
        .{ "texture_depth_cube", TextureInfo{ .kind = .depth, .dim = .cube } },
        .{ "texture_depth_cube_array", TextureInfo{ .kind = .depth, .dim = .cube_array } },
        .{ "texture_depth_multisampled_2d", TextureInfo{ .kind = .depth_multisampled, .dim = .@"2d" } },
    });
    return map.get(name);
}

fn parseAddressSpace(self: *Parser) Ast.AddressSpace {
    if (self.currentTag() == .ident) {
        const text = self.currentText();
        self.advance();
        if (std.mem.eql(u8, text, "function")) return .function;
        if (std.mem.eql(u8, text, "private")) return .private;
        if (std.mem.eql(u8, text, "workgroup")) return .workgroup;
        if (std.mem.eql(u8, text, "uniform")) return .uniform;
        if (std.mem.eql(u8, text, "storage")) return .storage;
    }
    return .none;
}

fn parseAccessMode(self: *Parser) Ast.AccessMode {
    if (self.currentTag() == .ident) {
        const text = self.currentText();
        self.advance();
        if (std.mem.eql(u8, text, "read")) return .read;
        if (std.mem.eql(u8, text, "write")) return .write;
        if (std.mem.eql(u8, text, "read_write")) return .read_write;
    }
    return .none;
}

// =========================================================================
// Expressions
// =========================================================================

fn parseExpression(self: *Parser) error{OutOfMemory, ParseFailed}!?Ast.Expr {
    return self.parseLogicalOrExpr();
}

fn parseLogicalOrExpr(self: *Parser) !?Ast.Expr {
    var left = (try self.parseLogicalAndExpr()) orelse return null;
    while (self.currentTag() == .pipe_pipe) {
        self.advance();
        const right = (try self.parseLogicalAndExpr()) orelse return null;
        const node = try self.allocator.create(Ast.BinaryExpr);
        node.* = .{ .op = .logical_or, .left = left, .right = right };
        left = .{ .binary = node };
    }
    return left;
}

fn parseLogicalAndExpr(self: *Parser) !?Ast.Expr {
    var left = (try self.parseBitwiseOrExpr()) orelse return null;
    while (self.currentTag() == .amp_amp) {
        self.advance();
        const right = (try self.parseBitwiseOrExpr()) orelse return null;
        const node = try self.allocator.create(Ast.BinaryExpr);
        node.* = .{ .op = .logical_and, .left = left, .right = right };
        left = .{ .binary = node };
    }
    return left;
}

fn parseBitwiseOrExpr(self: *Parser) !?Ast.Expr {
    var left = (try self.parseBitwiseXorExpr()) orelse return null;
    while (self.currentTag() == .pipe) {
        self.advance();
        const right = (try self.parseBitwiseXorExpr()) orelse return null;
        const node = try self.allocator.create(Ast.BinaryExpr);
        node.* = .{ .op = .@"or", .left = left, .right = right };
        left = .{ .binary = node };
    }
    return left;
}

fn parseBitwiseXorExpr(self: *Parser) !?Ast.Expr {
    var left = (try self.parseBitwiseAndExpr()) orelse return null;
    while (self.currentTag() == .caret) {
        self.advance();
        const right = (try self.parseBitwiseAndExpr()) orelse return null;
        const node = try self.allocator.create(Ast.BinaryExpr);
        node.* = .{ .op = .xor, .left = left, .right = right };
        left = .{ .binary = node };
    }
    return left;
}

fn parseBitwiseAndExpr(self: *Parser) !?Ast.Expr {
    var left = (try self.parseEqualityExpr()) orelse return null;
    while (self.currentTag() == .amp) {
        self.advance();
        const right = (try self.parseEqualityExpr()) orelse return null;
        const node = try self.allocator.create(Ast.BinaryExpr);
        node.* = .{ .op = .@"and", .left = left, .right = right };
        left = .{ .binary = node };
    }
    return left;
}

fn parseEqualityExpr(self: *Parser) !?Ast.Expr {
    var left = (try self.parseRelationalExpr()) orelse return null;
    while (true) {
        const op: Ast.BinaryOp = switch (self.currentTag()) {
            .eq_eq => .eq,
            .bang_eq => .ne,
            else => return left,
        };
        self.advance();
        const right = (try self.parseRelationalExpr()) orelse return null;
        const node = try self.allocator.create(Ast.BinaryExpr);
        node.* = .{ .op = op, .left = left, .right = right };
        left = .{ .binary = node };
    }
}

fn parseRelationalExpr(self: *Parser) !?Ast.Expr {
    var left = (try self.parseShiftExpr()) orelse return null;
    while (true) {
        const op: Ast.BinaryOp = switch (self.currentTag()) {
            .lt => .lt,
            .lt_eq => .le,
            .gt => .gt,
            .gt_eq => .ge,
            else => return left,
        };
        self.advance();
        const right = (try self.parseShiftExpr()) orelse return null;
        const node = try self.allocator.create(Ast.BinaryExpr);
        node.* = .{ .op = op, .left = left, .right = right };
        left = .{ .binary = node };
    }
}

fn parseShiftExpr(self: *Parser) !?Ast.Expr {
    var left = (try self.parseAdditiveExpr()) orelse return null;
    while (true) {
        const op: Ast.BinaryOp = switch (self.currentTag()) {
            .lt_lt => .shl,
            .gt_gt => .shr,
            else => return left,
        };
        self.advance();
        const right = (try self.parseAdditiveExpr()) orelse return null;
        const node = try self.allocator.create(Ast.BinaryExpr);
        node.* = .{ .op = op, .left = left, .right = right };
        left = .{ .binary = node };
    }
}

fn parseAdditiveExpr(self: *Parser) !?Ast.Expr {
    var left = (try self.parseMultiplicativeExpr()) orelse return null;
    while (true) {
        const op: Ast.BinaryOp = switch (self.currentTag()) {
            .plus => .add,
            .minus => .sub,
            else => return left,
        };
        self.advance();
        const right = (try self.parseMultiplicativeExpr()) orelse return null;
        const node = try self.allocator.create(Ast.BinaryExpr);
        node.* = .{ .op = op, .left = left, .right = right };
        left = .{ .binary = node };
    }
}

fn parseMultiplicativeExpr(self: *Parser) !?Ast.Expr {
    var left = (try self.parseUnaryExpr()) orelse return null;
    while (true) {
        const op: Ast.BinaryOp = switch (self.currentTag()) {
            .star => .mul,
            .slash => .div,
            .percent => .mod,
            else => return left,
        };
        self.advance();
        const right = (try self.parseUnaryExpr()) orelse return null;
        const node = try self.allocator.create(Ast.BinaryExpr);
        node.* = .{ .op = op, .left = left, .right = right };
        left = .{ .binary = node };
    }
}

fn parseUnaryExpr(self: *Parser) !?Ast.Expr {
    const op: ?Ast.UnaryOp = switch (self.currentTag()) {
        .minus => .neg,
        .bang => .not,
        .tilde => .bit_not,
        .star => .deref,
        .amp => .addr,
        else => null,
    };

    if (op) |unary_op| {
        self.advance();
        const operand = (try self.parseUnaryExpr()) orelse return null;
        const node = try self.allocator.create(Ast.UnaryExpr);
        node.* = .{ .op = unary_op, .operand = operand };
        return .{ .unary = node };
    }

    return self.parsePostfixExpr();
}

fn parsePostfixExpr(self: *Parser) !?Ast.Expr {
    var left = (try self.parsePrimaryExpr()) orelse return null;

    while (true) {
        switch (self.currentTag()) {
            .dot => {
                self.advance();
                if (self.currentTag() == .ident) {
                    const member = self.currentText();
                    self.advance();
                    const node = try self.allocator.create(Ast.MemberExpr);
                    node.* = .{ .base = left, .member_name = member };
                    left = .{ .member = node };
                } else {
                    self.addError("expected member name");
                }
            },
            .l_bracket => {
                self.advance();
                const idx = (try self.parseExpression()) orelse return null;
                _ = self.expect(.r_bracket);
                const node = try self.allocator.create(Ast.IndexExpr);
                node.* = .{ .base = left, .idx = idx };
                left = .{ .index = node };
            },
            .l_paren => {
                self.advance();
                const args = try self.parseExpressionList();
                _ = self.expect(.r_paren);
                const node = try self.allocator.create(Ast.CallExpr);
                node.* = .{ .func = left, .args = args };
                left = .{ .call = node };
            },
            else => return left,
        }
    }
}

fn parsePrimaryExpr(self: *Parser) !?Ast.Expr {
    switch (self.currentTag()) {
        .int_literal, .float_literal => {
            const text = self.currentText();
            const kind = self.currentTag();
            self.advance();
            const node = try self.allocator.create(Ast.LiteralExpr);
            node.* = .{ .kind = kind, .value = text };
            return .{ .literal = node };
        },
        .true_literal, .false_literal => {
            const text = self.currentText();
            const kind = self.currentTag();
            self.advance();
            const node = try self.allocator.create(Ast.LiteralExpr);
            node.* = .{ .kind = kind, .value = text };
            return .{ .literal = node };
        },
        .ident => {
            const text = self.currentText();
            const loc = self.currentStart();
            self.advance();

            // Templated constructor: array<T, N>(...) or vec2<f32>(...)
            if (self.currentTag() == .lt and isTemplatedTypeName(text)) {
                return self.parseTemplatedConstructor(text);
            }

            const node = try self.allocator.create(Ast.IdentExpr);
            node.* = .{ .loc = loc, .name = text, .ref = .none };
            return .{ .ident = node };
        },
        .l_paren => {
            self.advance();
            const expr = (try self.parseExpression()) orelse return null;
            _ = self.expect(.r_paren);
            const node = try self.allocator.create(Ast.ParenExpr);
            node.* = .{ .expr = expr };
            return .{ .paren = node };
        },
        else => {
            self.addError("expected expression");
            self.advance();
            return null;
        },
    }
}

fn parseTemplatedConstructor(self: *Parser, name: []const u8) !?Ast.Expr {
    const template_type = try self.parseTemplatedType(name);
    if (self.currentTag() != .l_paren) {
        const node = try self.allocator.create(Ast.IdentExpr);
        node.* = .{ .name = name, .ref = .none };
        return .{ .ident = node };
    }
    self.advance();
    const args = try self.parseExpressionList();
    _ = self.expect(.r_paren);
    const node = try self.allocator.create(Ast.CallExpr);
    node.* = .{ .template_type = template_type, .args = args };
    return .{ .call = node };
}

fn parseExpressionList(self: *Parser) !std.ArrayListUnmanaged(Ast.Expr) {
    var exprs: std.ArrayListUnmanaged(Ast.Expr) = .empty;
    if (self.currentTag() == .r_paren) return exprs;
    if (try self.parseExpression()) |first| {
        try exprs.append(self.allocator, first);
    }
    while (self.eat(.comma)) {
        if (self.currentTag() == .r_paren) break;
        if (try self.parseExpression()) |expr| {
            try exprs.append(self.allocator, expr);
        }
    }
    return exprs;
}

// Template argument expression (restricted: no > or >= operators)
fn parseTemplateArgExpr(self: *Parser) error{OutOfMemory, ParseFailed}!?Ast.Expr {
    return self.parseTemplateAdditiveExpr();
}

fn parseTemplateAdditiveExpr(self: *Parser) !?Ast.Expr {
    var left = (try self.parseTemplateMultiplicativeExpr()) orelse return null;
    while (true) {
        const op: Ast.BinaryOp = switch (self.currentTag()) {
            .plus => .add,
            .minus => .sub,
            else => return left,
        };
        self.advance();
        const right = (try self.parseTemplateMultiplicativeExpr()) orelse return null;
        const node = try self.allocator.create(Ast.BinaryExpr);
        node.* = .{ .op = op, .left = left, .right = right };
        left = .{ .binary = node };
    }
}

fn parseTemplateMultiplicativeExpr(self: *Parser) !?Ast.Expr {
    var left = (try self.parseTemplateUnaryExpr()) orelse return null;
    while (true) {
        const op: Ast.BinaryOp = switch (self.currentTag()) {
            .star => .mul,
            .slash => .div,
            .percent => .mod,
            else => return left,
        };
        self.advance();
        const right = (try self.parseTemplateUnaryExpr()) orelse return null;
        const node = try self.allocator.create(Ast.BinaryExpr);
        node.* = .{ .op = op, .left = left, .right = right };
        left = .{ .binary = node };
    }
}

fn parseTemplateUnaryExpr(self: *Parser) !?Ast.Expr {
    const op: ?Ast.UnaryOp = switch (self.currentTag()) {
        .minus => .neg,
        .bang => .not,
        .tilde => .bit_not,
        else => null,
    };
    if (op) |unary_op| {
        self.advance();
        const operand = (try self.parseTemplateUnaryExpr()) orelse return null;
        const node = try self.allocator.create(Ast.UnaryExpr);
        node.* = .{ .op = unary_op, .operand = operand };
        return .{ .unary = node };
    }
    return self.parseTemplatePrimaryExpr();
}

fn parseTemplatePrimaryExpr(self: *Parser) !?Ast.Expr {
    switch (self.currentTag()) {
        .int_literal, .float_literal, .true_literal, .false_literal => {
            const text = self.currentText();
            const kind = self.currentTag();
            self.advance();
            const node = try self.allocator.create(Ast.LiteralExpr);
            node.* = .{ .kind = kind, .value = text };
            return .{ .literal = node };
        },
        .ident => {
            const text = self.currentText();
            const loc = self.currentStart();
            self.advance();
            const node = try self.allocator.create(Ast.IdentExpr);
            node.* = .{ .loc = loc, .name = text, .ref = .none };
            return .{ .ident = node };
        },
        .l_paren => {
            self.advance();
            const expr = (try self.parseTemplateArgExpr()) orelse return null;
            _ = self.expect(.r_paren);
            const node = try self.allocator.create(Ast.ParenExpr);
            node.* = .{ .expr = expr };
            return .{ .paren = node };
        },
        else => {
            self.addError("expected expression");
            self.advance();
            return null;
        },
    }
}

// =========================================================================
// Statements
// =========================================================================

fn parseStatement(self: *Parser) error{OutOfMemory, ParseFailed}!?Ast.Stmt {
    switch (self.currentTag()) {
        .l_brace => return .{ .compound = try self.parseCompoundStmt() },
        .keyword_return => return .{ .@"return" = try self.parseReturnStmt() },
        .keyword_if => return .{ .@"if" = try self.parseIfStmt() },
        .keyword_switch => return .{ .@"switch" = try self.parseSwitchStmt() },
        .keyword_for => return .{ .@"for" = try self.parseForStmt() },
        .keyword_while => return .{ .@"while" = try self.parseWhileStmt() },
        .keyword_loop => return .{ .loop = try self.parseLoopStmt() },
        .keyword_break => {
            self.advance();
            if (self.eat(.keyword_if)) {
                const cond = (try self.parseExpression()) orelse return null;
                _ = self.expect(.semicolon);
                const node = try self.allocator.create(Ast.BreakIfStmt);
                node.* = .{ .condition = cond };
                return .{ .break_if = node };
            }
            _ = self.expect(.semicolon);
            const node = try self.allocator.create(Ast.BreakStmt);
            node.* = .{};
            return .{ .@"break" = node };
        },
        .keyword_continue => {
            self.advance();
            _ = self.expect(.semicolon);
            const node = try self.allocator.create(Ast.ContinueStmt);
            node.* = .{};
            return .{ .@"continue" = node };
        },
        .keyword_discard => {
            self.advance();
            _ = self.expect(.semicolon);
            const node = try self.allocator.create(Ast.DiscardStmt);
            node.* = .{};
            return .{ .discard = node };
        },
        .keyword_const, .keyword_let, .keyword_var => {
            if (try self.parseDeclaration()) |decl| {
                const node = try self.allocator.create(Ast.DeclStmt);
                node.* = .{ .decl = decl };
                return .{ .decl = node };
            }
            return null;
        },
        else => return self.parseExpressionOrAssignment(),
    }
}

fn parseCompoundStmt(self: *Parser) !*Ast.CompoundStmt {
    _ = self.expect(.l_brace);
    self.pushScope();
    const stmt = try self.allocator.create(Ast.CompoundStmt);
    stmt.* = .{ .stmts = .empty };
    while (self.currentTag() != .r_brace and self.currentTag() != .eof) {
        if (try self.parseStatement()) |s| {
            try stmt.stmts.append(self.allocator, s);
        }
    }
    self.popScope();
    _ = self.expect(.r_brace);
    return stmt;
}

fn parseReturnStmt(self: *Parser) !*Ast.ReturnStmt {
    _ = self.expect(.keyword_return);
    const node = try self.allocator.create(Ast.ReturnStmt);
    node.* = .{};
    if (self.currentTag() != .semicolon) {
        node.value = try self.parseExpression();
    }
    _ = self.expect(.semicolon);
    return node;
}

fn parseIfStmt(self: *Parser) !*Ast.IfStmt {
    _ = self.expect(.keyword_if);
    const node = try self.allocator.create(Ast.IfStmt);
    node.* = .{
        .condition = (try self.parseExpression()) orelse return error.ParseFailed,
        .body = try self.parseCompoundStmt(),
    };
    if (self.eat(.keyword_else)) {
        if (self.currentTag() == .keyword_if) {
            node.else_branch = .{ .@"if" = try self.parseIfStmt() };
        } else {
            node.else_branch = .{ .compound = try self.parseCompoundStmt() };
        }
    }
    return node;
}

fn parseSwitchStmt(self: *Parser) !*Ast.SwitchStmt {
    _ = self.expect(.keyword_switch);
    const node = try self.allocator.create(Ast.SwitchStmt);
    node.* = .{
        .expr = (try self.parseExpression()) orelse return error.ParseFailed,
        .cases = .empty,
    };
    _ = self.expect(.l_brace);
    while (self.currentTag() != .r_brace and self.currentTag() != .eof) {
        var c = Ast.SwitchCase{ .selectors = .empty, .body = undefined };
        if (self.eat(.keyword_default)) {
            // default case
        } else {
            _ = self.expect(.keyword_case);
            if (try self.parseExpression()) |sel| try c.selectors.append(self.allocator, sel);
            while (self.eat(.comma)) {
                if (try self.parseExpression()) |sel| try c.selectors.append(self.allocator, sel);
            }
        }
        _ = self.expect(.colon);
        c.body = try self.parseCompoundStmt();
        try node.cases.append(self.allocator, c);
    }
    _ = self.expect(.r_brace);
    return node;
}

fn parseForStmt(self: *Parser) !*Ast.ForStmt {
    _ = self.expect(.keyword_for);
    _ = self.expect(.l_paren);
    self.pushScope();
    const node = try self.allocator.create(Ast.ForStmt);
    node.* = .{ .body = undefined };

    // Init
    if (self.currentTag() != .semicolon) {
        switch (self.currentTag()) {
            .keyword_var, .keyword_let => {
                if (try self.parseDeclaration()) |decl| {
                    const ds = try self.allocator.create(Ast.DeclStmt);
                    ds.* = .{ .decl = decl };
                    node.init_stmt = .{ .decl = ds };
                }
            },
            else => node.init_stmt = try self.parseExpressionOrAssignment(),
        }
    } else {
        self.advance();
    }

    // Condition
    if (self.currentTag() != .semicolon) {
        node.condition = try self.parseExpression();
    }
    _ = self.expect(.semicolon);

    // Update
    if (self.currentTag() != .r_paren) {
        node.update = try self.parseForUpdateStmt();
    }

    _ = self.expect(.r_paren);
    node.body = try self.parseCompoundStmt();
    self.popScope();
    return node;
}

fn parseForUpdateStmt(self: *Parser) !?Ast.Stmt {
    const left = (try self.parseExpression()) orelse return null;

    // Check for assignment or incr/decr
    switch (self.currentTag()) {
        .plus_plus => {
            self.advance();
            const node = try self.allocator.create(Ast.IncrDecrStmt);
            node.* = .{ .expr = left, .increment = true };
            return .{ .incr_decr = node };
        },
        .minus_minus => {
            self.advance();
            const node = try self.allocator.create(Ast.IncrDecrStmt);
            node.* = .{ .expr = left, .increment = false };
            return .{ .incr_decr = node };
        },
        else => {},
    }

    if (self.parseAssignOp()) |op| {
        self.advance();
        const right = (try self.parseExpression()) orelse return null;
        const node = try self.allocator.create(Ast.AssignStmt);
        node.* = .{ .op = op, .left = left, .right = right };
        return .{ .assign = node };
    }

    // Call expression
    if (left == .call) {
        const node = try self.allocator.create(Ast.CallStmt);
        node.* = .{ .call = left.call };
        return .{ .call = node };
    }

    self.addError("expected for update statement");
    return null;
}

fn parseWhileStmt(self: *Parser) !*Ast.WhileStmt {
    _ = self.expect(.keyword_while);
    const node = try self.allocator.create(Ast.WhileStmt);
    node.* = .{
        .condition = (try self.parseExpression()) orelse return error.ParseFailed,
        .body = try self.parseCompoundStmt(),
    };
    return node;
}

fn parseLoopStmt(self: *Parser) !*Ast.LoopStmt {
    _ = self.expect(.keyword_loop);
    const node = try self.allocator.create(Ast.LoopStmt);
    node.* = .{ .body = try self.parseCompoundStmt() };
    if (self.eat(.keyword_continuing)) {
        node.continuing = try self.parseCompoundStmt();
    }
    return node;
}

fn parseExpressionOrAssignment(self: *Parser) !?Ast.Stmt {
    const left = (try self.parseExpression()) orelse return null;

    switch (self.currentTag()) {
        .plus_plus => {
            self.advance();
            _ = self.expect(.semicolon);
            const node = try self.allocator.create(Ast.IncrDecrStmt);
            node.* = .{ .expr = left, .increment = true };
            return .{ .incr_decr = node };
        },
        .minus_minus => {
            self.advance();
            _ = self.expect(.semicolon);
            const node = try self.allocator.create(Ast.IncrDecrStmt);
            node.* = .{ .expr = left, .increment = false };
            return .{ .incr_decr = node };
        },
        else => {},
    }

    if (self.parseAssignOp()) |op| {
        self.advance();
        const right = (try self.parseExpression()) orelse return null;
        _ = self.expect(.semicolon);
        const node = try self.allocator.create(Ast.AssignStmt);
        node.* = .{ .op = op, .left = left, .right = right };
        return .{ .assign = node };
    }

    _ = self.expect(.semicolon);
    if (left == .call) {
        const node = try self.allocator.create(Ast.CallStmt);
        node.* = .{ .call = left.call };
        return .{ .call = node };
    }

    self.addError("expected statement");
    return null;
}

fn parseAssignOp(self: *const Parser) ?Ast.AssignOp {
    return switch (self.currentTag()) {
        .eq => .simple,
        .plus_eq => .add,
        .minus_eq => .sub,
        .star_eq => .mul,
        .slash_eq => .div,
        .percent_eq => .mod,
        .amp_eq => .@"and",
        .pipe_eq => .@"or",
        .caret_eq => .xor,
        .lt_lt_eq => .shl,
        .gt_gt_eq => .shr,
        else => null,
    };
}

// =========================================================================
// Helpers
// =========================================================================

fn isVecName(name: []const u8) bool {
    return name.len == 4 and std.mem.eql(u8, name[0..3], "vec") and name[3] >= '2' and name[3] <= '4';
}

fn isMatName(name: []const u8) bool {
    return name.len == 6 and std.mem.eql(u8, name[0..3], "mat") and name[4] == 'x';
}

fn isTemplatedTypeName(name: []const u8) bool {
    const map = std.StaticStringMap(void).initComptime(.{
        .{ "array", {} },       .{ "vec2", {} },        .{ "vec3", {} },
        .{ "vec4", {} },        .{ "mat2x2", {} },      .{ "mat2x3", {} },
        .{ "mat2x4", {} },      .{ "mat3x2", {} },      .{ "mat3x3", {} },
        .{ "mat3x4", {} },      .{ "mat4x2", {} },      .{ "mat4x3", {} },
        .{ "mat4x4", {} },      .{ "ptr", {} },          .{ "atomic", {} },
        .{ "texture_1d", {} },   .{ "texture_2d", {} },
        .{ "texture_2d_array", {} }, .{ "texture_3d", {} },
        .{ "texture_cube", {} }, .{ "texture_cube_array", {} },
        .{ "texture_multisampled_2d", {} },
        .{ "texture_storage_1d", {} }, .{ "texture_storage_2d", {} },
        .{ "texture_storage_2d_array", {} }, .{ "texture_storage_3d", {} },
        .{ "sampler", {} },      .{ "sampler_comparison", {} },
        .{ "texture_depth_2d", {} }, .{ "texture_depth_2d_array", {} },
        .{ "texture_depth_cube", {} }, .{ "texture_depth_cube_array", {} },
        .{ "texture_depth_multisampled_2d", {} },
    });
    return map.has(name);
}

// Public access for Lexer helpers used in tokenText
pub const isIdentStart = Lexer.isIdentStart;
pub const isIdentContinue = Lexer.isIdentContinue;
pub const isDigit = Lexer.isDigit;
pub const isHexDigit = Lexer.isHexDigit;

// Expose these for other modules
pub fn isIdentStartFn(c: u8) bool {
    return Lexer.isIdentStart(c);
}

// =========================================================================
// Tests
// =========================================================================

test "parse simple const" {
    const source: [:0]const u8 = "const x = 1;";
    var tokens = try Lexer.tokenize(std.testing.allocator, source);
    defer tokens.deinit(std.testing.allocator);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.init(alloc, source, tokens);
    const module = try parser.parse();
    _ = module;
    try std.testing.expectEqual(@as(usize, 1), parser.symbols.items.len);
    try std.testing.expectEqualStrings("x", parser.symbols.items[0].original_name);
}

pub const Error = error{ParseFailed} || std.mem.Allocator.Error;
