//! miniray — WGSL minifier.
//!
//! Public API re-exports.

pub const Ast = @import("Ast.zig");
pub const Lexer = @import("Lexer.zig");
pub const Parser = @import("Parser.zig");
pub const Printer = @import("Printer.zig");
pub const Renamer = @import("Renamer.zig");
pub const Dce = @import("Dce.zig");
pub const Builtins = @import("Builtins.zig");
pub const Diagnostic = @import("Diagnostic.zig");
pub const Types = @import("Types.zig");
pub const Validator = @import("Validator.zig");
pub const Minifier = @import("Minifier.zig");
pub const Config = @import("Config.zig");
pub const Reflect = @import("Reflect.zig");
pub const SourceMap = @import("SourceMap.zig");

/// Minify WGSL source with default options.
pub fn minify(allocator: @import("std").mem.Allocator, source: [:0]const u8) !Minifier.Result {
    return Minifier.minify(allocator, source, Minifier.defaultOptions());
}

/// Minify WGSL source with custom options.
pub fn minifyWithOptions(allocator: @import("std").mem.Allocator, source: [:0]const u8, options: Minifier.Options) !Minifier.Result {
    return Minifier.minify(allocator, source, options);
}

/// Validate WGSL source with default options.
pub fn validate(allocator: @import("std").mem.Allocator, source: [:0]const u8) !Validator.Result {
    return validateWithOptions(allocator, source, .{});
}

/// Validate WGSL source with custom options.
pub fn validateWithOptions(allocator: @import("std").mem.Allocator, source: [:0]const u8, options: Validator.Options) !Validator.Result {
    const tokens = try Lexer.tokenize(allocator, source);
    var parser = Parser.init(allocator, source, tokens);
    const module = parser.parse() catch {
        const diags = try allocator.create(Diagnostic);
        diags.* = Diagnostic.init(allocator, source);
        for (parser.errors.items) |err| {
            diags.addError(allocator, err.pos, err.message);
        }
        return .{ .valid = false, .diagnostics = diags };
    };
    return Validator.validate(allocator, module, options);
}

/// Minify and reflect in a single pass. The reflection result uses the
/// minified names, so callers can map bindings to the minified output.
pub fn minifyAndReflect(allocator: @import("std").mem.Allocator, source: [:0]const u8, options: Minifier.Options) !Minifier.MinifyAndReflectResult {
    return Minifier.minifyAndReflect(allocator, source, options);
}

/// Reflect WGSL source (extract bindings, layouts, entry points).
pub fn reflect(allocator: @import("std").mem.Allocator, source: [:0]const u8) !Reflect.ReflectResult {
    const tokens = try Lexer.tokenize(allocator, source);
    var parser = Parser.init(allocator, source, tokens);
    const module = parser.parse() catch {
        var result = Reflect.ReflectResult{};
        result.errors.append(allocator, "parse error") catch {};
        return result;
    };
    return Reflect.reflect(allocator, module);
}

// Re-export tests from all modules
comptime {
    _ = Ast;
    _ = Lexer;
    _ = Parser;
    _ = Renamer;
    _ = Builtins;
    _ = Diagnostic;
    _ = Types;
    _ = Validator;
    _ = Reflect;
    _ = SourceMap;
    _ = Dce;
}
