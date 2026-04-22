# deps/build.jl
# For local development only. Overrides [sources] entries in Project.toml with
# local copies when found, so edits are picked up immediately via Revise.jl.
#
# Resolution order for each package:
#   1. Env var <PKG>_PATH         — e.g. METAMODELICA_PATH=/path/to/MetaModelica.jl
#   2. Sibling directory           — ../PackageName.jl relative to this project
#
# OMParser is excluded here because this repo's committed [sources] entry
# conflicts with Pkg.develop(path=...) for that dependency. Use a manual
# `Pkg.add(path=...)` override for OMParser instead.
#
# If neither is found the package is left to [sources] / Pkg.instantiate().
# After local overrides are applied, this script also runs `Pkg.build("OMParser")`
# so the native parser library is installed in the active environment.
# Run this script once after cloning: julia --project deps/build.jl

import Pkg

const PROJECT_DIR = dirname(dirname(abspath(@__FILE__)))
const PACKAGES = ["MetaModelica", "Absyn"]
const OMPARSER_ENV_KEY = "OMPARSER_PATH"

Pkg.activate(PROJECT_DIR)

developed_any = false

for name in PACKAGES
    env_key = uppercase(name) * "_PATH"
    explicit = get(ENV, env_key, "")
    local_path = if !isempty(explicit) && isdir(explicit)
        abspath(explicit)
    else
        sibling = abspath(joinpath(PROJECT_DIR, "..", name * ".jl"))
        isdir(sibling) ? sibling : nothing
    end

    if local_path !== nothing
        println("$name: developing from $local_path")
        Pkg.develop(path = local_path)
        global developed_any = true
    else
        println("$name: no local copy found, using [sources]")
    end
end

if developed_any
    println("\nRun `Pkg.instantiate()` (or restart with --project) to resolve remaining deps.")
end

omparser_path = get(ENV, OMPARSER_ENV_KEY, "")
if !isempty(omparser_path)
    println("""

OMParser: skipped in deps/build.jl.
This repo's committed [sources].OMParser entry conflicts with Pkg.develop(path=...).
To override OMParser locally on this machine, run instead:

  julia --project -e 'import Pkg; Pkg.add(path=expanduser("$omparser_path"))'
""")
else
    println("""

OMParser: skipped in deps/build.jl.
To override OMParser locally, run:

  export OMPARSER_PATH=/path/to/OMParser.jl
  julia --project -e 'import Pkg; Pkg.add(path=expanduser(ENV["OMPARSER_PATH"]))'
""")
end

println("\nBuilding OMParser native parser library ...")
Pkg.build("OMParser")
println("OMParser build complete.")
