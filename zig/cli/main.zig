const std = @import("std");
const miniray = @import("miniray");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;
    const Dir = std.Io.Dir;
    const File = std.Io.File;

    var input_path: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;
    var config_path: ?[]const u8 = null;
    var options = miniray.Minifier.defaultOptions();
    var cli_no_mangle = false;
    var cli_no_tree_shaking = false;
    var source_map = false;
    var source_map_inline = false;
    var source_map_sources = false;
    var keep_names_raw: ?[]const u8 = null;
    var subcommand: enum { minify, validate, reflect } = .minify;

    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    _ = args_iter.skip(); // skip program name
    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "validate")) {
            subcommand = .validate;
        } else if (std.mem.eql(u8, arg, "reflect")) {
            subcommand = .reflect;
        } else if (std.mem.eql(u8, arg, "-o")) {
            output_path = args_iter.next();
        } else if (std.mem.eql(u8, arg, "--config")) {
            config_path = args_iter.next();
        } else if (std.mem.eql(u8, arg, "--no-mangle")) {
            cli_no_mangle = true;
        } else if (std.mem.eql(u8, arg, "--mangle-external-bindings")) {
            options.mangle_external_bindings = true;
        } else if (std.mem.eql(u8, arg, "--no-tree-shaking")) {
            cli_no_tree_shaking = true;
        } else if (std.mem.eql(u8, arg, "--preserve-uniform-struct-types")) {
            options.preserve_uniform_struct_types = true;
        } else if (std.mem.eql(u8, arg, "--source-map")) {
            source_map = true;
        } else if (std.mem.eql(u8, arg, "--source-map-inline")) {
            source_map_inline = true;
        } else if (std.mem.eql(u8, arg, "--source-map-sources")) {
            source_map_sources = true;
        } else if (std.mem.eql(u8, arg, "--keep-names")) {
            keep_names_raw = args_iter.next();
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try File.stdout().writeStreamingAll(io, usage_text);
            return;
        } else if (arg.len > 0 and arg[0] != '-') {
            input_path = arg;
        }
    }

    // Load config file if specified
    if (config_path) |path| {
        const content = Dir.cwd().readFileAlloc(io, path, allocator, .unlimited) catch {
            try File.stderr().writeStreamingAll(io, "error: could not read config file\n");
            return;
        };
        const config = miniray.Config.parseJson(allocator, content) catch {
            try File.stderr().writeStreamingAll(io, "error: invalid config JSON\n");
            return;
        };
        options = config.toOptions();
    }

    // CLI overrides
    if (cli_no_mangle) options.minify_identifiers = false;
    if (cli_no_tree_shaking) options.tree_shaking = false;

    // Parse --keep-names (comma-separated)
    if (keep_names_raw) |raw| {
        var names: std.ArrayListUnmanaged([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, raw, ',');
        while (it.next()) |name| {
            const trimmed = std.mem.trim(u8, name, " ");
            if (trimmed.len > 0) {
                names.append(allocator, trimmed) catch {};
            }
        }
        options.keep_names = names.items;
    }

    // Configure source map options
    const generate_source_map = source_map or source_map_inline;
    if (generate_source_map) {
        options.generate_source_map = true;
        options.source_map_options.include_source = source_map_sources;
        if (input_path) |path| {
            options.source_map_options.source_name = std.fs.path.basename(path);
        }
        if (output_path) |path| {
            options.source_map_options.file = std.fs.path.basename(path);
        }
    }

    // Read input
    const source = try readSource(allocator, io, input_path);

    switch (subcommand) {
        .validate => try runValidate(allocator, io, source),
        .reflect => try runReflect(allocator, io, source),
        .minify => try runMinify(allocator, io, source, options, output_path, source_map, source_map_inline),
    }
}

fn readSource(allocator: std.mem.Allocator, io: std.Io, input_path: ?[]const u8) ![:0]const u8 {
    var source_bytes: []u8 = undefined;
    if (input_path) |path| {
        source_bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
    } else {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        var tmp: [4096]u8 = undefined;
        while (true) {
            const n = std.Io.File.stdin().readStreaming(io, &.{&tmp}) catch break;
            if (n == 0) break;
            try buf.appendSlice(allocator, tmp[0..n]);
        }
        source_bytes = buf.items;
    }
    const sb = try allocator.alloc(u8, source_bytes.len + 1);
    @memcpy(sb[0..source_bytes.len], source_bytes);
    sb[source_bytes.len] = 0;
    return sb[0..source_bytes.len :0];
}

