# MetaModelicaRag.jl

Semantic search over MetaModelica source code. Built for exploring the syntactic constructs of MetaModelica — the language that implements OpenModelica itself.

## What is MetaModelica?

MetaModelica extends Modelica with:

- `uniontype` — algebraic data types (tagged unions)
- `match` / `matchcontinue` — structural pattern matching
- `list<T>` — persistent linked lists
- `Option<T>` — optional values (`SOME(x)` / `NONE()`)
- `array<T>` — mutable arrays
- `fail()` — explicit pattern-match failure
- First-class functions and higher-order patterns

Most of the OpenModelica Compiler (`OMCompiler/Compiler/`) is written in MetaModelica. This package lets you search that source for examples of any construct.

## How it works

```
.mo source files
     │
     ▼
  Parser.jl       OMParser.jl parses each file into an Absyn AST.
                  Extracts every non-package class as a Chunk:
                  qualified name, symbol type, source lines.
                  Recognises MetaModelica-specific types (uniontype).
     │
     ▼
  Embedder.jl     Sends chunk text to a local embedding model
                  (Ollama or llama-server). Only changed files are
                  re-indexed.
     │
     ▼
  Store.jl        Stores embeddings as binary blobs in SQLite.
                  Cosine similarity search is computed in Julia.
     │
     ▼
  MCP.jl          Stdio MCP server — five tools available to any
                  MCP client (Claude Code, etc.).
```

## Requirements

- Julia 1.12+
- [OMParser.jl](https://github.com/OpenModelica/OMParser.jl) (fetched automatically)
- One embedding backend:
  - A GitHub personal access token for the [GitHub Models](https://github.com/marketplace/models) free embedding API
  - [Ollama](https://ollama.ai) with `nomic-embed-text` or similar
  - [llama.cpp](https://github.com/ggerganov/llama.cpp) `llama-server` with a GGUF model

## Installation

```julia
import Pkg
Pkg.develop(path = "/path/to/MetaModelicaRag.jl")
Pkg.build("MetaModelicaRag")
```

If you already have a working local `OMParser.jl` checkout and want this
project to use it locally, run:

```bash
export OMPARSER_PATH=~/Projects/Julia/OM.jl/OMParser.jl
julia --project -e 'import Pkg; Pkg.add(path=expanduser(ENV["OMPARSER_PATH"]))'
```

This writes a local manifest override only. Do not commit machine-specific path changes.

`Pkg.build("MetaModelicaRag")` also runs `Pkg.build("OMParser")`, which is the step
that downloads/configures OMParser's native parser library for this environment.

Then copy and edit the config:

```
cp config.toml.example config.toml
$EDITOR config.toml
```

## Configuration

`config.toml` is machine-specific (not tracked by git). The default backend is
`github_models`, which requires no local server — only a GitHub personal access
token exported as `GITHUB_TOKEN=github_pat_...` (150 requests/day free per
GitHub user, no special scopes required).

```toml
[embeddings]
backend    = "github_models"           # "github_models", "ollama", or "llama"
model      = "text-embedding-3-small"  # ollama: "nomic-embed-text"; llama: any GGUF
batch_size = 32
# url = "http://localhost:11434"       # only needed for ollama / llama backends

[store]
path = "/absolute/path/to/data/index.db"

[codebase]
# Point this at the MetaModelica source you want to index.
# The OpenModelica compiler source is a good choice.
root       = "/path/to/OpenModelica/OMCompiler/Compiler"
extensions = [".mo"]
```

To use a local server instead, switch `backend` to `"ollama"` or `"llama"` and
uncomment the matching `url` line.

## Usage

### Index

```julia
using MetaModelicaRag

# Build the index (incremental — only changed files)
MetaModelicaRag.main(["index"])

# Full rebuild
MetaModelicaRag.main(["index", "--force"])
```

### Search from the REPL

```julia
MetaModelicaRag.main(["search", "match expression with list patterns"])
MetaModelicaRag.main(["search", "uniontype with multiple record constructors", "--top-k", "10"])
```

### Start the MCP server

```julia
MetaModelicaRag.main(["serve"])
```

A custom config path can be passed with `--config path/to/config.toml`.

## MCP integration (Claude Code)

Add to `.mcp.json` in your project or user Claude Code settings:

```json
{
  "mcpServers": {
    "metamodelica-rag": {
      "command": "julia",
      "args": [
        "--project=/path/to/MetaModelicaRag.jl",
        "-e",
        "using MetaModelicaRag; MetaModelicaRag.main([\"serve\"])"
      ]
    }
  }
}
```

### Available MCP tools

| Tool | Input | Description |
|------|-------|-------------|
| `search_codebase` | `query`, `top_k` | Semantic search over indexed MetaModelica source. Returns matching functions, records, uniontypes, etc. |
| `lookup_symbol` | `name` | Exact lookup by qualified name, e.g. `NFInst.instClass`. Case-insensitive. |
| `fuzzy_lookup` | `pattern`, `top_k` | Case-insensitive substring match over symbol names when you only know part of a qualified name. |
| `rebuild_index` | `force` | Incremental or full index rebuild. |
| `index_library` | `path`, `force` | Index a MetaModelica source tree at an arbitrary path. |

## Project structure

```
MetaModelicaRag.jl/
├── Project.toml
├── config.toml.example   # copy to config.toml and fill in paths
├── docs/
│   ├── architecture.md   # pipeline and module design
│   └── metamodelica_syntax.md   # MetaModelica constructs reference
├── src/
│   ├── MetaModelicaRag.jl   # package entry point
│   ├── Parser.jl            # AST walker — extracts Chunks from .mo files
│   ├── Embedder.jl          # Ollama and llama-server embedding backends
│   ├── Store.jl             # SQLite storage and cosine similarity search
│   ├── MCP.jl               # MCP stdio server
│   └── CLI.jl               # index / serve / search / fuzzy commands
└── test/
    ├── runtests.jl
    ├── test_parser.jl       # chunk extraction from .mo files
    ├── test_store.jl        # SQLite insert, search, mtime tracking
    ├── test_mcp.jl          # MCP JSON-RPC dispatch
    └── test_integration.jl  # parse + store pipeline, live server tests
```

## Relation to ModelicaRag.jl

MetaModelicaRag.jl shares the same pipeline architecture as
[ModelicaRag.jl](../ModelicaRag.jl). The differences are:

- `Parser.jl` also handles `uniontype` (MetaModelica-specific restriction).
- MCP adds `fuzzy_lookup` alongside semantic search and exact symbol lookup.
- The intended codebase to index is MetaModelica source (e.g. `OMCompiler`)
  rather than Modelica standard libraries.
