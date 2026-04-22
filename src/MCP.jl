module MCP

using JSON3

export serve_mcp

const PROTOCOL_VERSION = "2024-11-05"
const SERVER_NAME      = "metamodelica-rag"
const SERVER_VERSION   = "0.1.0"

function serve_mcp(search_fn, lookup_fn, fuzzy_fn, rebuild_fn, index_lib_fn)
    while !eof(stdin)
        line = readline(stdin)
        isempty(line) && continue
        req = try
            JSON3.read(line)
        catch e
            @warn "Bad JSON from client: $e"
            continue
        end
        handle(req, search_fn, lookup_fn, fuzzy_fn, rebuild_fn, index_lib_fn)
    end
end

function respond(id, result)
    println(JSON3.write(Dict("jsonrpc" => "2.0", "id" => id, "result" => result)))
    flush(stdout)
end

function respond_error(id, code::Int, msg::String)
    println(JSON3.write(Dict(
        "jsonrpc" => "2.0", "id" => id,
        "error"   => Dict("code" => code, "message" => msg),
    )))
    flush(stdout)
end

function handle(req, search_fn, lookup_fn, fuzzy_fn, rebuild_fn, index_lib_fn)
    method = string(get(req, :method, ""))
    id     = get(req, :id, nothing)

    isnothing(id) && return
    method == "notifications/initialized" && return

    if method == "initialize"
        respond(id, Dict(
            "protocolVersion" => PROTOCOL_VERSION,
            "capabilities"    => Dict("tools" => Dict()),
            "serverInfo"      => Dict("name" => SERVER_NAME, "version" => SERVER_VERSION),
        ))

    elseif method == "tools/list"
        respond(id, Dict("tools" => tool_specs()))

    elseif method == "tools/call"
        params    = get(req, :params, Dict())
        tool_name = string(get(params, :name, ""))
        args      = get(params, :arguments, Dict())
        result    = dispatch(tool_name, args, search_fn, lookup_fn, fuzzy_fn, rebuild_fn, index_lib_fn)
        respond(id, result)

    else
        respond_error(id, -32601, "Method not found: $method")
    end
end

function dispatch(name, args, search_fn, lookup_fn, fuzzy_fn, rebuild_fn, index_lib_fn)
    try
        if name == "search_codebase"
            query = string(get(args, :query, get(args, "query", "")))
            top_k = Int(get(args, :top_k, get(args, "top_k", 5)))
            results = search_fn(query, top_k)
            return Dict("content" => [Dict("type" => "text", "text" => fmt_search(results))])

        elseif name == "lookup_symbol"
            sym = string(get(args, :name, get(args, "name", "")))
            results = lookup_fn(sym)
            return Dict("content" => [Dict("type" => "text", "text" => fmt_chunks(results))])

        elseif name == "fuzzy_lookup"
            pattern = string(get(args, :pattern, get(args, "pattern", "")))
            top_k   = Int(get(args, :top_k, get(args, "top_k", 10)))
            isempty(pattern) && return Dict("content" => [Dict("type" => "text", "text" => "Error: pattern is required")], "isError" => true)
            results = fuzzy_fn(pattern, top_k)
            return Dict("content" => [Dict("type" => "text", "text" => fmt_chunks(results))])

        elseif name == "rebuild_index"
            force = Bool(get(args, :force, get(args, "force", false)))
            msg   = rebuild_fn(force)
            return Dict("content" => [Dict("type" => "text", "text" => msg)])

        elseif name == "index_library"
            path  = string(get(args, :path, get(args, "path", "")))
            force = Bool(get(args, :force, get(args, "force", false)))
            isempty(path) && return Dict("content" => [Dict("type" => "text", "text" => "Error: path is required")], "isError" => true)
            msg   = index_lib_fn(path, force)
            return Dict("content" => [Dict("type" => "text", "text" => msg)])

        else
            return Dict("content" => [Dict("type" => "text", "text" => "Unknown tool: $name")],
                        "isError" => true)
        end
    catch e
        return Dict("content" => [Dict("type" => "text", "text" => "Error: $e")],
                    "isError" => true)
    end
