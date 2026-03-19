# miniray (Zig)

Zig port of the miniray WGSL minifier. Produces **byte-identical output** to the Go implementation on all test shaders.

## Build

Requires Zig master (0.16.x via [zigup](https://github.com/marler182/zigup)).

```bash
zig build          # Native CLI → zig-out/bin/miniray
zig build wasm     # WASM → zig-out/bin/miniray.wasm (88 KB)
zig build test     # Run all 152 tests
```

## Usage

```bash
# Minify
zig-out/bin/miniray shader.wgsl -o shader.min.wgsl
echo 'fn main() {}' | zig-out/bin/miniray

# With config
zig-out/bin/miniray --config configs/compute.toys.json shader.wgsl

# Validate
zig-out/bin/miniray validate shader.wgsl

# Options
zig-out/bin/miniray --no-mangle shader.wgsl
zig-out/bin/miniray --mangle-external-bindings shader.wgsl
zig-out/bin/miniray --no-tree-shaking shader.wgsl
zig-out/bin/miniray --preserve-uniform-struct-types shader.wgsl
```

## WASM

88 KB binary (49x smaller than Go's 4.3 MB). No `wasm_exec.js` required.

```javascript
const { instance } = await WebAssembly.instantiate(wasmBytes);
const { memory, miniray_alloc, miniray_dealloc, miniray_minify } = instance.exports;

// Write source to WASM memory
const srcPtr = miniray_alloc(source.length);
new Uint8Array(memory.buffer, srcPtr, source.length).set(encoder.encode(source));

// Minify (flags: whitespace=1, identifiers=2, syntax=4, tree_shaking=8)
const resultPtr = miniray_minify(srcPtr, source.length, 0xF);
miniray_dealloc(srcPtr, source.length);

// Read result: [u32 length][u8... code]
const len = new DataView(memory.buffer).getUint32(resultPtr, true);
const code = decoder.decode(new Uint8Array(memory.buffer, resultPtr + 4, len));
miniray_dealloc(resultPtr, len + 4);
```

## Zig Library API

```zig
const miniray = @import("miniray");

// Minify with defaults
const result = try miniray.minify(allocator, source);

// Minify with options
const result = try miniray.minifyWithOptions(allocator, source, .{
    .minify_whitespace = true,
    .minify_identifiers = true,
    .tree_shaking = true,
    .keep_names = &.{"myUniform"},
});

// Validate
const vresult = miniray.Validator.validate(allocator, module, .{});
if (!vresult.valid) { /* handle errors */ }
```

## Architecture

```
Source → Lexer → Parser → AST → Minifier → Printer → Output
                           ↓         ↓
                       Renamer      DCE

Source → Lexer → Parser → AST → Validator → Diagnostics
                                    ↓
                            Types + Builtins
```

## Module Map

| Module | Lines | Purpose |
|--------|-------|---------|
| `Lexer.zig` | 767 | Tokenizer with comptime ASCII tables |
| `Ast.zig` | 688 | AST node types, Symbol, Scope |
| `Parser.zig` | 1,673 | Two-pass parser (parse + visit/bind) |
| `Printer.zig` | 681 | Code generator with minification |
| `Renamer.zig` | 320 | Frequency-based identifier renaming |
| `Dce.zig` | 238 | Dead code elimination (BFS) |
| `Minifier.zig` | 284 | Pipeline orchestration |
| `Config.zig` | 86 | JSON config file loading |
| `Diagnostic.zig` | 642 | Error reporting with source locations |
| `Types.zig` | 1,327 | WGSL type system |
| `Builtins.zig` | 609 | 119+ builtin function signatures |
| `Validator.zig` | 1,969 | 5-phase semantic validation |
| `SourceMap.zig` | 884 | Source map v3 with VLQ encoding |
| `Reflect.zig` | 887 | Shader reflection + memory layouts |
| `wasm.zig` | 80 | WASM entry point |
| `lib.zig` | 65 | C-ABI static library |
| `root.zig` | 42 | Public API |
| `cli/main.zig` | 163 | CLI binary |

**11,405 lines** total across 18 source files.

## Tests

```
152 tests total:
  65 unit tests (Lexer, AST, Parser, Renamer, Builtins, Diagnostic, Types, Validator, SourceMap, Reflect)
  79 snapshot + DCE tests (byte-identical to Go snapshots)
   8 validation integration tests
```

All 18 real-world test shaders (testdata + compute.toys) produce **byte-identical** output to the Go implementation.

## Comparison with Go

| | Go | Zig |
|---|---|---|
| Source lines | ~8,500 (core) | 11,405 (full) |
| Native binary | 6.7 MB | 3.0 MB |
| WASM binary | 4.3 MB | 88 KB |
| Tests | 200+ | 152 |
| Output | reference | byte-identical |
