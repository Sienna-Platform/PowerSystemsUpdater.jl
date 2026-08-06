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
either confirmed SiennaSchemas defect in test_corpus.jl's `KNOWN_ROUNDTRIP_GAPS`: the two
generated bindings, and SiennaSchemas itself, are three distinct schema states, none
matching the other two:

    PowerOpenAPIModels (Julia)    .schema-version = 89f078c-dirty
    power-openapi-models (Python) .schema-version = none
    SiennaSchemas HEAD             db4b48b  (branch jd/ptdp_pffp_integration_changes)

Confirmed root causes as of this writing, all present in the Julia-side schema state and
absent from the Python-side one: Arc's `from`/`to` not yet renamed to `from_id`/`to_id`;
`base_power` not yet added to `Area`/`LoadZone`/`AreaInterchange` and the HVDC line types;
the `*_units` suffix convention not yet extended to
`EnergyReservoirStorage`/`TwoWindingTransformer`/`TransformerCircuit`/`ThreeWindingTransformer`;
the `OnlineReserve` type not yet present; and `VoltageUnitBasis` not yet renamed from
`SYSTEM_BASE` to `DEVICE_BASE`. None of this is fixable in this repo -- see
task-13-report.md. Re-check the three stamps above before assuming a regeneration fixed it.
"""
const KNOWN_PYTHON_SCHEMA_DRIFT = Dict(
    "c_sys5" => "Arc.from/Arc.to not yet renamed to from_id/to_id in power-openapi-models@main",
)

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
        @warn "SKIPPING python tier: no interpreter. Set PSU_PYTHON or run " *
              "`python3 -m venv test/python/.venv && " *
              "test/python/.venv/bin/pip install -r test/python/requirements.txt`"
    elseif !isfile(with_time_series) || !isfile(without_time_series)
        @warn "corpus absent; skipping python tier" with_time_series without_time_series
    else
        mktempdir() do tmp
            ok, out, err = convert_and_check(python, checker, with_time_series, tmp)
            if !ok
                @error "python validation failed on a system with time series" stderr = err
            end
            @test ok
            @test parse_validated_count(out) > 0

            ok, out, err = convert_and_check(python, checker, without_time_series, tmp)
            reason = get(KNOWN_PYTHON_SCHEMA_DRIFT, basename(without_time_series), nothing)
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

@testset "python checker rejects a corrupted document" begin
    python = python_interpreter()
    checker = joinpath(@__DIR__, "python", "check_document.py")

    if isnothing(python)
        @warn "SKIPPING python tier: no interpreter"
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
        @warn "SKIPPING python tier: no interpreter"
    elseif isempty(systems)
        @warn "corpus absent under data/; skipping python corpus scan"
    else
        accepted = String[]
        rejected = Tuple{String, String}[]
        mktempdir() do tmp
            for path in systems
                name = basename(path)
                out = joinpath(tmp, name)
                ok, _, err = convert_and_check(python, checker, path, out)
                if ok
                    push!(accepted, name)
                else
                    push!(rejected, (name, first(split(err, "\n"))))
                end
            end
        end

        @info "python corpus validation" accepted = length(accepted) rejected =
            length(rejected)
        @test !isempty(accepted)

        rejected_names = Set(first.(rejected))
        julia_gaps = Set([
            "c_pwl_average_cost_test", "c_pwl_average_fuel_test", "c_sys5_hybrid",
            "c_sys5_hybrid_ed", "c_sys5_hybrid_uc", "test_RTS_GMLC_sys_with_hybrid",
        ])
        missing_from_python_rejects = setdiff(julia_gaps, rejected_names)
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