end

function tool_specs()
    [
        Dict(
            "name"        => "search_codebase",
            "description" => "Semantic search over indexed MetaModelica source files. Returns the most relevant functions, records, uniontypes, and other constructs for the given query.",
            "inputSchema" => Dict(
                "type"       => "object",
                "properties" => Dict(
                    "query" => Dict("type" => "string",  "description" => "Natural-language query about a MetaModelica syntactic construct or pattern, e.g. \"match expression with list patterns\" or \"uniontype with record constructors\""),
                    "top_k" => Dict("type" => "integer", "description" => "Number of results to return (default 5)"),
                ),
                "required"   => ["query"],
            ),
        ),
        Dict(
            "name"        => "lookup_symbol",
            "description" => "Exact lookup of a MetaModelica declaration by qualified name (e.g. NFInst.instClass). Case-insensitive. Returns the full source of all matching symbols.",
            "inputSchema" => Dict(
                "type"       => "object",
                "properties" => Dict(
                    "name" => Dict("type" => "string", "description" => "Qualified MetaModelica symbol name to look up"),
                ),
                "required"   => ["name"],
            ),
        ),
        Dict(
            "name"        => "fuzzy_lookup",
            "description" => "Find MetaModelica symbol declarations whose name contains the given pattern (case-insensitive substring match). Useful when you remember part of a name but not the full qualified path.",
            "inputSchema" => Dict(
                "type"       => "object",
                "properties" => Dict(
                    "pattern" => Dict("type" => "string",  "description" => "Substring to match against symbol names, e.g. \"instClass\" or \"Lookup\""),
                    "top_k"   => Dict("type" => "integer", "description" => "Maximum number of results (default 10)"),
                ),
                "required"   => ["pattern"],
            ),
        ),
        Dict(
            "name"        => "rebuild_index",
            "description" => "Update the MetaModelica source search index. By default only re-indexes changed files (incremental). Pass force=true to rebuild everything from scratch.",
            "inputSchema" => Dict(
                "type"       => "object",
                "properties" => Dict(
                    "force" => Dict("type" => "boolean",
                                   "description" => "If true, clear and rebuild the entire index. Default false."),
                ),
                "required"   => String[],
            ),
        ),
        Dict(
            "name"        => "index_library",
            "description" => "Index MetaModelica source files at the given filesystem path. Incremental by default. Use force=true to rebuild from scratch.",
            "inputSchema" => Dict(
                "type"       => "object",
                "properties" => Dict(
                    "path"  => Dict("type" => "string",  "description" => "Absolute path to the MetaModelica source directory to index"),
                    "force" => Dict("type" => "boolean", "description" => "If true, remove existing chunks for this path and re-embed everything. Default false."),
                ),
                "required"   => ["path"],
            ),
        ),
    ]
end

function fmt_search(results)::String
    isempty(results) && return "No results found."
    io = IOBuffer()
    for (i, r) in enumerate(results)
        c = r.chunk
        println(io, "## Result $i  (similarity $(round(r.similarity; digits=3)))")
        println(io, "**`$(c.symbol_name)`** — $(c.symbol_type)")
        println(io, "`$(c.file_path):$(c.start_line)-$(c.end_line)`")
        println(io, "```modelica")
        println(io, c.content)
        println(io, "```")
        i < length(results) && println(io, "---")
    end
    String(take!(io))
end

function fmt_chunks(chunks)::String
    isempty(chunks) && return "Symbol not found."
    io = IOBuffer()
    for (i, c) in enumerate(chunks)
        println(io, "**`$(c.symbol_name)`** — $(c.symbol_type)")
        println(io, "`$(c.file_path):$(c.start_line)-$(c.end_line)`")
        println(io, "```modelica")
        println(io, c.content)
        println(io, "```")
        i < length(chunks) && println(io, "---")
    end
    String(take!(io))
end

end # module MCP
