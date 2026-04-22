using LinearAlgebra: normalize

function fake_chunk(name; file = "test.mo", line = 1, typ = "function",
                    content = "function $name end $name;")
    (file_path   = file,
     start_line  = line,
     end_line    = line + 5,
     symbol_name = name,
     symbol_type = typ,
     content     = content)
end

# ── open / schema ──────────────────────────────────────────────────────────

@testset "Store — open_store creates empty database" begin
    db = Store.open_store(tempname() * ".db")
    @test Store.chunk_count(db) == 0
    @test isempty(Store.get_indexed_mtimes(db))
end

@testset "Store — open_store is idempotent (schema already exists)" begin
    path = tempname() * ".db"
    db1  = Store.open_store(path)
    Store.insert_chunk(db1, fake_chunk("Foo"), Float32[1.0, 0.0])
    # Re-opening must not lose data or crash on CREATE TABLE IF NOT EXISTS
    db2  = Store.open_store(path)
    @test Store.chunk_count(db2) == 1
end

# ── insert / count ──────────────────────────────────────────────────────────

@testset "Store — insert_chunk increments count" begin
    db  = Store.open_store(tempname() * ".db")
    @test Store.chunk_count(db) == 0
    Store.insert_chunk(db, fake_chunk("A"), Float32[1.0, 0.0])
    @test Store.chunk_count(db) == 1
    Store.insert_chunk(db, fake_chunk("B"), Float32[0.0, 1.0])
    @test Store.chunk_count(db) == 2
end

# ── cosine similarity ───────────────────────────────────────────────────────

@testset "Store — exact match scores 1.0" begin
    db  = Store.open_store(tempname() * ".db")
    vec = normalize(Float32[1.0, 2.0, 3.0])
    Store.insert_chunk(db, fake_chunk("X"), vec)

    results = Store.search_chunks(db, vec, 1)
    @test length(results) == 1
    @test results[1].similarity ≈ 1.0f0  atol = 1e-6
    @test results[1].chunk.symbol_name == "X"
end

@testset "Store — cosine similarity ordering" begin
    db = Store.open_store(tempname() * ".db")
    Store.insert_chunk(db, fake_chunk("A"), Float32[1.0, 0.0, 0.0])  # cos = 1.0
    Store.insert_chunk(db, fake_chunk("B"), Float32[0.0, 1.0, 0.0])  # cos = 0.0
    Store.insert_chunk(db, fake_chunk("C"), Float32[1.0, 1.0, 0.0])  # cos ≈ 0.707

    results = Store.search_chunks(db, Float32[1.0, 0.0, 0.0], 3)
    ranked  = [r.chunk.symbol_name for r in results]

    @test ranked[1] == "A"
    @test ranked[2] == "C"
    @test ranked[3] == "B"
end

@testset "Store — results are sorted descending by similarity" begin
    db = Store.open_store(tempname() * ".db")
    for i in 1:10
        vec = normalize(randn(Float32, 16))
        Store.insert_chunk(db, fake_chunk("C$i"), vec)
    end
    query   = normalize(randn(Float32, 16))
    results = Store.search_chunks(db, query, 10)
    @test issorted(results; by = r -> -r.similarity)
end

@testset "Store — top_k limits number of results" begin
    db = Store.open_store(tempname() * ".db")
    for i in 1:20
        Store.insert_chunk(db, fake_chunk("M$i"), normalize(randn(Float32, 8)))
    end
    for k in [1, 5, 20, 100]
        results = Store.search_chunks(db, normalize(randn(Float32, 8)), k)
        @test length(results) == min(k, 20)
    end
end

@testset "Store — zero query vector returns empty" begin
    db  = Store.open_store(tempname() * ".db")
    Store.insert_chunk(db, fake_chunk("Z"), Float32[1.0, 0.0])
    results = Store.search_chunks(db, Float32[0.0, 0.0], 5)
    @test isempty(results)
end

@testset "Store — search on empty database returns empty" begin
    db = Store.open_store(tempname() * ".db")
    @test isempty(Store.search_chunks(db, Float32[1.0, 0.0], 5))
end

# ── lookup_symbol ───────────────────────────────────────────────────────────

@testset "Store — lookup_symbol exact match" begin
    db  = Store.open_store(tempname() * ".db")
    Store.insert_chunk(db, fake_chunk("instClass"), Float32[1.0])
    hits = Store.lookup_symbol(db, "instClass")
    @test length(hits) == 1
    @test hits[1].symbol_name == "instClass"
end

@testset "Store — lookup_symbol is case-insensitive" begin
    db  = Store.open_store(tempname() * ".db")
    Store.insert_chunk(db, fake_chunk("instClass"), Float32[1.0])
    @test length(Store.lookup_symbol(db, "instClass")) == 1
    @test length(Store.lookup_symbol(db, "INSTCLASS")) == 1
    @test length(Store.lookup_symbol(db, "instclass")) == 1
end

@testset "Store — lookup_symbol returns empty for unknown name" begin
    db  = Store.open_store(tempname() * ".db")
    Store.insert_chunk(db, fake_chunk("instClass"), Float32[1.0])
    @test isempty(Store.lookup_symbol(db, "typeCheck"))
end

@testset "Store — lookup_symbol returns all matching chunks" begin
    db  = Store.open_store(tempname() * ".db")
    v   = Float32[1.0]
    # Same qualified name in two different files
    Store.insert_chunk(db, fake_chunk("Foo"; file = "a.mo"), v)
    Store.insert_chunk(db, fake_chunk("Foo"; file = "b.mo"), v)
    hits = Store.lookup_symbol(db, "Foo")
    @test length(hits) == 2
end

# ── mtime tracking ──────────────────────────────────────────────────────────

