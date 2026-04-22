using MetaModelicaRag: CLI

function write_config(contents::String)
    path = tempname() * ".toml"
    write(path, contents)
    path
end

@testset "CLI — load_config accepts known embedding backends" begin
    for backend in ("ollama", "llama", "github_models")
        path = write_config("""
        [embeddings]
        backend = "$backend"
        """)
        cfg = CLI.load_config(path)
        @test cfg.embed_backend == backend
    end
end

@testset "CLI — load_config rejects unknown embedding backend" begin
    path = write_config("""
    [embeddings]
    backend = "bogus_backend"
    """)
    @test_throws ArgumentError CLI.load_config(path)
end