fn runMinify(allocator: std.mem.Allocator, io: std.Io, source: [:0]const u8, options: miniray.Minifier.Options, output_path: ?[]const u8, ext_source_map: bool, source_map_inline: bool) !void {
    const result = try miniray.minifyWithOptions(allocator, source, options);
    const File = std.Io.File;
    const Dir = std.Io.Dir;

    if (output_path) |path| {
        const file = try Dir.cwd().createFile(io, path, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, result.code);

        // Append inline source map comment
        if (source_map_inline) {
            if (result.source_map) |sm| {
                var comment_buf: std.ArrayListUnmanaged(u8) = .empty;
                comment_buf.append(allocator, '\n') catch {};
                sm.toComment(&comment_buf, allocator, true);
                try file.writeStreamingAll(io, comment_buf.items);
            }
        }
    } else {
        try File.stdout().writeStreamingAll(io, result.code);

        // Append inline source map comment to stdout
        if (source_map_inline) {
            if (result.source_map) |sm| {
                var comment_buf: std.ArrayListUnmanaged(u8) = .empty;
                comment_buf.append(allocator, '\n') catch {};
                sm.toComment(&comment_buf, allocator, true);
                try File.stdout().writeStreamingAll(io, comment_buf.items);
            }
        }
    }

    // Write external source map file
    if (ext_source_map and !source_map_inline) {
        if (result.source_map) |sm| {
            if (output_path) |path| {
                var map_path_buf: std.ArrayListUnmanaged(u8) = .empty;
                map_path_buf.appendSlice(allocator, path) catch {};
                map_path_buf.appendSlice(allocator, ".map") catch {};
                const map_path = map_path_buf.items;

                var json_buf: std.ArrayListUnmanaged(u8) = .empty;
                sm.toJson(&json_buf, allocator);

                const map_file = try Dir.cwd().createFile(io, map_path, .{});
                defer map_file.close(io);
                try map_file.writeStreamingAll(io, json_buf.items);

                try File.stderr().writeStreamingAll(io, "Source map: ");
                try File.stderr().writeStreamingAll(io, map_path);
                try File.stderr().writeStreamingAll(io, "\n");
            }
        }
    }

    if (result.errors.len > 0) {
        for (result.errors) |err| {
            try File.stderr().writeStreamingAll(io, "error: ");
            try File.stderr().writeStreamingAll(io, err.message);
            try File.stderr().writeStreamingAll(io, "\n");
        }
    }
}

fn runValidate(allocator: std.mem.Allocator, io: std.Io, source: [:0]const u8) !void {
    const File = std.Io.File;

    // Tokenize + parse
    var tokens = try miniray.Lexer.tokenize(allocator, source);
    _ = &tokens;
    var parser = miniray.Parser.init(allocator, source, tokens);
    const module = parser.parse() catch {
        try File.stderr().writeStreamingAll(io, "error: parse failed\n");
        for (parser.errors.items) |err| {
            try File.stderr().writeStreamingAll(io, "  ");
            try File.stderr().writeStreamingAll(io, err.message);
            try File.stderr().writeStreamingAll(io, "\n");
        }
        return;
    };

    // Validate
    const result = miniray.Validator.validate(allocator, module, .{});

    if (result.valid) {
        try File.stdout().writeStreamingAll(io, "valid\n");
    } else {
        try File.stdout().writeStreamingAll(io, "invalid\n");
        for (result.diagnostics.diagnostics.items) |entry| {
            const sev_str = entry.severity.string();
            try File.stderr().writeStreamingAll(io, sev_str);
            try File.stderr().writeStreamingAll(io, ": ");
            try File.stderr().writeStreamingAll(io, entry.message);
            try File.stderr().writeStreamingAll(io, "\n");
        }
    }
}

fn runReflect(allocator: std.mem.Allocator, io: std.Io, source: [:0]const u8) !void {
    const File = std.Io.File;

    // Tokenize + parse
    var tokens = try miniray.Lexer.tokenize(allocator, source);
    _ = &tokens;
    var parser = miniray.Parser.init(allocator, source, tokens);
    const module = parser.parse() catch {
        try File.stderr().writeStreamingAll(io, "error: parse failed\n");
        for (parser.errors.items) |err| {
            try File.stderr().writeStreamingAll(io, "  ");
            try File.stderr().writeStreamingAll(io, err.message);
            try File.stderr().writeStreamingAll(io, "\n");
        }
        return;
    };

    // Reflect
    const result = miniray.Reflect.reflect(allocator, module);

    // Serialize to JSON
    var json_buf: std.ArrayListUnmanaged(u8) = .empty;
    result.toJson(&json_buf, allocator);

    try File.stdout().writeStreamingAll(io, json_buf.items);
    try File.stdout().writeStreamingAll(io, "\n");
}

const usage_text =
    \\Usage: miniray [command] [options] [file.wgsl]
    \\
    \\Commands:
    \\  (default)                        Minify WGSL source
    \\  validate                         Validate WGSL source
    \\  reflect                          Extract bindings, layouts, and entry points as JSON
    \\
    \\Options:
    \\  -o <path>                        Output file
    \\  --config <path>                  Config file (JSON)
    \\  --no-mangle                      Don't rename identifiers
    \\  --mangle-external-bindings       Rename uniform/storage variables
    \\  --no-tree-shaking                Keep all declarations
    \\  --preserve-uniform-struct-types   Keep struct names used in uniforms
    \\  --keep-names <names>             Comma-separated names to preserve
    \\  --source-map                     Generate source map file (.map)
    \\  --source-map-inline              Embed source map as inline data URI
    \\  --source-map-sources             Include original source in source map
    \\  -h, --help                       Show this help
    \\
    \\If no input file is given, reads from stdin.
    \\
;
