module Parser

using MetaModelica
import Absyn
import OMParser

export Chunk, parse_file

struct Chunk
    file_path::String
    start_line::Int
    end_line::Int
    symbol_name::String  # qualified: "NFInst.instClass"
    symbol_type::String  # "function", "record", "uniontype", "model", etc.
    content::String      # raw MetaModelica source lines
end

# Maps an Absyn.Path to a dot-separated string.
function absyn_path_to_string(p)::String
    @match p begin
        Absyn.IDENT(name)           => name
        Absyn.QUALIFIED(name, rest) => name * "." * absyn_path_to_string(rest)
        Absyn.FULLYQUALIFIED(inner) => absyn_path_to_string(inner)
    end
end

# Maps an Absyn.Restriction to a human-readable symbol_type string.
# Includes MetaModelica-specific types (uniontype) beyond standard Modelica.
function restriction_to_string(r)::String
    @match r begin
        Absyn.R_MODEL()           => "model"
        Absyn.R_FUNCTION(__)      => "function"
        Absyn.R_RECORD()          => "record"
        Absyn.R_BLOCK()           => "block"
        Absyn.R_CONNECTOR()       => "connector"
        Absyn.R_EXP_CONNECTOR()   => "connector"
        Absyn.R_TYPE()            => "type"
        Absyn.R_PACKAGE()         => "package"
        Absyn.R_CLASS()           => "class"
        Absyn.R_OPERATOR()        => "operator"
        Absyn.R_OPERATOR_RECORD() => "operator_record"
        Absyn.R_ENUMERATION()     => "enumeration"
        Absyn.R_OPTIMIZATION()    => "optimization"
        Absyn.R_UNIONTYPE()       => "uniontype"
        _                         => "class"
    end
end

# Returns all direct child Class nodes nested inside a class's body.
# Searches PUBLIC and PROTECTED sections for CLASSDEF element specs.
function collect_nested_classes(cls)
    result = []

    parts_list = @match cls.body begin
        Absyn.PARTS(classParts = cp)    => cp
        Absyn.CLASS_EXTENDS(parts = cp) => cp
        _                               => return result
    end

    for part in parts_list
        elem_items = @match part begin
            Absyn.PUBLIC(contents = c)    => c
            Absyn.PROTECTED(contents = c) => c
            _                             => nothing
        end
        isnothing(elem_items) && continue

        for item in elem_items
            @match item begin
                Absyn.ELEMENTITEM(
                    Absyn.ELEMENT(specification = Absyn.CLASSDEF(class_ = inner))
                ) => push!(result, inner)
                _ => nothing
            end
        end
    end

    result
end

# Parse a MetaModelica source file and return a vector of Chunks.
# Uses OMParser.jl for accurate AST-based extraction.
# Strategy:
#   - Packages are not emitted as chunks (they can be enormous); we recurse into them.
#   - Every other class kind (function, record, uniontype, model, type, etc.)
#     becomes one chunk containing its full source text.
#   - Qualified names are built from the file's `within` clause plus ancestor package names.
function parse_file(path::String)::Vector{Chunk}
    source = try
        read(path, String)
    catch e
        @warn "Cannot read $path: $e"
        return Chunk[]
    end
    lines = split(source, '\n')

    program = try
        OMParser.parseFile(path, 2, 9999)
    catch e
        @warn "Parse error in $path: $e"
        return Chunk[]
    end

    file_prefix = @match program.within_ begin
        Absyn.WITHIN(path = p) => absyn_path_to_string(p)
        Absyn.TOP()             => ""
    end

    chunks     = Chunk[]
    work_stack = [(cls, file_prefix) for cls in program.classes]

    while !isempty(work_stack)
        cls, prefix = pop!(work_stack)

        qname = isempty(prefix) ? cls.name : prefix * "." * cls.name
        rtype = restriction_to_string(cls.restriction)

        cls.info.lineNumberStart == 0 && continue

        is_pkg = @match cls.restriction begin
            Absyn.R_PACKAGE() => true
            _                 => false
        end

        if !is_pkg
            lo      = max(1, cls.info.lineNumberStart)
            hi      = min(length(lines), cls.info.lineNumberEnd)
            content = lo <= hi ? join(lines[lo:hi], "\n") : ""
            push!(chunks, Chunk(path, lo, hi, qname, rtype, content))
        end

        for child in collect_nested_classes(cls)
            push!(work_stack, (child, qname))
        end
    end

    chunks
end

end # module Parser
