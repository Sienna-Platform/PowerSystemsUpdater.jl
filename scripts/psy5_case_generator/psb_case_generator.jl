# Build every PowerSystemCaseBuilder system with PowerSystems 5 and serialize each to
# `<out>/<Category>/<case>.json` (with its `_time_series_storage.h5`): the PSY5 corpus for the
# corpus test tier and for `scripts/psy5_psy6_compare`.
#
#   julia --project=scripts/psy5_case_generator \
#       scripts/psy5_case_generator/psb_case_generator.jl [options]
#
# Options:
#   --categories A,B   only these categories (default: every category PSB defines)
#   --systems a,b      only these system names
#   --variants         also build each non-default value of every boolean argument, one at a
#                      time (e.g. `c_sys5_uc__add_reserves_true`)
#   --skip-existing    keep a case whose JSON is already present instead of rebuilding it, to
#                      resume an interrupted run
#   --out DIR          default: data/
#
# A system with a required argument (e.g. `psid_psse_test_avr`'s `avr_type`) is built once per
# allowed value, named `<system>__<argument>_<value>`.
#
# A system that fails to build is recorded and the run moves on. `<out>/psb_build_report.md`
# lists every case's outcome; full errors go to `<out>/psb_build_errors/`. A case's previous
# output is removed before it is rebuilt, so a failed build never leaves an old one behind.

using PowerSystems
using PowerSystemCaseBuilder
const PSB = PowerSystemCaseBuilder

import Dates

const DEFAULT_OUT = normpath(joinpath(@__DIR__, "..", "..", "data"))
const REPORT_FILE = "psb_build_report.md"
const ERRORS_DIR = "psb_build_errors"

struct Options
    categories::Union{Nothing, Vector{String}}
    systems::Union{Nothing, Vector{String}}
    variants::Bool
    skip_existing::Bool
    out::String
end

function parse_options(args)
    categories = nothing
    systems = nothing
    variants = false
    skip_existing = false
    out = DEFAULT_OUT
    i = 1
    while i <= length(args)
        arg = args[i]
        if arg == "--categories"
            categories = String.(split(args[i += 1], ','))
        elseif arg == "--systems"
            systems = String.(split(args[i += 1], ','))
        elseif arg == "--variants"
            variants = true
        elseif arg == "--skip-existing"
            skip_existing = true
        elseif arg == "--out"
            out = abspath(args[i += 1])
        else
            error("unknown option $arg")
        end
        i += 1
    end
    return Options(categories, systems, variants, skip_existing, out)
end

"""
One system to build: the PSB system, the arguments to build it with, and the case name its
output is written under.
"""
struct Case
    category::Type{<:PSB.SystemCategory}
    system::String
    kwargs::Vector{Pair{Symbol, Any}}
end

function case_name(c::Case)
    suffix = join(("__$(k)_$(v)" for (k, v) in sort(c.kwargs; by = first)))
    return c.system * suffix
end

category_name(c::Case) = string(nameof(c.category))

"""
The builds for one system: one per allowed value of each required argument (there is at most
one per system in PSB), then with `variants`, one per non-default value of each boolean
argument on top of the first of those.
"""
function cases_for(descriptor, variants::Bool)
    required = [a for a in descriptor.supported_arguments if isnothing(a.default)]
    bases = if isempty(required)
        [Pair{Symbol, Any}[]]
    else
        vec([
            Pair{Symbol, Any}[a.name => v for (a, v) in zip(required, values)]
            for values in
            Iterators.product((sort!(collect(a.allowed_values)) for a in required)...)
        ])
    end
    cases = [Case(descriptor.category, descriptor.name, base) for base in bases]
    if variants
        for a in descriptor.supported_arguments
            if isnothing(a.default)
                continue
            end
            for v in sort!(collect(a.allowed_values))
                if v != a.default
                    push!(
                        cases,
                        Case(descriptor.category, descriptor.name,
                            vcat(first(bases), [a.name => v])),
                    )
                end
            end
        end
    end
    return cases
end

function selected_cases(options::Options)
    cases = Case[]
    for descriptor in PSB.SYSTEM_CATALOG
        category = string(nameof(descriptor.category))
        if !isnothing(options.categories) && category ∉ options.categories
            continue
        end
        if !isnothing(options.systems) && descriptor.name ∉ options.systems
            continue
        end
        append!(cases, cases_for(descriptor, options.variants))
    end
    sort!(cases; by = c -> (category_name(c), case_name(c)))
    return cases
end

"""
The files `to_json` writes for a case.
"""
function case_files(dir::AbstractString, name::AbstractString)
    return [
        joinpath(dir, "$name.json"),
        joinpath(dir, "$(name)_metadata.json"),
        joinpath(dir, "$(name)_time_series_storage.h5"),
    ]
end

struct Outcome
    case::Case
    status::String
    seconds::Float64
    message::String
end

function build_case(c::Case, options::Options)
    dir = joinpath(options.out, category_name(c))
    name = case_name(c)
    json = joinpath(dir, "$name.json")
    error_path = joinpath(options.out, ERRORS_DIR, "$(category_name(c))__$name.txt")
    if options.skip_existing && isfile(json)
        return Outcome(c, "kept", 0.0, "")
    end
    mkpath(dir)
    for f in (case_files(dir, name)..., error_path)
        rm(f; force = true)
    end
    @info "building" category = category_name(c) case = name
    start = time()
    try
        sys = build_system(c.category, c.system; force_build = true, c.kwargs...)
        to_json(sys, json; force = true)
        return Outcome(c, "built", time() - start, "")
    catch e
        mkpath(dirname(error_path))
        open(error_path, "w") do io
            showerror(io, e, catch_backtrace())
        end
        message = first(split(sprint(showerror, e), '\n'))
        @error "build failed" case = name message
        return Outcome(c, "FAILED", time() - start, message)
    end
end

md_cell(x) = replace(string(x), "|" => "\\|", "\n" => " ")

function write_report(path::AbstractString, outcomes::Vector{Outcome})
    open(path, "w") do io
        println(io, "# PowerSystemCaseBuilder PSY5 build\n")
        println(
            io,
            "$(Dates.now()) · PowerSystems $(pkgversion(PowerSystems)) · " *
            "PowerSystemCaseBuilder $(pkgversion(PSB))\n",
        )
        for status in ("built", "kept", "FAILED")
            println(io, "- $status: $(count(o -> o.status == status, outcomes))")
        end
        println(io, "\n| category | case | status | seconds | error |")
        println(io, "|:--|:--|:--|--:|:--|")
        for o in outcomes
            println(io, "| ",
                join(
                    md_cell.((category_name(o.case), case_name(o.case),
                        o.status, round(o.seconds; digits = 1), o.message)), " | "), " |")
        end
    end
end

function main(args)
    options = parse_options(args)
    cases = selected_cases(options)
    if isempty(cases)
        error("no PowerSystemCaseBuilder systems match the given --categories/--systems")
    end
    @info "building $(length(cases)) case(s)" out = options.out
    outcomes = Outcome[]
    report = joinpath(options.out, REPORT_FILE)
    mkpath(options.out)
    for c in cases
        push!(outcomes, build_case(c, options))
        # Rewritten after every case, so an interrupted run still says how far it got.
        write_report(report, outcomes)
    end
    failed = count(o -> o.status == "FAILED", outcomes)
    @info "done" built = count(o -> o.status == "built", outcomes) kept =
        count(o -> o.status == "kept", outcomes) failed report
    return failed == 0 ? 0 : 1
end

exit(main(ARGS))