@testset "Store — set_file_mtime and get_indexed_mtimes round-trip" begin
    db = Store.open_store(tempname() * ".db")
    Store.set_file_mtime(db, "a.mo", 1000.0)
    Store.set_file_mtime(db, "b.mo", 2000.0)
    m = Store.get_indexed_mtimes(db)
    @test m["a.mo"] == 1000.0
    @test m["b.mo"] == 2000.0
end

@testset "Store — set_file_mtime is an upsert" begin
    db = Store.open_store(tempname() * ".db")
    Store.set_file_mtime(db, "a.mo", 1.0)
    Store.set_file_mtime(db, "a.mo", 9.0)
    @test Store.get_indexed_mtimes(db)["a.mo"] == 9.0
    @test length(Store.get_indexed_mtimes(db)) == 1
end

# ── delete / clear ──────────────────────────────────────────────────────────

@testset "Store — delete_file_chunks removes chunks and mtime entry" begin
    db  = Store.open_store(tempname() * ".db")
    v   = Float32[1.0, 0.0]
    Store.insert_chunk(db, fake_chunk("Keep"; file = "keep.mo"), v)
    Store.insert_chunk(db, fake_chunk("Drop"; file = "drop.mo"), v)
    Store.set_file_mtime(db, "keep.mo", 1.0)
    Store.set_file_mtime(db, "drop.mo", 2.0)

    Store.delete_file_chunks(db, "drop.mo")

    @test Store.chunk_count(db) == 1
    m = Store.get_indexed_mtimes(db)
    @test !haskey(m, "drop.mo")
    @test  haskey(m, "keep.mo")
    @test all(r.chunk.symbol_name != "Drop" for r in Store.search_chunks(db, v, 5))
end

@testset "Store — delete_file_chunks is a no-op for unknown file" begin
    db = Store.open_store(tempname() * ".db")
    Store.insert_chunk(db, fake_chunk("X"), Float32[1.0])
    Store.delete_file_chunks(db, "nonexistent.mo")
    @test Store.chunk_count(db) == 1
end

@testset "Store — clear_store empties all tables" begin
    db  = Store.open_store(tempname() * ".db")
    v   = Float32[1.0]
    Store.insert_chunk(db, fake_chunk("M"), v)
    Store.set_file_mtime(db, "test.mo", 1.0)

    Store.clear_store(db)

    @test Store.chunk_count(db) == 0
    @test isempty(Store.get_indexed_mtimes(db))
    @test isempty(Store.search_chunks(db, v, 5))
end

# ── fuzzy_lookup ───────────────────────────────────────────────────────────

@testset "Store — fuzzy_lookup: substring match" begin
    db = Store.open_store(tempname() * ".db")
    Store.insert_chunk(db, fake_chunk("NFInst.instClass"),  Float32[1.0])
    Store.insert_chunk(db, fake_chunk("NFInst.instRecord"), Float32[1.0])
    Store.insert_chunk(db, fake_chunk("NFLookup.lookupClass"), Float32[1.0])

    hits = Store.fuzzy_lookup(db, "instClass", 10)
    @test length(hits) == 1
    @test hits[1].symbol_name == "NFInst.instClass"
end

@testset "Store — fuzzy_lookup: partial prefix match" begin
    db = Store.open_store(tempname() * ".db")
    Store.insert_chunk(db, fake_chunk("NFInst.instClass"),  Float32[1.0])
    Store.insert_chunk(db, fake_chunk("NFInst.instRecord"), Float32[1.0])
    Store.insert_chunk(db, fake_chunk("NFLookup.lookupClass"), Float32[1.0])

    hits = Store.fuzzy_lookup(db, "NFInst", 10)
    names = [h.symbol_name for h in hits]
    @test "NFInst.instClass"  in names
    @test "NFInst.instRecord" in names
    @test !("NFLookup.lookupClass" in names)
end

@testset "Store — fuzzy_lookup: case-insensitive" begin
    db = Store.open_store(tempname() * ".db")
    Store.insert_chunk(db, fake_chunk("NFInst.instClass"), Float32[1.0])

    hits = Store.fuzzy_lookup(db, "nfinst", 10)
    @test length(hits) == 1
end

@testset "Store — fuzzy_lookup: top_k limits results" begin
    db = Store.open_store(tempname() * ".db")
    for i in 1:10
        Store.insert_chunk(db, fake_chunk("Foo$i"), Float32[1.0])
    end
    @test length(Store.fuzzy_lookup(db, "Foo", 3))  == 3
    @test length(Store.fuzzy_lookup(db, "Foo", 10)) == 10
end

@testset "Store — fuzzy_lookup: no match returns empty" begin
    db = Store.open_store(tempname() * ".db")
    Store.insert_chunk(db, fake_chunk("instClass"), Float32[1.0])
    @test isempty(Store.fuzzy_lookup(db, "zzznomatch999", 10))
end

# ── ChunkRecord fields ──────────────────────────────────────────────────────

@testset "Store — ChunkRecord fields are preserved through insert+search" begin
    db   = Store.open_store(tempname() * ".db")
    orig = fake_chunk("NFInst.instClass"; file = "NFInst.mo", line = 42,
                      typ = "function", content = "function NFInst.instClass end;")
    vec  = normalize(Float32[1.0, 0.0])
    Store.insert_chunk(db, orig, vec)

    hits = Store.lookup_symbol(db, "NFInst.instClass")
    @test length(hits) == 1
    c = hits[1]
    @test c.file_path   == "NFInst.mo"
    @test c.start_line  == 42
    @test c.end_line    == 47
    @test c.symbol_name == "NFInst.instClass"
    @test c.symbol_type == "function"
    @test c.content     == "function NFInst.instClass end;"
end
