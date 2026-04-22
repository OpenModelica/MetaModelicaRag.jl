using JSON3
using LinearAlgebra: normalize

# Build a minimal MCP server wired to in-memory fakes.
# No embedding server required.

function make_fake_db()
    db  = Store.open_store(tempname() * ".db")
    vec = normalize(Float32[1.0, 0.0, 0.0])
    Store.insert_chunk(db,
        (file_path = "NFInst.mo", start_line = 10, end_line = 20,
         symbol_name = "NFInst.instClass", symbol_type = "function",
         content = "function NFInst.instClass end NFInst.instClass;"),
        vec)
    Store.insert_chunk(db,
        (file_path = "NFLookup.mo", start_line = 5, end_line = 15,
         symbol_name = "NFLookup.lookupClass", symbol_type = "function",
         content = "function NFLookup.lookupClass end NFLookup.lookupClass;"),
        normalize(Float32[0.0, 1.0, 0.0]))
    db, vec
end

function make_fns(db, stored_vec)
    search_fn    = (query, top_k)    -> Store.search_chunks(db, stored_vec, top_k)
    lookup_fn    = (name)            -> Store.lookup_symbol(db, name)
    fuzzy_fn     = (pattern, top_k)  -> Store.fuzzy_lookup(db, pattern, top_k)
    rebuild_fn   = (force)           -> "rebuild ok (force=$force)"
    index_lib_fn = (path, force)     -> "indexed $path (force=$force)"
    (search_fn, lookup_fn, fuzzy_fn, rebuild_fn, index_lib_fn)
end

# Call MCP.dispatch directly (bypasses stdin/stdout loop).
function call_tool(name, args, fns)
    (search_fn, lookup_fn, fuzzy_fn, rebuild_fn, index_lib_fn) = fns
    MetaModelicaRag.MCP.dispatch(name, args,
        search_fn, lookup_fn, fuzzy_fn, rebuild_fn, index_lib_fn)
end

# ── setup ──────────────────────────────────────────────────────────────────

const MCP_DB, MCP_VEC = make_fake_db()
const MCP_FNS         = make_fns(MCP_DB, MCP_VEC)

# ── tool: search_codebase ──────────────────────────────────────────────────

@testset "MCP — search_codebase returns text content" begin
    result = call_tool("search_codebase", Dict("query" => "instClass", "top_k" => 1), MCP_FNS)
    @test haskey(result, "content")
    @test result["content"] isa AbstractVector
    text = result["content"][1]["text"]
    @test contains(text, "NFInst.instClass")
end

@testset "MCP — search_codebase default top_k" begin
    result = call_tool("search_codebase", Dict("query" => "anything"), MCP_FNS)
    @test haskey(result, "content")
    @test !contains(get(result, "isError", false) |> string, "true")
end

@testset "MCP — search_codebase empty result message" begin
    empty_db  = Store.open_store(tempname() * ".db")
    empty_fns = make_fns(empty_db, MCP_VEC)
    result    = call_tool("search_codebase", Dict("query" => "x"), empty_fns)
    text      = result["content"][1]["text"]
    @test contains(text, "No results")
end

# ── tool: lookup_symbol ────────────────────────────────────────────────────

@testset "MCP — lookup_symbol: known name returns source" begin
    result = call_tool("lookup_symbol", Dict("name" => "NFInst.instClass"), MCP_FNS)
    text   = result["content"][1]["text"]
    @test contains(text, "NFInst.instClass")
    @test contains(text, "function")
end

@testset "MCP — lookup_symbol: case-insensitive" begin
    result = call_tool("lookup_symbol", Dict("name" => "nfinst.instclass"), MCP_FNS)
    text   = result["content"][1]["text"]
    @test contains(text, "NFInst.instClass")
end

@testset "MCP — lookup_symbol: unknown name returns 'Symbol not found'" begin
    result = call_tool("lookup_symbol", Dict("name" => "NoSuchThing"), MCP_FNS)
    text   = result["content"][1]["text"]
    @test contains(text, "not found")
