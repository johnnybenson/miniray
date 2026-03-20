const std = @import("std");
const miniray = @import("miniray");

const CliArgs = struct {
    input_path: ?[]const u8 = null,
    output_path: ?[]const u8 = null,
    options: miniray.Minifier.Options = miniray.Minifier.defaultOptions(),
    source_map: bool = false,
    source_map_inline: bool = false,
    subcommand: enum { minify, validate, reflect } = .minify,
    show_help: bool = false,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;

    var args = parseArgs(allocator, init.minimal.args, io) orelse return;

    // Read input
    const source = try readSource(allocator, io, args.input_path);

    switch (args.subcommand) {
        .validate => try runValidate(allocator, io, source),
        .reflect => try runReflect(allocator, io, source),
        .minify => try runMinify(allocator, io, source, args.options, args.output_path, args.source_map, args.source_map_inline),
    }
}

fn parseArgs(allocator: std.mem.Allocator, raw_args: anytype, io: std.Io) ?CliArgs {
    const File = std.Io.File;
    const Dir = std.Io.Dir;
    var args = CliArgs{};
    var config_path: ?[]const u8 = null;
    var cli_no_mangle = false;
    var cli_no_tree_shaking = false;
    var source_map_sources = false;
    var keep_names_raw: ?[]const u8 = null;

    var args_iter = std.process.Args.Iterator.init(raw_args);
    _ = args_iter.skip(); // skip program name
    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "validate")) {
            args.subcommand = .validate;
        } else if (std.mem.eql(u8, arg, "reflect")) {
            args.subcommand = .reflect;
        } else if (std.mem.eql(u8, arg, "-o")) {
            args.output_path = args_iter.next();
        } else if (std.mem.eql(u8, arg, "--config")) {
            config_path = args_iter.next();
        } else if (std.mem.eql(u8, arg, "--no-mangle")) {
            cli_no_mangle = true;
        } else if (std.mem.eql(u8, arg, "--mangle-external-bindings")) {
            args.options.mangle_external_bindings = true;
        } else if (std.mem.eql(u8, arg, "--no-tree-shaking")) {
            cli_no_tree_shaking = true;
        } else if (std.mem.eql(u8, arg, "--preserve-uniform-struct-types")) {
            args.options.preserve_uniform_struct_types = true;
        } else if (std.mem.eql(u8, arg, "--source-map")) {
            args.source_map = true;
        } else if (std.mem.eql(u8, arg, "--source-map-inline")) {
            args.source_map_inline = true;
        } else if (std.mem.eql(u8, arg, "--source-map-sources")) {
            source_map_sources = true;
        } else if (std.mem.eql(u8, arg, "--keep-names")) {
            keep_names_raw = args_iter.next();
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            File.stdout().writeStreamingAll(io, usage_text) catch {};
            return null;
        } else if (arg.len > 0 and arg[0] != '-') {
            args.input_path = arg;
        }
    }

    // Load config file if specified
    if (config_path) |path| {
        const content = Dir.cwd().readFileAlloc(io, path, allocator, .unlimited) catch {
            File.stderr().writeStreamingAll(io, "error: could not read config file\n") catch {};
            return null;
        };
        const config = miniray.Config.parseJson(allocator, content) catch {
            File.stderr().writeStreamingAll(io, "error: invalid config JSON\n") catch {};
            return null;
        };
        args.options = config.toOptions();
    }

    // CLI overrides
    if (cli_no_mangle) args.options.minify_identifiers = false;
    if (cli_no_tree_shaking) args.options.tree_shaking = false;

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
        args.options.keep_names = names.items;
    }

    // Configure source map options
    const generate_source_map = args.source_map or args.source_map_inline;
    if (generate_source_map) {
        args.options.generate_source_map = true;
        args.options.source_map_options.include_source = source_map_sources;
        if (args.input_path) |path| {
            args.options.source_map_options.source_name = std.fs.path.basename(path);
        }
        if (args.output_path) |path| {
            args.options.source_map_options.file = std.fs.path.basename(path);
        }
    }

    return args;
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
    const tokens = try miniray.Lexer.tokenize(allocator, source);
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
    const tokens = try miniray.Lexer.tokenize(allocator, source);
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
