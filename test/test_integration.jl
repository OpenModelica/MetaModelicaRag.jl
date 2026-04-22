using LinearAlgebra: normalize

function embedding_server_available(url)
    try
        resp = MetaModelicaRag.Embedder.embed(
            MetaModelicaRag.Embedder.OllamaEmbedder(url, "nomic-embed-text"), "test")
        !isempty(resp)
    catch
        false
    end
end

function llama_server_available(url)
    try
        resp = MetaModelicaRag.Embedder.embed(
            MetaModelicaRag.Embedder.LlamaEmbedder(url), "test")
        !isempty(resp)
    catch
        false
    end
end

# ── parse + store pipeline ─────────────────────────────────────────────────

@testset "Integration — parse + store: synthetic embeddings, search and lookup" begin
    path   = joinpath(FIXTURE_DIR, "msl.mo")
    chunks = Parser.parse_file(path)
    @test !isempty(chunks)

    db = Store.open_store(tempname() * ".db")

    sample = chunks[1:min(50, length(chunks))]
    for chunk in sample
        vec = normalize(randn(Float32, 768))
        Store.insert_chunk(db, chunk, vec)
        Store.set_file_mtime(db, chunk.file_path, 1.0)
    end

    @test Store.chunk_count(db) == length(sample)

    # Exact lookup by name must find the chunk we just indexed
    first_name = sample[1].symbol_name
    hits = Store.lookup_symbol(db, first_name)
    @test !isempty(hits)
    @test hits[1].symbol_name == first_name

    # Search returns at most top_k results, sorted by similarity
    query   = normalize(randn(Float32, 768))
    results = Store.search_chunks(db, query, 5)
    @test length(results) <= 5
    @test issorted(results; by = r -> -r.similarity)
end

@testset "Integration — incremental indexing: unchanged file is skipped" begin
    path   = joinpath(FIXTURE_DIR, "HelloWorld.mo")
    chunks = Parser.parse_file(path)
    db     = Store.open_store(tempname() * ".db")
    mtime  = Float64(stat(path).mtime)

    for chunk in chunks
        Store.insert_chunk(db, chunk, normalize(randn(Float32, 64)))
    end
    Store.set_file_mtime(db, path, mtime)

    @test Store.chunk_count(db) == length(chunks)

    # Simulate the incremental check: file mtime unchanged → nothing to re-index
    indexed    = Store.get_indexed_mtimes(db)
    to_reindex = filter(p -> Float64(stat(p).mtime) != get(indexed, p, -1.0), [path])
    @test isempty(to_reindex)
end

@testset "Integration — incremental indexing: modified file is re-indexed" begin
    path   = joinpath(FIXTURE_DIR, "HelloWorld.mo")
    chunks = Parser.parse_file(path)
    db     = Store.open_store(tempname() * ".db")

    for chunk in chunks
        Store.insert_chunk(db, chunk, normalize(randn(Float32, 64)))
    end
    # Record a stale mtime (0.0 ≠ actual mtime)
    Store.set_file_mtime(db, path, 0.0)

    indexed    = Store.get_indexed_mtimes(db)
    to_reindex = filter(p -> Float64(stat(p).mtime) != get(indexed, p, -1.0), [path])
    @test length(to_reindex) == 1
    @test to_reindex[1] == path
end

@testset "Integration — delete + re-insert: no duplicate chunks" begin
    path   = joinpath(FIXTURE_DIR, "HelloWorld.mo")
    chunks = Parser.parse_file(path)
    db     = Store.open_store(tempname() * ".db")
    mtime  = Float64(stat(path).mtime)
    v      = normalize(randn(Float32, 16))

    for chunk in chunks
        Store.insert_chunk(db, chunk, v)
    end
    Store.set_file_mtime(db, path, mtime)
    n_first = Store.chunk_count(db)

    # Simulate re-index: delete then re-insert
    Store.delete_file_chunks(db, path)
    for chunk in chunks
        Store.insert_chunk(db, chunk, v)
    end
    Store.set_file_mtime(db, path, mtime)

    @test Store.chunk_count(db) == n_first
end

@testset "Integration — multiple files indexed, lookup is file-independent" begin
    db = Store.open_store(tempname() * ".db")

    for fname in ["HelloWorld.mo", "BreakingPendulum.mo", "Influenza.mo"]
        path   = joinpath(FIXTURE_DIR, fname)
        chunks = Parser.parse_file(path)
        for chunk in chunks
            Store.insert_chunk(db, chunk, normalize(randn(Float32, 32)))
        end
        Store.set_file_mtime(db, path, Float64(stat(path).mtime))
    end

    @test Store.chunk_count(db) >= 3   # at least one chunk from each file

    # HelloWorld is indexable by name regardless of other files in the DB
    hits = Store.lookup_symbol(db, "HelloWorld")
    @test !isempty(hits)
end

# ── live embedding servers ─────────────────────────────────────────────────

if embedding_server_available("http://localhost:11434")
    @testset "Integration — live Ollama: embed + search round-trip" begin
        path     = joinpath(FIXTURE_DIR, "HelloWorld.mo")
        chunks   = Parser.parse_file(path)
        embedder = MetaModelicaRag.Embedder.OllamaEmbedder("http://localhost:11434", "nomic-embed-text")
        db       = Store.open_store(tempname() * ".db")

        for chunk in chunks
            text = "$(chunk.symbol_type) $(chunk.symbol_name)\n$(first(chunk.content, 512))"
            vec  = MetaModelicaRag.Embedder.embed(embedder, text)
            @test !isempty(vec)
            Store.insert_chunk(db, chunk, vec)
        end

        qvec    = MetaModelicaRag.Embedder.embed(embedder, "simple ODE model")
        results = Store.search_chunks(db, qvec, 1)
        @test !isempty(results)
        @test results[1].chunk.symbol_name == "HelloWorld"
    end
else
    @info "Skipping live Ollama test (server not available at http://localhost:11434)"
end

if llama_server_available("http://localhost:8080")
    @testset "Integration — live llama-server: embed + search round-trip" begin
        path     = joinpath(FIXTURE_DIR, "HelloWorld.mo")
        chunks   = Parser.parse_file(path)
        embedder = MetaModelicaRag.Embedder.LlamaEmbedder("http://localhost:8080")
        db       = Store.open_store(tempname() * ".db")

        for chunk in chunks
            text = "$(chunk.symbol_type) $(chunk.symbol_name)\n$(first(chunk.content, 512))"
            vec  = MetaModelicaRag.Embedder.embed(embedder, text)
            @test !isempty(vec)
            Store.insert_chunk(db, chunk, vec)
        end

        qvec    = MetaModelicaRag.Embedder.embed(embedder, "simple ODE model")
        results = Store.search_chunks(db, qvec, 1)
        @test !isempty(results)
        @test results[1].chunk.symbol_name == "HelloWorld"
    end
else
    @info "Skipping live llama-server test (server not available at http://localhost:8080)"
end
