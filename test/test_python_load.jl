"""
Locates the interpreter for the Python tier: `PSU_PYTHON` override, then the repo-local
`test/python/.venv`, then nothing. Never falls back to a machine-specific absolute path,
so CI without a provisioned venv skips loudly instead of silently passing.
"""
function python_interpreter()
    override = get(ENV, "PSU_PYTHON", "")
    if !isempty(override) && isfile(override)
        return override
    end
    base = joinpath(@__DIR__, "python", ".venv")
    for candidate in (joinpath(base, "bin", "python"),
        joinpath(base, "Scripts", "python.exe"))
        if isfile(candidate)
            return candidate
        end
    end
    return nothing
end

const PYTHON_TIER_SKIP_MESSAGE =
    "SKIPPING python tier: no interpreter. Set PSU_PYTHON or run " *
    "`python3 -m venv test/python/.venv && " *
    "test/python/.venv/bin/pip install -r test/python/requirements.txt`"

function run_checker(python::AbstractString, checker::AbstractString, path::AbstractString)
    out = IOBuffer()
    err = IOBuffer()
    cmd = `$python $checker $path`
    ok = success(pipeline(ignorestatus(cmd); stdout = out, stderr = err))
    return ok, String(take!(out)), String(take!(err))
end

function convert_and_check(
    python::AbstractString,
    checker::AbstractString,
    source::AbstractString,
    tmp::AbstractString,
)
    PSU.convert_system(source, tmp; force = true)
    return run_checker(python, checker, joinpath(tmp, "system.json"))
end

"""
Pulls the validated-component count out of the checker's `OK <n> components validated`
line, so the non-zero assertion checks the number the checker actually printed rather than
just trusting the exit code.
"""
function parse_validated_count(stdout_text::AbstractString)
    m = match(r"OK (\d+) components validated", stdout_text)
    if isnothing(m)
        return 0
    end
    return parse(Int, m.captures[1])
end

"""
Systems that fail Python validation today for a reason unrelated to the translator or to
either confirmed SiennaSchemas defect in test_corpus.jl's `KNOWN_ROUNDTRIP_GAPS`.

Empty: the entries this table used to carry were all three-way schema-version skew between
PowerOpenAPIModels, power-openapi-models and SiennaSchemas, and both bindings now stamp the
same `.schema-version`. Compare those stamps before assuming a future regeneration
reintroduces it; a fresh entry must name its own schema defect, not skew.
"""
const KNOWN_PYTHON_SCHEMA_DRIFT = Dict{String, String}()

function _python_corpus_systems()
    root = joinpath(@__DIR__, "..", "data")
    paths = String[]
    for category in ("PSISystems", "PSITestSystems")
        dir = joinpath(root, category)
        if !isdir(dir)
            continue
        end
        for f in readdir(dir)
            if endswith(f, "_metadata.json") || endswith(f, ".h5")
                continue
            end
            push!(paths, joinpath(dir, f))
        end
    end
    return paths
end

@testset "python loads the document" begin
    python = python_interpreter()
    checker = joinpath(@__DIR__, "python", "check_document.py")
    with_time_series = joinpath(@__DIR__, "..", "data", "PSITestSystems", "c_duration_test")
    without_time_series = joinpath(@__DIR__, "..", "data", "PSITestSystems", "c_sys5")

    if isnothing(python)
        @warn PYTHON_TIER_SKIP_MESSAGE
    else
        has_with_ts = require_corpus_file(with_time_series)
        has_without_ts = require_corpus_file(without_time_series)
        if has_with_ts && has_without_ts
            mktempdir() do tmp
                ok, out, err = convert_and_check(python, checker, with_time_series, tmp)
                if !ok
                    @error "python validation failed on a system with time series" stderr =
                        err
                end
                @test ok
                @test parse_validated_count(out) > 0

                ok, out, err = convert_and_check(python, checker, without_time_series, tmp)
                reason =
                    get(KNOWN_PYTHON_SCHEMA_DRIFT, basename(without_time_series), nothing)
                if isnothing(reason)
                    if !ok
                        @error "python validation failed on a system without time series" stderr =
                            err
                    end
                    @test ok
                else
                    if ok
                        @warn "KNOWN_PYTHON_SCHEMA_DRIFT entry now passes; remove it" system =
                            basename(without_time_series)
                    end
                    @test !ok
                end
            end
        end
    end
