# Architecture

## Module overview

```
MetaModelicaRag.jl
├── Parser      — file ingestion: .mo → Vector{Chunk}
├── Embedder    — text → Vector{Float32} via local model
├── Store       — SQLite: insert, search, mtime tracking
├── MCP         — JSON-RPC stdio server (MCP protocol)
└── CLI         — command-line entry point
```

Each module has a single responsibility. MCP and CLI are thin orchestration layers; they hold no state themselves.

---

## Parser

**Input:** path to a `.mo` file.

**Output:** `Vector{Chunk}`, one chunk per non-package class.

```
struct Chunk
    file_path   :: String
    start_line  :: Int
    end_line    :: Int
    symbol_name :: String   # fully qualified, e.g. "NFInst.instClass"
    symbol_type :: String   # "function", "uniontype", "record", ...
    content     :: String   # raw source lines
end
```

The walker uses `OMParser.jl` to produce an `Absyn` AST, then traverses it:

1. Reads the `within` clause to obtain the file's package prefix.
2. Pushes all top-level classes onto a work stack together with their prefix.
3. Pops one entry at a time:
   - If the class is a `package`: skip emitting a chunk (packages can be
     very large) but recurse into nested classes.
   - Otherwise: emit a chunk with the source lines `[lineNumberStart, lineNumberEnd]`.
4. Recurses into nested classes regardless of whether the parent was emitted.

MetaModelica adds one restriction type beyond standard Modelica:
`Absyn.R_UNIONTYPE()` mapped to the string `"uniontype"`.

---

## Embedder

Two backends, same interface (`embed` and `embed_batch`):

| Backend | Struct | Endpoint |
|---------|--------|----------|
| Ollama | `OllamaEmbedder(url, model)` | `POST /api/embeddings` |
| llama-server | `LlamaEmbedder(url)` | `POST /embeddings` |

Batch embedding is native on llama-server; Ollama falls back to sequential calls.

The text sent for each chunk is:
```
"$(chunk.symbol_type) $(chunk.symbol_name)\n$(first(chunk.content, 512))"
```

---

## Store

SQLite database with three tables:

```sql
chunks      (id, file_path, start_line, end_line, symbol_name, symbol_type, content)
embeddings  (chunk_id → chunks.id, vector BLOB)
file_meta   (file_path, mtime REAL)
```

Embeddings are stored as raw `Float32` bytes (`reinterpret(UInt8, vec)`).

Search loads all embedding blobs into memory and computes cosine similarity in Julia using `LinearAlgebra.dot` and `norm`. This is O(n) per query but is fast enough for the size of a compiler source tree (typically < 50 000 chunks).

Incremental indexing: before indexing a directory the walker checks `file_meta` to see which files have changed (`mtime` differs). Only those files are re-parsed and re-embedded.

---

## MCP

Implements the [Model Context Protocol](https://modelcontextprotocol.io) over stdio (newline-delimited JSON-RPC 2.0).

Message loop:

```
stdin  →  JSON-RPC request
           ├── initialize       → capabilities handshake
           ├── tools/list       → tool specs
           └── tools/call       → dispatch to handler function
stdout ←  JSON-RPC response
```

All state (DB handle and embedder) lives in closures passed into `serve_mcp` from `CLI.cmd_serve`. MCP itself is pure and stateless.

Tools exposed:

| Tool | Handler |
|------|---------|
| `search_codebase` | embed query → cosine search |
| `lookup_symbol` | exact SQL lookup (COLLATE NOCASE) |
| `fuzzy_lookup` | case-insensitive substring match on symbol names |
| `rebuild_index` | re-run indexer on codebase root |
| `index_library` | re-run indexer on arbitrary path |

---

## CLI

Parses `ARGS`, loads `config.toml`, and dispatches:

| Command | Description |
|---------|-------------|
| `index` | Build / update the index for `codebase.root` |
| `serve` | Start the MCP stdio server |
| `search` | One-shot semantic search, prints to stdout |
| `fuzzy` | One-shot substring lookup over symbol names |

`--config <path>` overrides the default `config.toml` location.
`--force` forces a full rebuild for `index`.
`--top-k <n>` controls result count for `search` and `fuzzy`.