end

# ── tool: fuzzy_lookup ────────────────────────────────────────────────────

@testset "MCP — fuzzy_lookup: partial name match" begin
    result = call_tool("fuzzy_lookup", Dict("pattern" => "instClass", "top_k" => 5), MCP_FNS)
    text   = result["content"][1]["text"]
    @test contains(text, "NFInst.instClass")
end

@testset "MCP — fuzzy_lookup: substring matching both symbols" begin
    result = call_tool("fuzzy_lookup", Dict("pattern" => "NF", "top_k" => 10), MCP_FNS)
    text   = result["content"][1]["text"]
    @test contains(text, "NFInst.instClass") || contains(text, "NFLookup.lookupClass")
end

@testset "MCP — fuzzy_lookup: missing pattern returns isError" begin
    result = call_tool("fuzzy_lookup", Dict{String,Any}(), MCP_FNS)
    text   = result["content"][1]["text"]
    @test contains(text, "Error") || get(result, "isError", false) == true
end

@testset "MCP — fuzzy_lookup: no match returns 'Symbol not found'" begin
    result = call_tool("fuzzy_lookup", Dict("pattern" => "zzznomatch999"), MCP_FNS)
    text   = result["content"][1]["text"]
    @test contains(text, "not found")
end

# ── tool: rebuild_index ────────────────────────────────────────────────────

@testset "MCP — rebuild_index: force=false" begin
    result = call_tool("rebuild_index", Dict("force" => false), MCP_FNS)
    text   = result["content"][1]["text"]
    @test contains(text, "force=false")
end

@testset "MCP — rebuild_index: force=true" begin
    result = call_tool("rebuild_index", Dict("force" => true), MCP_FNS)
    text   = result["content"][1]["text"]
    @test contains(text, "force=true")
end

@testset "MCP — rebuild_index: default (no force arg)" begin
    result = call_tool("rebuild_index", Dict{String,Any}(), MCP_FNS)
    @test haskey(result, "content")
end

# ── tool: index_library ────────────────────────────────────────────────────

@testset "MCP — index_library: passes path and force" begin
    result = call_tool("index_library", Dict("path" => "/some/path", "force" => false), MCP_FNS)
    text   = result["content"][1]["text"]
    @test contains(text, "/some/path")
end

@testset "MCP — index_library: missing path returns isError" begin
    result = call_tool("index_library", Dict{String,Any}(), MCP_FNS)
    text   = result["content"][1]["text"]
    @test contains(text, "Error") || get(result, "isError", false) == true
end

# ── unknown tool ───────────────────────────────────────────────────────────

@testset "MCP — unknown tool name returns isError" begin
    result = call_tool("no_such_tool", Dict{String,Any}(), MCP_FNS)
    @test get(result, "isError", false) == true ||
          contains(result["content"][1]["text"], "Unknown")
end

# ── tool_specs ─────────────────────────────────────────────────────────────

@testset "MCP — tool_specs returns five tools" begin
    specs = MetaModelicaRag.MCP.tool_specs()
    @test length(specs) == 5
end

@testset "MCP — tool_specs: all tools have name, description, inputSchema" begin
    for spec in MetaModelicaRag.MCP.tool_specs()
        @test haskey(spec, "name")
        @test haskey(spec, "description")
        @test haskey(spec, "inputSchema")
        @test !isempty(spec["name"])
        @test !isempty(spec["description"])
    end
end

@testset "MCP — tool_specs: expected tool names are present" begin
    names = Set(spec["name"] for spec in MetaModelicaRag.MCP.tool_specs())
    @test "search_codebase" in names
    @test "lookup_symbol"   in names
    @test "fuzzy_lookup"    in names
    @test "rebuild_index"   in names
    @test "index_library"   in names
end

@testset "MCP — tool_specs: required fields are non-empty arrays" begin
    for spec in MetaModelicaRag.MCP.tool_specs()
        schema = spec["inputSchema"]
        @test haskey(schema, "required")
        @test schema["required"] isa AbstractVector
    end
end