end

@testset "python checker rejects a corrupted document" begin
    python = python_interpreter()
    checker = joinpath(@__DIR__, "python", "check_document.py")

    if isnothing(python)
        @warn PYTHON_TIER_SKIP_MESSAGE
    else
        corrupted = Dict(
            "base_power" => 100.0,
            "unit_system" => "DEVICE_BASE",
            "components" => Dict("NotARealComponentType" => [Dict("id" => 1)]),
            "supplemental_attributes" => Dict(),
            "supplemental_attribute_associations" => [],
            "time_series_associations" => [],
            "ext" => Dict(),
            "time_series_storage_file" => "time_series_storage.h5",
        )
        mktempdir() do tmp
            path = joinpath(tmp, "system.json")
            open(path, "w") do io
                write(io, PSU.JSON.json(corrupted))
            end
            ok, out, err = run_checker(python, checker, path)
            @test !ok
            @test occursin("no generated model for component type", err)
        end
    end
end

@testset "python validates the corpus" begin
    python = python_interpreter()
    checker = joinpath(@__DIR__, "python", "check_document.py")
    systems = _python_corpus_systems()

    if isnothing(python)
        @warn PYTHON_TIER_SKIP_MESSAGE
    elseif !require_corpus_systems(systems, "data/ contains no systems for the python tier")
        # already reported by require_corpus_systems above
    else
        accepted = String[]
        rejected = Tuple{String, String}[]
        mktempdir() do tmp
            for path in systems
                name = basename(path)
                out = joinpath(tmp, name)
                # A system in KNOWN_CONVERSION_GAPS (test_corpus.jl) throws inside
                # convert_system itself, before the python checker ever runs — caught here
                # so one such system does not abort the whole sweep, and recorded as a
                # rejection like any other so the gap bookkeeping below stays uniform.
                try
                    ok, _, err = convert_and_check(python, checker, path, out)
                    if ok
                        push!(accepted, name)
                    else
                        push!(rejected, (name, first(split(err, "\n"))))
                    end
                catch e
                    push!(rejected, (name, first(split(sprint(showerror, e), "\n"))))
                end
            end
        end

        @info "python corpus validation" accepted = length(accepted) rejected =
            length(rejected)
        @test !isempty(accepted)

        rejected_names = Set(first.(rejected))
        # c_sys5_hybrid/_ed/_uc are also in KNOWN_CONVERSION_GAPS (test_corpus.jl):
        # MarketBidCost.incremental_offer_curves is an embedded time-series pointer on
        # these three, so conversion now throws before reaching the python checker.
        # test_RTS_GMLC_sys_with_hybrid carried only the scalar shut_down/no_load_cost
        # defect, which the converter now promotes to a curve, so it is no longer a gap.
        # c_pwl_average_cost_test/c_pwl_average_fuel_test were here for the
        # AverageRateCurveFunctionData PIECEWISE_STEP gap; the schema regen fixed it (see
        # KNOWN_ROUNDTRIP_GAPS in test_corpus.jl), so both now pass Python validation too.
        julia_gaps = union(
            Set(["c_sys5_hybrid", "c_sys5_hybrid_ed", "c_sys5_hybrid_uc"]),
            Set(keys(KNOWN_CONVERSION_GAPS)),
        )
        # Only check gap systems this run actually swept: a partial corpus (the 7-system
        # fixture set) legitimately omits some of them, and that omission is not the same
        # finding as one that was swept and unexpectedly started passing.
        present = Set(basename.(systems))
        applicable_gaps = filter(g -> g in present, julia_gaps)
        missing_from_python_rejects = setdiff(applicable_gaps, rejected_names)
        if !isempty(missing_from_python_rejects)
            @error "a Julia round-trip gap now passes Python validation; check whether " *
                   "the corresponding KNOWN_ROUNDTRIP_GAPS entry in test_corpus.jl is stale" system =
                collect(
                    missing_from_python_rejects,
                )
        end
        @test isempty(missing_from_python_rejects)

        extra_rejects = setdiff(rejected_names, julia_gaps)
        if !isempty(extra_rejects)
            @info "python rejects systems beyond Julia's known round-trip gaps -- see " *
                  "task-13-report.md" count = length(extra_rejects)
        end
    end
end
