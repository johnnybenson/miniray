//! WGSL tokenizer.
//!
//! Converts WGSL source text into a sequence of tokens using a
//! state-machine approach with comptime lookup tables for fast
//! ASCII classification.

const std = @import("std");
const Ast = @import("Ast.zig");

const Lexer = @This();

source: [:0]const u8,
pos: u32,
tokens: std.MultiArrayList(Token),

pub const Token = struct {
    tag: Tag,
    start: u32,
};

/// Token tags. Values ≤ keyword_end are keywords, used for StaticStringMap.
pub const Tag = enum(u8) {
    // Sentinel / error
    eof,
    @"error",

    // Literals
    int_literal,
    float_literal,
    true_literal,
    false_literal,

    // Identifier
    ident,

    // Keywords (order must match keywords_map entries)
    keyword_alias,
    keyword_break,
    keyword_case,
    keyword_const,
    keyword_const_assert,
    keyword_continue,
    keyword_continuing,
    keyword_default,
    keyword_diagnostic,
    keyword_discard,
    keyword_else,
    keyword_enable,
    keyword_fn,
    keyword_for,
    keyword_if,
    keyword_let,
    keyword_loop,
    keyword_override,
    keyword_requires,
    keyword_return,
    keyword_struct,
    keyword_switch,
    keyword_var,
    keyword_while,

    // Single-char operators
    plus,
    minus,
    star,
    slash,
    percent,
    amp,
    pipe,
    caret,
    tilde,
    bang,
    lt,
    gt,
    eq,
    dot,
    at,

    // Multi-char operators
    plus_plus,
    minus_minus,
    amp_amp,
    pipe_pipe,
    lt_lt,
    gt_gt,
    lt_eq,
    gt_eq,
    eq_eq,
    bang_eq,
    arrow,
    plus_eq,
    minus_eq,
    star_eq,
    slash_eq,
    percent_eq,
    amp_eq,
    pipe_eq,
    caret_eq,
    lt_lt_eq,
    gt_gt_eq,

    // Delimiters
    l_paren,
    r_paren,
    l_brace,
    r_brace,
    l_bracket,
    r_bracket,
    semicolon,
    colon,
    comma,
    underscore,

    // Template delimiters (context-sensitive, reserved for future use)
    template_args_start,
    template_args_end,

    pub fn symbol(self: Tag) []const u8 {
        return symbols_table[@intFromEnum(self)];
    }

    const symbols_table = init_symbols_table();

    fn init_symbols_table() [std.meta.fields(Tag).len][]const u8 {
        var result: [std.meta.fields(Tag).len][]const u8 = undefined;
        for (std.meta.fields(Tag)) |field| {
            result[field.value] = field.name;
        }
        // Override with readable symbols
        result[@intFromEnum(Tag.plus)] = "+";
        result[@intFromEnum(Tag.minus)] = "-";
        result[@intFromEnum(Tag.star)] = "*";
        result[@intFromEnum(Tag.slash)] = "/";
        result[@intFromEnum(Tag.percent)] = "%";
        result[@intFromEnum(Tag.amp)] = "&";
        result[@intFromEnum(Tag.pipe)] = "|";
        result[@intFromEnum(Tag.caret)] = "^";
        result[@intFromEnum(Tag.tilde)] = "~";
        result[@intFromEnum(Tag.bang)] = "!";
        result[@intFromEnum(Tag.lt)] = "<";
        result[@intFromEnum(Tag.gt)] = ">";
        result[@intFromEnum(Tag.eq)] = "=";
        result[@intFromEnum(Tag.dot)] = ".";
        result[@intFromEnum(Tag.at)] = "@";
        result[@intFromEnum(Tag.plus_plus)] = "++";
        result[@intFromEnum(Tag.minus_minus)] = "--";
        result[@intFromEnum(Tag.amp_amp)] = "&&";
        result[@intFromEnum(Tag.pipe_pipe)] = "||";
        result[@intFromEnum(Tag.lt_lt)] = "<<";
        result[@intFromEnum(Tag.gt_gt)] = ">>";
        result[@intFromEnum(Tag.lt_eq)] = "<=";
        result[@intFromEnum(Tag.gt_eq)] = ">=";
        result[@intFromEnum(Tag.eq_eq)] = "==";
        result[@intFromEnum(Tag.bang_eq)] = "!=";
        result[@intFromEnum(Tag.arrow)] = "->";
        result[@intFromEnum(Tag.plus_eq)] = "+=";
        result[@intFromEnum(Tag.minus_eq)] = "-=";
        result[@intFromEnum(Tag.star_eq)] = "*=";
        result[@intFromEnum(Tag.slash_eq)] = "/=";
        result[@intFromEnum(Tag.percent_eq)] = "%=";
        result[@intFromEnum(Tag.amp_eq)] = "&=";
        result[@intFromEnum(Tag.pipe_eq)] = "|=";
        result[@intFromEnum(Tag.caret_eq)] = "^=";
        result[@intFromEnum(Tag.lt_lt_eq)] = "<<=";
        result[@intFromEnum(Tag.gt_gt_eq)] = ">>=";
        result[@intFromEnum(Tag.l_paren)] = "(";
        result[@intFromEnum(Tag.r_paren)] = ")";
        result[@intFromEnum(Tag.l_brace)] = "{";
        result[@intFromEnum(Tag.r_brace)] = "}";
        result[@intFromEnum(Tag.l_bracket)] = "[";
        result[@intFromEnum(Tag.r_bracket)] = "]";
        result[@intFromEnum(Tag.semicolon)] = ";";
        result[@intFromEnum(Tag.colon)] = ":";
        result[@intFromEnum(Tag.comma)] = ",";
        result[@intFromEnum(Tag.underscore)] = "_";
        return result;
    }
};

