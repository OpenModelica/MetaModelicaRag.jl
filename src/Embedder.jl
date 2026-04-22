module Embedder

using HTTP
using JSON3

export LlamaEmbedder, OllamaEmbedder, GithubModelsEmbedder, embed, embed_batch

# ── llama-server backend ───────────────────────────────────────────────────

struct LlamaEmbedder
    url::String  # e.g. "http://localhost:8080"
end

# Single embedding via llama-server POST /embeddings {"content": "..."}
function embed(e::LlamaEmbedder, text::String)::Vector{Float32}
    body = JSON3.write(Dict("content" => text))
    resp = HTTP.post(
        e.url * "/embeddings",
        ["Content-Type" => "application/json"],
        body;
        retry = false,
        readtimeout = 60,
    )
    data = JSON3.read(resp.body)
    extract_single(data)
end

# Batch embedding — llama-server accepts an array of {"content": "..."} objects.
# Falls back to sequential if the server does not support batch.
function embed_batch(e::LlamaEmbedder, texts::Vector{String})::Vector{Vector{Float32}}
    body = JSON3.write([Dict("content" => t) for t in texts])
    resp = try
        HTTP.post(
            e.url * "/embeddings",
            ["Content-Type" => "application/json"],
            body;
            retry = false,
            readtimeout = 120,
        )
    catch
        return [embed(e, t) for t in texts]
    end

    data = JSON3.read(resp.body)

    if data isa AbstractVector
        sorted = sort(collect(data), by = x -> get(x, :index, 0))
        return [unwrap_embedding(x.embedding) for x in sorted]
    end

    # Single-object response — batch not supported, fall back.
    return [embed(e, t) for t in texts]
end

# ── Ollama backend ─────────────────────────────────────────────────────────

struct OllamaEmbedder
    url::String    # e.g. "http://localhost:11434"
    model::String  # e.g. "nomic-embed-text" or "mxbai-embed-large"
end

# Single embedding via Ollama POST /api/embeddings {"model": "...", "prompt": "..."}
function embed(e::OllamaEmbedder, text::String)::Vector{Float32}
    body = JSON3.write(Dict("model" => e.model, "prompt" => text))
    resp = HTTP.post(
        e.url * "/api/embeddings",
        ["Content-Type" => "application/json"],
        body;
        retry = false,
        readtimeout = 60,
    )
    data = JSON3.read(resp.body)
    haskey(data, :embedding) || error("No embedding field in Ollama response")
    Float32.(data.embedding)
end

# Ollama has no native batch endpoint — embed sequentially.
function embed_batch(e::OllamaEmbedder, texts::Vector{String})::Vector{Vector{Float32}}
    [embed(e, t) for t in texts]
end

# ── GitHub Models backend ──────────────────────────────────────────────────
#
# Uses the GitHub Models free embedding API (OpenAI-compatible).
# Each GitHub user gets 150 requests/day at no cost.
# Token is read from the GITHUB_TOKEN environment variable if not supplied.

struct GithubModelsEmbedder
    token::String   # GitHub personal access token
    model::String   # e.g. "text-embedding-3-small" or "text-embedding-3-large"
end

function GithubModelsEmbedder(; model::String = "text-embedding-3-small",
                                token::String  = get(ENV, "GITHUB_TOKEN", ""))
    isempty(token) && error("GitHub token required: set GITHUB_TOKEN or pass token=")
    GithubModelsEmbedder(token, model)
end

const GITHUB_MODELS_URL = "https://models.inference.ai.azure.com/embeddings"

function embed(e::GithubModelsEmbedder, text::String)::Vector{Float32}
    first(embed_batch(e, [text]))
end

function embed_batch(e::GithubModelsEmbedder, texts::Vector{String})::Vector{Vector{Float32}}
    body = JSON3.write(Dict("input" => texts, "model" => e.model))
    resp = HTTP.post(
        GITHUB_MODELS_URL,
        ["Content-Type"  => "application/json",
         "Authorization" => "Bearer $(e.token)"],
        body;
        retry       = false,
        readtimeout = 120,
    )
    data = JSON3.read(resp.body)
    haskey(data, :data) || error("Unexpected GitHub Models response: $data")
    sorted = sort(collect(data.data), by = x -> x.index)
    [Float32.(x.embedding) for x in sorted]
end

# ── shared helpers ─────────────────────────────────────────────────────────

# Extract embedding from a top-level llama-server response (object or array).
function extract_single(data)::Vector{Float32}
    obj = data isa AbstractVector ? first(data) : data
    haskey(obj, :embedding) && return unwrap_embedding(obj.embedding)
    error("No embedding field in llama-server response")
end

# Qwen3-Embedding returns embedding as [[...]] (nested array).
# Older models return it as [...] (flat array).
function unwrap_embedding(emb)::Vector{Float32}
    if !isempty(emb) && first(emb) isa AbstractVector
        return Float32.(first(emb))
    end
    return Float32.(emb)
end

end # module Embedder
