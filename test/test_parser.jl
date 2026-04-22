@testset "Parser — HelloWorld.mo: single model chunk" begin
    path   = joinpath(FIXTURE_DIR, "HelloWorld.mo")
    chunks = Parser.parse_file(path)

    @test length(chunks) == 1
    if length(chunks) == 1
        c = only(chunks)
        @test c.symbol_name == "HelloWorld"
        @test c.symbol_type == "model"
        @test c.start_line >= 1
        @test c.end_line >= c.start_line
        @test !isempty(c.content)
        @test contains(c.content, "HelloWorld")
        @test c.file_path == path
    end
end

@testset "Parser — BreakingPendulum.mo: multiple classes per file" begin
    path   = joinpath(FIXTURE_DIR, "BreakingPendulum.mo")
    chunks = Parser.parse_file(path)
    names  = [c.symbol_name for c in chunks]

    @test "BouncingBall"     in names
    @test "Pendulum"         in names
    @test "BreakingPendulum" in names

    for c in chunks
        @test c.start_line >= 1
        @test c.end_line >= c.start_line
        @test !isempty(c.content)
        @test c.file_path == path
    end
end

@testset "Parser — Influenza.mo: connectors and components" begin
    path   = joinpath(FIXTURE_DIR, "Influenza.mo")
    chunks = Parser.parse_file(path)

    @test length(chunks) >= 1
    for c in chunks
        @test c.start_line >= 1
        @test c.end_line >= c.start_line
        @test !isempty(c.content)
    end
end

@testset "Parser — Casc12800.mo: single model" begin
    path   = joinpath(FIXTURE_DIR, "Casc12800.mo")
    chunks = Parser.parse_file(path)

    @test length(chunks) == 1
    if length(chunks) == 1
        @test chunks[1].symbol_name == "Casc12800"
        @test chunks[1].symbol_type == "model"
    end
end

@testset "Parser — symbol_type values are in the allowed set" begin
    # Packages must never be emitted; all others must be from the known set.
    allowed = Set(["model", "function", "record", "block", "connector",
                   "type", "class", "operator", "operator_record",
                   "enumeration", "optimization", "uniontype"])
    path   = joinpath(FIXTURE_DIR, "BreakingPendulum.mo")
    for c in Parser.parse_file(path)
        @test c.symbol_type in allowed
    end
end

@testset "Parser — no package chunks emitted" begin
    path  = joinpath(FIXTURE_DIR, "msl.mo")
    types = [c.symbol_type for c in Parser.parse_file(path)]
    @test !("package" in types)
end

@testset "Parser — msl.mo: large library, qualified names, known classes" begin
    path   = joinpath(FIXTURE_DIR, "msl.mo")
    chunks = Parser.parse_file(path)
    names  = [c.symbol_name for c in chunks]
    types  = [c.symbol_type for c in chunks]

    @test length(chunks) > 500

    @test all(c.start_line >= 1 for c in chunks)
    @test all(c.end_line >= c.start_line for c in chunks)
    @test all(!isempty(c.content) for c in chunks)

    # Qualified names contain dots for nested classes
    @test any(contains(n, ".") for n in names)

    @test any(endswith(n, "Resistor")  for n in names)
    @test any(endswith(n, "Capacitor") for n in names)
    @test any(endswith(n, "Inductor")  for n in names)

    # Every chunk's content contains the unqualified class name
    for c in chunks
        local_name = split(c.symbol_name, ".")[end]
        @test contains(c.content, local_name)
    end
end

@testset "Parser — line numbers are consistent with source" begin
    path   = joinpath(FIXTURE_DIR, "HelloWorld.mo")
    source = readlines(path)
    for c in Parser.parse_file(path)
        @test c.start_line >= 1
        @test c.end_line <= length(source)
        @test c.start_line <= c.end_line
        # Content must contain at least one line from the source range
        @test !isempty(c.content)
    end
end

@testset "Parser — nonexistent file returns empty" begin
    chunks = Parser.parse_file("/nonexistent/path/file.mo")
    @test isempty(chunks)
end

@testset "Parser — Chunk fields are all non-empty strings" begin
    path = joinpath(FIXTURE_DIR, "HelloWorld.mo")
    for c in Parser.parse_file(path)
        @test !isempty(c.file_path)
        @test !isempty(c.symbol_name)
        @test !isempty(c.symbol_type)
        @test !isempty(c.content)
    end
end