// -------------------------------------------------------------------------
// Comptime lookup tables
// -------------------------------------------------------------------------

const ident_start_table: [128]bool = blk: {
    var table = [_]bool{false} ** 128;
    for ('a'..('z' + 1)) |c| {
        table[c] = true;
    }
    for ('A'..('Z' + 1)) |c| {
        table[c] = true;
    }
    table['_'] = true;
    break :blk table;
};

const ident_continue_table: [128]bool = blk: {
    var table = ident_start_table;
    for ('0'..('9' + 1)) |c| {
        table[c] = true;
    }
    break :blk table;
};

pub fn isIdentStart(c: u8) bool {
    return c < 128 and ident_start_table[c];
}

pub fn isIdentContinue(c: u8) bool {
    return c < 128 and ident_continue_table[c];
}

pub fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

pub fn isHexDigit(c: u8) bool {
    return isDigit(c) or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

// -------------------------------------------------------------------------
// Keyword map (comptime StaticStringMap)
// -------------------------------------------------------------------------

pub const keywords_map = std.StaticStringMap(Tag).initComptime(.{
    .{ "alias", .keyword_alias },
    .{ "break", .keyword_break },
    .{ "case", .keyword_case },
    .{ "const", .keyword_const },
    .{ "const_assert", .keyword_const_assert },
    .{ "continue", .keyword_continue },
    .{ "continuing", .keyword_continuing },
    .{ "default", .keyword_default },
    .{ "diagnostic", .keyword_diagnostic },
    .{ "discard", .keyword_discard },
    .{ "else", .keyword_else },
    .{ "enable", .keyword_enable },
    .{ "false", .false_literal },
    .{ "fn", .keyword_fn },
    .{ "for", .keyword_for },
    .{ "if", .keyword_if },
    .{ "let", .keyword_let },
    .{ "loop", .keyword_loop },
    .{ "override", .keyword_override },
    .{ "requires", .keyword_requires },
    .{ "return", .keyword_return },
    .{ "struct", .keyword_struct },
    .{ "switch", .keyword_switch },
    .{ "true", .true_literal },
    .{ "var", .keyword_var },
    .{ "while", .keyword_while },
});

pub const reserved_words = std.StaticStringMap(void).initComptime(.{
    .{ "NULL", {} },     .{ "Self", {} },          .{ "abstract", {} },
    .{ "active", {} },   .{ "alignas", {} },       .{ "alignof", {} },
    .{ "as", {} },       .{ "asm", {} },            .{ "asm_fragment", {} },
    .{ "async", {} },    .{ "attribute", {} },      .{ "auto", {} },
    .{ "await", {} },    .{ "become", {} },         .{ "cast", {} },
    .{ "catch", {} },    .{ "class", {} },          .{ "co_await", {} },
    .{ "co_return", {} }, .{ "co_yield", {} },      .{ "coherent", {} },
    .{ "column_major", {} }, .{ "common", {} },     .{ "compile", {} },
    .{ "compile_fragment", {} }, .{ "concept", {} }, .{ "const_cast", {} },
    .{ "consteval", {} }, .{ "constexpr", {} },     .{ "constinit", {} },
    .{ "crate", {} },    .{ "debugger", {} },       .{ "decltype", {} },
    .{ "delete", {} },   .{ "demote", {} },         .{ "demote_to_helper", {} },
    .{ "do", {} },       .{ "dynamic_cast", {} },   .{ "enum", {} },
    .{ "explicit", {} }, .{ "export", {} },         .{ "extends", {} },
    .{ "extern", {} },   .{ "external", {} },       .{ "fallthrough", {} },
    .{ "filter", {} },   .{ "final", {} },          .{ "finally", {} },
    .{ "friend", {} },   .{ "from", {} },           .{ "fxgroup", {} },
    .{ "get", {} },      .{ "goto", {} },           .{ "groupshared", {} },
    .{ "highp", {} },    .{ "impl", {} },           .{ "implements", {} },
    .{ "import", {} },   .{ "inline", {} },         .{ "instanceof", {} },
    .{ "interface", {} }, .{ "layout", {} },         .{ "lowp", {} },
    .{ "macro", {} },    .{ "macro_rules", {} },    .{ "match", {} },
    .{ "mediump", {} },  .{ "meta", {} },           .{ "mod", {} },
    .{ "module", {} },   .{ "move", {} },           .{ "mut", {} },
    .{ "mutable", {} },  .{ "namespace", {} },      .{ "new", {} },
    .{ "nil", {} },      .{ "noexcept", {} },       .{ "noinline", {} },
    .{ "nointerpolation", {} }, .{ "non_coherent", {} }, .{ "noncoherent", {} },
    .{ "noperspective", {} }, .{ "null", {} },      .{ "nullptr", {} },
    .{ "of", {} },       .{ "operator", {} },       .{ "package", {} },
    .{ "packoffset", {} }, .{ "partition", {} },    .{ "pass", {} },
    .{ "patch", {} },    .{ "pixelfragment", {} },  .{ "precise", {} },
    .{ "precision", {} }, .{ "premerge", {} },      .{ "priv", {} },
    .{ "protected", {} }, .{ "pub", {} },           .{ "public", {} },
    .{ "readonly", {} }, .{ "ref", {} },            .{ "regardless", {} },
    .{ "register", {} }, .{ "reinterpret_cast", {} }, .{ "require", {} },
    .{ "resource", {} }, .{ "restrict", {} },       .{ "self", {} },
    .{ "set", {} },      .{ "shared", {} },         .{ "sizeof", {} },
    .{ "smooth", {} },   .{ "snorm", {} },          .{ "static", {} },
    .{ "static_assert", {} }, .{ "static_cast", {} }, .{ "std", {} },
    .{ "subroutine", {} }, .{ "super", {} },        .{ "target", {} },
    .{ "template", {} }, .{ "this", {} },           .{ "thread_local", {} },
    .{ "throw", {} },    .{ "trait", {} },          .{ "try", {} },
    .{ "type", {} },     .{ "typedef", {} },        .{ "typeid", {} },
    .{ "typename", {} }, .{ "typeof", {} },         .{ "union", {} },
    .{ "unless", {} },   .{ "unorm", {} },          .{ "unsafe", {} },
    .{ "unsized", {} },  .{ "use", {} },            .{ "using", {} },
    .{ "varying", {} },  .{ "virtual", {} },        .{ "volatile", {} },
    .{ "wgsl", {} },     .{ "where", {} },          .{ "with", {} },
    .{ "writeonly", {} }, .{ "yield", {} },
});

// -------------------------------------------------------------------------
// Initialization
// -------------------------------------------------------------------------

pub fn init(source: [:0]const u8) Lexer {
    return .{
        .source = source,
        .pos = 0,
        .tokens = std.MultiArrayList(Token){},
    };
}

/// Tokenize the entire source, returning owned token storage.
/// Caller must call `deinit` on the returned Lexer to free memory.
pub fn tokenize(allocator: std.mem.Allocator, source: [:0]const u8) !std.MultiArrayList(Token) {
    var lex = Lexer{
        .source = source,
        .pos = 0,
        .tokens = .empty,
    };

    // Pre-estimate capacity: ~1 token per 8 source bytes
    const estimated = @max(source.len / 8, 16);
    try lex.tokens.ensureTotalCapacity(allocator, estimated);

    while (true) {
        const tag = lex.next();
        try lex.tokens.append(allocator, .{ .tag = tag.tag, .start = tag.start });
        if (tag.tag == .eof or tag.tag == .@"error") break;
    }

    return lex.tokens;
}

// -------------------------------------------------------------------------
// Core scanning
// -------------------------------------------------------------------------

const TokenResult = struct { tag: Tag, start: u32 };

fn next(self: *Lexer) TokenResult {
    self.skipWhitespaceAndComments();

    if (self.pos >= self.source.len) {
        return .{ .tag = .eof, .start = self.pos };
    }

    const start = self.pos;
    const ch = self.source[self.pos];

    // Identifiers and keywords
    if (isIdentStart(ch)) {
        return self.scanIdentOrKeyword(start);
    }

    // Numbers
    if (isDigit(ch) or (ch == '.' and self.pos + 1 < self.source.len and isDigit(self.source[self.pos + 1]))) {
        return self.scanNumber(start);
    }

    // Operators and punctuation
    return self.scanOperator(start);
}

fn skipWhitespaceAndComments(self: *Lexer) void {
    while (self.pos < self.source.len) {
        const ch = self.source[self.pos];

        // Fast path: space and newline
        if (ch == ' ' or ch == '\n') {
            self.pos += 1;
            continue;
        }
        if (ch == '\t' or ch == '\r') {
            self.pos += 1;
            continue;
        }

        // Line comment
        if (ch == '/' and self.pos + 1 < self.source.len and self.source[self.pos + 1] == '/') {
            self.pos += 2;
            while (self.pos < self.source.len and self.source[self.pos] != '\n') {
                self.pos += 1;
            }
            continue;
        }

        // Block comment (nested)
        if (ch == '/' and self.pos + 1 < self.source.len and self.source[self.pos + 1] == '*') {
            self.pos += 2;
            var depth: u32 = 1;
            while (self.pos + 1 < self.source.len and depth > 0) {
                const c = self.source[self.pos];
                if (c == '/' and self.source[self.pos + 1] == '*') {
                    depth += 1;
                    self.pos += 2;
                } else if (c == '*' and self.source[self.pos + 1] == '/') {
                    depth -= 1;
                    self.pos += 2;
                } else {
                    self.pos += 1;
                }
            }
            continue;
        }

        break;
    }
}

fn scanIdentOrKeyword(self: *Lexer, start: u32) TokenResult {
    // Scan ASCII identifier characters
    while (self.pos < self.source.len and isIdentContinue(self.source[self.pos])) {
        self.pos += 1;
    }

    const text = self.source[start..self.pos];

    // Check keywords
    if (keywords_map.get(text)) |kw_tag| {
        return .{ .tag = kw_tag, .start = start };
    }

    // Single underscore
    if (text.len == 1 and text[0] == '_') {
        return .{ .tag = .underscore, .start = start };
    }

    // Reserved words
    if (reserved_words.has(text)) {
        return .{ .tag = .@"error", .start = start };
    }

    // Double underscore prefix
    if (text.len >= 2 and text[0] == '_' and text[1] == '_') {
        return .{ .tag = .@"error", .start = start };
    }

    return .{ .tag = .ident, .start = start };
}

fn scanNumber(self: *Lexer, start: u32) TokenResult {
    var kind: Tag = .int_literal;

    // Hex
    if (self.pos + 1 < self.source.len and self.source[self.pos] == '0' and
        (self.source[self.pos + 1] == 'x' or self.source[self.pos + 1] == 'X'))
    {
        self.pos += 2;
        while (self.pos < self.source.len and isHexDigit(self.source[self.pos])) self.pos += 1;
        // Hex float
        if (self.pos < self.source.len and self.source[self.pos] == '.') {
            kind = .float_literal;
            self.pos += 1;
            while (self.pos < self.source.len and isHexDigit(self.source[self.pos])) self.pos += 1;
        }
        // Hex exponent
        if (self.pos < self.source.len and (self.source[self.pos] == 'p' or self.source[self.pos] == 'P')) {
            kind = .float_literal;
            self.pos += 1;
            if (self.pos < self.source.len and (self.source[self.pos] == '+' or self.source[self.pos] == '-')) self.pos += 1;
            while (self.pos < self.source.len and isDigit(self.source[self.pos])) self.pos += 1;
        }
    } else {
        // Decimal integer part
        while (self.pos < self.source.len and isDigit(self.source[self.pos])) self.pos += 1;
        // Decimal point
        if (self.pos < self.source.len and self.source[self.pos] == '.') {
            const next_is_digit = self.pos + 1 < self.source.len and isDigit(self.source[self.pos + 1]);
            const next_is_ident = self.pos + 1 < self.source.len and isIdentStart(self.source[self.pos + 1]);
            const at_end = self.pos + 1 >= self.source.len;

            if (next_is_digit or at_end or !next_is_ident) {
                kind = .float_literal;
                self.pos += 1;
                while (self.pos < self.source.len and isDigit(self.source[self.pos])) self.pos += 1;
            }
        }
        // Exponent
        if (self.pos < self.source.len and (self.source[self.pos] == 'e' or self.source[self.pos] == 'E')) {
            kind = .float_literal;
            self.pos += 1;
            if (self.pos < self.source.len and (self.source[self.pos] == '+' or self.source[self.pos] == '-')) self.pos += 1;
            while (self.pos < self.source.len and isDigit(self.source[self.pos])) self.pos += 1;
        }
    }

    // Type suffix
    if (self.pos < self.source.len) {
        const ch = self.source[self.pos];
        if (ch == 'i' or ch == 'u') {
            self.pos += 1;
        } else if (ch == 'f' or ch == 'h') {
            kind = .float_literal;
            self.pos += 1;
        }
    }

    return .{ .tag = kind, .start = start };
}

fn scanOperator(self: *Lexer, start: u32) TokenResult {
    const ch = self.source[self.pos];
    self.pos += 1;

    const next_ch: u8 = if (self.pos < self.source.len) self.source[self.pos] else 0;

    switch (ch) {
        '+' => {
            if (next_ch == '+') { self.pos += 1; return .{ .tag = .plus_plus, .start = start }; }
            if (next_ch == '=') { self.pos += 1; return .{ .tag = .plus_eq, .start = start }; }
            return .{ .tag = .plus, .start = start };
        },
        '-' => {
            if (next_ch == '-') { self.pos += 1; return .{ .tag = .minus_minus, .start = start }; }
            if (next_ch == '=') { self.pos += 1; return .{ .tag = .minus_eq, .start = start }; }
            if (next_ch == '>') { self.pos += 1; return .{ .tag = .arrow, .start = start }; }
            return .{ .tag = .minus, .start = start };
        },
        '*' => {
            if (next_ch == '=') { self.pos += 1; return .{ .tag = .star_eq, .start = start }; }
            return .{ .tag = .star, .start = start };
        },
        '/' => {
            if (next_ch == '=') { self.pos += 1; return .{ .tag = .slash_eq, .start = start }; }
            return .{ .tag = .slash, .start = start };
        },
        '%' => {
            if (next_ch == '=') { self.pos += 1; return .{ .tag = .percent_eq, .start = start }; }
            return .{ .tag = .percent, .start = start };
        },
        '&' => {
            if (next_ch == '&') { self.pos += 1; return .{ .tag = .amp_amp, .start = start }; }
            if (next_ch == '=') { self.pos += 1; return .{ .tag = .amp_eq, .start = start }; }
            return .{ .tag = .amp, .start = start };
        },
        '|' => {
            if (next_ch == '|') { self.pos += 1; return .{ .tag = .pipe_pipe, .start = start }; }
            if (next_ch == '=') { self.pos += 1; return .{ .tag = .pipe_eq, .start = start }; }
            return .{ .tag = .pipe, .start = start };
        },
        '^' => {
            if (next_ch == '=') { self.pos += 1; return .{ .tag = .caret_eq, .start = start }; }
            return .{ .tag = .caret, .start = start };
        },
        '<' => {
            if (next_ch == '<') {
                self.pos += 1;
                if (self.pos < self.source.len and self.source[self.pos] == '=') {
                    self.pos += 1;
                    return .{ .tag = .lt_lt_eq, .start = start };
                }
                return .{ .tag = .lt_lt, .start = start };
            }
            if (next_ch == '=') { self.pos += 1; return .{ .tag = .lt_eq, .start = start }; }
            return .{ .tag = .lt, .start = start };
        },
        '>' => {
            if (next_ch == '>') {
                self.pos += 1;
                if (self.pos < self.source.len and self.source[self.pos] == '=') {
                    self.pos += 1;
                    return .{ .tag = .gt_gt_eq, .start = start };
                }
                return .{ .tag = .gt_gt, .start = start };
            }
            if (next_ch == '=') { self.pos += 1; return .{ .tag = .gt_eq, .start = start }; }
            return .{ .tag = .gt, .start = start };
        },
        '=' => {
            if (next_ch == '=') { self.pos += 1; return .{ .tag = .eq_eq, .start = start }; }
            return .{ .tag = .eq, .start = start };
        },
        '!' => {
            if (next_ch == '=') { self.pos += 1; return .{ .tag = .bang_eq, .start = start }; }
            return .{ .tag = .bang, .start = start };
        },
        '~' => return .{ .tag = .tilde, .start = start },
        '.' => return .{ .tag = .dot, .start = start },
        '@' => return .{ .tag = .at, .start = start },
        '(' => return .{ .tag = .l_paren, .start = start },
        ')' => return .{ .tag = .r_paren, .start = start },
        '{' => return .{ .tag = .l_brace, .start = start },
        '}' => return .{ .tag = .r_brace, .start = start },
        '[' => return .{ .tag = .l_bracket, .start = start },
        ']' => return .{ .tag = .r_bracket, .start = start },
        ';' => return .{ .tag = .semicolon, .start = start },
        ':' => return .{ .tag = .colon, .start = start },
        ',' => return .{ .tag = .comma, .start = start },
        else => return .{ .tag = .@"error", .start = start },
    }
}

// -------------------------------------------------------------------------
// Public helpers
// -------------------------------------------------------------------------

/// Return the source text for the token at `index`.
pub fn tokenText(self: *const Lexer, index: u32) []const u8 {
    const tags = self.tokens.items(.tag);
    const starts = self.tokens.items(.start);
    const start = starts[index];

    // End is the start of the next token, or the token's own scan end
    if (index + 1 < self.tokens.len) {
        // Walk backwards from next token start to skip whitespace/comments
        const next_start = starts[index + 1];
        // For a precise end, we re-scan from start
        return self.retokenizeEnd(start, tags[index], next_start);
    }
    return self.retokenizeEnd(start, tags[index], @intCast(self.source.len));
}

/// Re-scan to find the end of a token given its start position and tag.
fn retokenizeEnd(self: *const Lexer, start: u32, tag: Tag, bound: u32) []const u8 {
    _ = tag;
    var pos = start;
    const src = self.source;

    if (pos >= src.len) return "";

    const ch = src[pos];

    // Identifier/keyword
    if (isIdentStart(ch)) {
        pos += 1;
        while (pos < bound and pos < src.len and isIdentContinue(src[pos])) pos += 1;
        return src[start..pos];
    }

    // Number
    if (isDigit(ch) or (ch == '.' and pos + 1 < src.len and isDigit(src[pos + 1]))) {
        // Hex
        if (pos + 1 < src.len and src[pos] == '0' and (src[pos + 1] == 'x' or src[pos + 1] == 'X')) {
            pos += 2;
            while (pos < src.len and isHexDigit(src[pos])) pos += 1;
            if (pos < src.len and src[pos] == '.') {
                pos += 1;
                while (pos < src.len and isHexDigit(src[pos])) pos += 1;
            }
            if (pos < src.len and (src[pos] == 'p' or src[pos] == 'P')) {
                pos += 1;
                if (pos < src.len and (src[pos] == '+' or src[pos] == '-')) pos += 1;
                while (pos < src.len and isDigit(src[pos])) pos += 1;
            }
        } else {
            while (pos < src.len and isDigit(src[pos])) pos += 1;
            if (pos < src.len and src[pos] == '.') {
                const nid = pos + 1 < src.len and isDigit(src[pos + 1]);
                const nie = pos + 1 < src.len and isIdentStart(src[pos + 1]);
                const ae = pos + 1 >= src.len;
                if (nid or ae or !nie) {
                    pos += 1;
                    while (pos < src.len and isDigit(src[pos])) pos += 1;
                }
            }
            if (pos < src.len and (src[pos] == 'e' or src[pos] == 'E')) {
                pos += 1;
                if (pos < src.len and (src[pos] == '+' or src[pos] == '-')) pos += 1;
                while (pos < src.len and isDigit(src[pos])) pos += 1;
            }
        }
        // Type suffix
        if (pos < src.len and (src[pos] == 'i' or src[pos] == 'u' or src[pos] == 'f' or src[pos] == 'h')) {
            pos += 1;
        }
        return src[start..pos];
    }

    // Operator - just return up to 3 chars matching the operator
    pos += 1;
    const nc: u8 = if (pos < src.len) src[pos] else 0;
    switch (ch) {
        '+' => if (nc == '+' or nc == '=') { pos += 1; },
        '-' => if (nc == '-' or nc == '=' or nc == '>') { pos += 1; },
        '*', '/', '%' => if (nc == '=') { pos += 1; },
        '&' => if (nc == '&' or nc == '=') { pos += 1; },
        '|' => if (nc == '|' or nc == '=') { pos += 1; },
        '^' => if (nc == '=') { pos += 1; },
        '<' => {
            if (nc == '<') { pos += 1; if (pos < src.len and src[pos] == '=') pos += 1; } else if (nc == '=') { pos += 1; }
        },
        '>' => {
            if (nc == '>') { pos += 1; if (pos < src.len and src[pos] == '=') pos += 1; } else if (nc == '=') { pos += 1; }
        },
        '=', '!' => if (nc == '=') { pos += 1; },
        else => {},
    }
    return src[start..pos];
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

test "tokenize simple" {
    const source: [:0]const u8 = "fn main() {}";
    var tokens = try tokenize(std.testing.allocator, source);
    defer tokens.deinit(std.testing.allocator);

    const tags = tokens.items(.tag);
    try std.testing.expectEqual(Tag.keyword_fn, tags[0]);
    try std.testing.expectEqual(Tag.ident, tags[1]);
    try std.testing.expectEqual(Tag.l_paren, tags[2]);
    try std.testing.expectEqual(Tag.r_paren, tags[3]);
    try std.testing.expectEqual(Tag.l_brace, tags[4]);
    try std.testing.expectEqual(Tag.r_brace, tags[5]);
    try std.testing.expectEqual(Tag.eof, tags[6]);
}

test "tokenize operators" {
    const source: [:0]const u8 = "++ -- && || << >> <= >= == != -> += -= *= /= %= &= |= ^= <<= >>=";
    var tokens = try tokenize(std.testing.allocator, source);
    defer tokens.deinit(std.testing.allocator);
    const tags = tokens.items(.tag);
    try std.testing.expectEqual(Tag.plus_plus, tags[0]);
    try std.testing.expectEqual(Tag.minus_minus, tags[1]);
    try std.testing.expectEqual(Tag.amp_amp, tags[2]);
    try std.testing.expectEqual(Tag.pipe_pipe, tags[3]);
    try std.testing.expectEqual(Tag.lt_lt, tags[4]);
    try std.testing.expectEqual(Tag.gt_gt, tags[5]);
    try std.testing.expectEqual(Tag.lt_eq, tags[6]);
    try std.testing.expectEqual(Tag.gt_eq, tags[7]);
    try std.testing.expectEqual(Tag.eq_eq, tags[8]);
    try std.testing.expectEqual(Tag.bang_eq, tags[9]);
    try std.testing.expectEqual(Tag.arrow, tags[10]);
}

test "tokenize nested block comment" {
    const source: [:0]const u8 = "/* outer /* inner */ still comment */ fn";
    var tokens = try tokenize(std.testing.allocator, source);
    defer tokens.deinit(std.testing.allocator);
    const tags = tokens.items(.tag);
    try std.testing.expectEqual(Tag.keyword_fn, tags[0]);
    try std.testing.expectEqual(Tag.eof, tags[1]);
}

test "tokenize keywords" {
    const source: [:0]const u8 = "const var let fn struct alias override return if else for while loop break continue discard switch case default";
    var tokens = try tokenize(std.testing.allocator, source);
    defer tokens.deinit(std.testing.allocator);
    const tags = tokens.items(.tag);
    try std.testing.expectEqual(Tag.keyword_const, tags[0]);
    try std.testing.expectEqual(Tag.keyword_var, tags[1]);
    try std.testing.expectEqual(Tag.keyword_let, tags[2]);
    try std.testing.expectEqual(Tag.keyword_fn, tags[3]);
}

test "fuzz lexer no crash" {
    try std.testing.fuzz({}, struct {
        fn testOne(_: void, smith: *std.testing.Smith) !void {
            @disableInstrumentation();
            var buf: [256]u8 = undefined;
            const len = smith.slice(buf[0 .. buf.len - 1]);
            buf[len] = 0;
            const source: [:0]const u8 = buf[0..len :0];
            var tokens = tokenize(std.testing.allocator, source) catch return;
            defer tokens.deinit(std.testing.allocator);
            // Verify all token starts are within source bounds
            for (tokens.items(.start)) |start| {
                try std.testing.expect(start <= source.len);
            }
            // Last token must be eof or error
            const tags = tokens.items(.tag);
            if (tags.len > 0) {
                const last = tags[tags.len - 1];
                try std.testing.expect(last == .eof or last == .@"error");
            }
        }
    }.testOne, .{
        .corpus = &.{
            "fn main() {}",
            "/* nested /* comment */ */",
            "var<storage, read_write> x: f32 = 1.0;",
            "++--&&||<<>>",
        },
    });
}

test "tokenize numbers" {
    const source: [:0]const u8 = "42 3.14 0xFF 1e10 0.5f 1u 2i";
    var tokens = try tokenize(std.testing.allocator, source);
    defer tokens.deinit(std.testing.allocator);
    const tags = tokens.items(.tag);
    try std.testing.expectEqual(Tag.int_literal, tags[0]);
    try std.testing.expectEqual(Tag.float_literal, tags[1]);
    try std.testing.expectEqual(Tag.int_literal, tags[2]); // 0xFF
    try std.testing.expectEqual(Tag.float_literal, tags[3]); // 1e10
    try std.testing.expectEqual(Tag.float_literal, tags[4]); // 0.5f
    try std.testing.expectEqual(Tag.int_literal, tags[5]); // 1u
    try std.testing.expectEqual(Tag.int_literal, tags[6]); // 2i
}
