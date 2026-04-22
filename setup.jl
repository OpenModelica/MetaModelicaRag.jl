#!/usr/bin/env julia
# setup.jl — interactive first-run configuration for MetaModelicaRag.jl
import Dates
#
# Run this once after cloning:
#   julia setup.jl
#
# It detects available embedding backends, asks for the MetaModelica source
# path, and writes config.toml.

function ask(prompt::String, default::String = "")::String
    if isempty(default)
        print("$prompt: ")
    else
        print("$prompt [$default]: ")
    end
    answer = strip(readline())
    isempty(answer) ? default : answer
end

function yn(prompt::String, default::Bool = true)::Bool
    hint = default ? "Y/n" : "y/N"
    print("$prompt [$hint]: ")
    answer = lowercase(strip(readline()))
    isempty(answer) ? default : answer in ("y", "yes")
end

println("=" ^ 60)
println("MetaModelicaRag — setup")
println("=" ^ 60)
println()

# ---------------------------------------------------------------------------
# Detect embedding backends
# ---------------------------------------------------------------------------

github_token = get(ENV, "GITHUB_TOKEN", "")
ollama_ok    = false
llama_ok     = false

print("Checking Ollama ... ")
try
    import HTTP
    resp = HTTP.get("http://localhost:11434/api/tags"; readtimeout = 2, retry = false)
    ollama_ok = resp.status == 200
    println(ollama_ok ? "found" : "not running")
catch
    println("not running")
end

default_llama = expanduser("~/llama.cpp/build/bin/llama-server")
if isfile(default_llama)
    llama_ok = true
    print("Checking llama-server ... found at $default_llama")
    println()
end

println()
println("Available embedding backends:")
!isempty(github_token) && println("  [1] github_models  (GITHUB_TOKEN detected — free, no local server needed)")
ollama_ok              && println("  [2] ollama         (Ollama is running locally)")
llama_ok               && println("  [3] llama          (llama-server found at $default_llama)")
println()

# Pick a default
backend = if !isempty(github_token)
    "github_models"
elseif ollama_ok
    "ollama"
elseif llama_ok
    "llama"
else
    ""
end

if isempty(backend)
    println("No embedding backend detected.")
    println("Options:")
    println("  - Install Ollama (https://ollama.com) and run: ollama pull nomic-embed-text")
    println("  - Set GITHUB_TOKEN to use the GitHub Models free API")
    println("  - Build llama-server from llama.cpp")
    println()
    backend = ask("Enter backend manually (github_models / ollama / llama)", "ollama")
end

backend = ask("Embedding backend", backend)

# ---------------------------------------------------------------------------
# Backend-specific settings
# ---------------------------------------------------------------------------

embed_url   = "http://localhost:8080"
embed_model = "text-embedding-3-small"

if backend == "github_models"
    if isempty(github_token)
        println()
        println("GitHub Models requires a personal access token.")
        println("Create one at https://github.com/settings/tokens (no scopes needed).")
        println("It is safer to set GITHUB_TOKEN in your shell than to store it here.")
    end
    embed_model = ask("GitHub embedding model", "text-embedding-3-small")

elseif backend == "ollama"
    embed_url   = ask("Ollama URL", "http://localhost:11434")
    embed_model = ask("Ollama model", "nomic-embed-text")

elseif backend == "llama"
    embed_url = ask("llama-server URL", "http://localhost:8080")
end

# ---------------------------------------------------------------------------
# MetaModelica source path
# ---------------------------------------------------------------------------

println()
println("MetaModelica source directory")
println("  Typically: /path/to/OpenModelica/OMCompiler")

# Check common locations
candidates = [
    get(ENV, "OPENMODELICAHOME", ""),
    "/usr/share/openmodelica",
    "/opt/openmodelica",
    expanduser("~/Projects/OpenModelica/OMCompiler"),
]
detected_root = ""
for c in candidates
    if !isempty(c) && isdir(c)
        detected_root = c
        break
    end
end

codebase_root = ask("MetaModelica source root", detected_root)
while !isdir(codebase_root)
    println("Directory not found: $codebase_root")
    codebase_root = ask("MetaModelica source root")
end

# ---------------------------------------------------------------------------
# Store path
# ---------------------------------------------------------------------------

println()
default_store = joinpath(@__DIR__, "data", "index.db")
store_path    = ask("Index database path", default_store)

# ---------------------------------------------------------------------------
# llama-server paths (only if needed)
# ---------------------------------------------------------------------------

llama_server_path = expanduser("~/llama.cpp/build/bin/llama-server")
llama_model_path  = expanduser("~/llama.cpp/models/Qwen3-Embedding-8B-Q8_0.gguf")

if backend == "llama"
    println()
    llama_server_path = ask("llama-server binary", llama_server_path)
    llama_model_path  = ask("GGUF model path",     llama_model_path)
end

# ---------------------------------------------------------------------------
# Write config.toml
# ---------------------------------------------------------------------------

config_path = joinpath(@__DIR__, "config.toml")
if isfile(config_path)
    println()
    overwrite = yn("config.toml already exists. Overwrite?", false)
    overwrite || (println("Aborted. Existing config.toml unchanged."); exit(0))
end

open(config_path, "w") do io
    println(io, "# Generated by setup.jl on $(Dates.today())")
    println(io, "# Run `julia setup.jl` again to regenerate.\n")
    println(io, "[embeddings]")
    println(io, "backend    = \"$backend\"")
    if backend == "ollama"
        println(io, "url        = \"$embed_url\"")
        println(io, "model      = \"$embed_model\"")
    elseif backend == "github_models"
        println(io, "model      = \"$embed_model\"")
        println(io, "# token is read from the GITHUB_TOKEN environment variable.")
        println(io, "# Do not put your token directly in this file.")
    else
        println(io, "url        = \"$embed_url\"")
    end
    println(io, "batch_size = 32\n")

    println(io, "[server]")
    println(io, "llama_server = \"$llama_server_path\"")
    println(io, "model_path   = \"$llama_model_path\"\n")

    println(io, "[store]")
    println(io, "path = \"$store_path\"\n")

    println(io, "[codebase]")
    println(io, "root       = \"$codebase_root\"")
    println(io, "extensions = [\".mo\"]")
end

println()
println("config.toml written to $config_path")
println()
println("Next steps:")
if backend == "github_models"
    println("  1. export GITHUB_TOKEN=<your token>")
    println("  2. julia -e 'push!(LOAD_PATH, \".\"); using MetaModelicaRag; MetaModelicaRag.main([\"index\"])'")
elseif backend == "ollama"
    println("  1. Make sure Ollama is running and the model is pulled:")
    println("       ollama pull $embed_model")
    println("  2. julia -e 'push!(LOAD_PATH, \".\"); using MetaModelicaRag; MetaModelicaRag.main([\"index\"])'")
else
    println("  1. julia -e 'push!(LOAD_PATH, \".\"); using MetaModelicaRag; MetaModelicaRag.main([\"index\"])'")
end
println()
println("Once indexed, search with:")
println("  julia -e 'push!(LOAD_PATH, \".\"); using MetaModelicaRag; MetaModelicaRag.main([\"search\", \"match expression with list patterns\"])'")
println("  julia -e 'push!(LOAD_PATH, \".\"); using MetaModelicaRag; MetaModelicaRag.main([\"fuzzy\", \"instClass\"])'")
