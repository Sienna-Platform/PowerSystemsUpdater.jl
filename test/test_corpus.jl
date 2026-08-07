# Every PSY5 type in the corpus that has no PSY6 counterpart. Empty: all 35 measured types
# either match by name or have an explicit translator. A new entry here is a finding about
# SiennaSchemas, not a licence to ignore it.
const KNOWN_GAPS = String[]

# Systems whose output cannot be read back by PSY6's own reader because of a defect in
# SiennaSchemas, not in this translator. Each entry must name the schema defect.
#
# AverageRateCurveFunctionData carries InputOutputCurve's value set, not its own. Ground
# truth from InfrastructureSystems/src/value_curve.jl:
#     InputOutputCurve{T <: Union{Quadratic, Linear, PiecewiseLinear}}
#     IncrementalCurve{T <: Union{Linear, PiecewiseStep}}
#     AverageRateCurve{T <: Union{Linear, PiecewiseStep}}
# The schema models IncrementalCurveFunctionData correctly as {LINEAR, PIECEWISE_STEP} —
# so it understands PiecewiseStepData — but gives AverageRateCurveFunctionData
# {LINEAR, PIECEWISE_LINEAR, QUADRATIC}, a copy of InputOutputCurve's set.
#
# The defect runs both ways: it rejects AverageRateCurve{PiecewiseStepData}, which is
# constructible and appears in real systems, and it accepts AverageRateCurve{Quadratic} and
# {PiecewiseLinear}, which PowerSystems cannot construct at all.
#
# Correct repair upstream: make it exactly {LINEAR, PIECEWISE_STEP}, mirroring
# IncrementalCurveFunctionData. Reported; do NOT work around it in the translator.
#
# MarketBidCost.shut_down / no_load_cost being a bare scalar in PSY5 is no longer a gap:
# the converter promotes the scalar into a constant InputOutputCurve (see
# src/translate/fields.jl). c_sys5_hybrid, c_sys5_hybrid_ed, c_sys5_hybrid_uc also carry an
# embedded time-series pointer on a different MarketBidCost field and so now fail
# conversion outright instead — see KNOWN_CONVERSION_GAPS below.
const KNOWN_ROUNDTRIP_GAPS = Dict(
    "c_pwl_average_cost_test" => "SiennaSchemas: AverageRateCurveFunctionData omits PIECEWISE_STEP",
    "c_pwl_average_fuel_test" => "SiennaSchemas: AverageRateCurveFunctionData omits PIECEWISE_STEP",
)

# Systems that fail conversion outright because a PSY5 value field holds an embedded
# time-series pointer (`__metadata__.type` of `ForecastKey` or `StaticTimeSeriesKey`)
# instead of a literal value. PSY6 has no field type that can represent an embedded
# time-series reference, so `translate_value` throws `Psy5FormatError` rather than
# converting or dropping it — this is intentional, not a bug in the translator.
const KNOWN_CONVERSION_GAPS = Dict(
    "c_linear_fuel_test_ts" => "FuelCurve.fuel_cost is a time-series pointer",
    "c_market_bid_cost" => "MarketBidCost.incremental_offer_curves is a time-series pointer",
    "c_pwl_incremental_fuel_test_ts" => "FuelCurve.fuel_cost is a time-series pointer",
    "c_pwl_io_fuel_test_ts" => "FuelCurve.fuel_cost is a time-series pointer",
    "c_quadratic_fuel_test_ts" => "FuelCurve.fuel_cost is a time-series pointer",
    "c_sys5_hybrid" => "MarketBidCost.incremental_offer_curves is a time-series pointer",
    "c_sys5_hybrid_ed" => "MarketBidCost.incremental_offer_curves is a time-series pointer",
    "c_sys5_hybrid_uc" => "MarketBidCost.incremental_offer_curves is a time-series pointer",
    "c_sys5_re_fuel_cost" => "FuelCurve.fuel_cost is a time-series pointer",
)

"""
System names this test suite hardcodes elsewhere (`test_convert.jl`,
`test_python_load.jl`, `test_time_series.jl`, `test_translate_transformers.jl`).
`test/fixtures/generate_fixtures.jl` must produce every one of them.

A total-count assertion cannot tell the 103-system real corpus apart from the smaller
fixture set the generator produces, and asserting the wrong count against whichever one is
actually present is worse than asserting nothing — so membership is checked by name instead,
which holds for either corpus.
"""
const REQUIRED_SYSTEMS = Set([
    "c_sys5", "c_linear_fuel_test", "c_sys5_hy_uc", "c_sys5_hybrid", "c_sys5_hybrid_uc",
    "c_sys5_hybrid_ed", "test_RTS_GMLC_sys_with_hybrid",
    "case10_radial_series_reductions",
    "c_duration_test", "c_sys5_uc", "c_sys5_hy_ed", "c_sys5_all_components", "c_sys14",
])

function _corpus_systems()
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

@testset "corpus conversion" begin
    systems = _corpus_systems()
    if !require_corpus_systems(
        systems,
        "data/ contains no systems. Generate them with " *
        "scripts/psy5_case_generator/psb_case_generator.jl or " *
        "test/fixtures/generate_fixtures.jl",
    )
        # already reported by require_corpus_systems above
    else
        @info "converting corpus" count = length(systems)
        report = PSU.ConversionReport()
        failures = Tuple{String, String}[]

        mktempdir() do tmp
            for path in systems
                out = joinpath(tmp, basename(path))
                try
                    PSU.convert_system(path, out; report = report, force = true)
                catch e
                    push!(failures, (basename(path), sprint(showerror, e)))
                end
            end
        end

        present = Set(basename.(systems))
        missing_required = setdiff(REQUIRED_SYSTEMS, present)
        if !isempty(missing_required)
            @error "required system(s) missing from the corpus" missing =
                collect(missing_required)
        end
        @test isempty(missing_required)

        unexpected_failures = [p for p in failures if !haskey(KNOWN_CONVERSION_GAPS, p[1])]
        for (name, message) in unexpected_failures
            @error "conversion failed and is not a known conversion gap" system = name message
        end
        @test isempty(unexpected_failures)

        # A known gap that starts passing means the translator was fixed — remove the
        # entry rather than leaving a stale exemption that hides a future regression.
        # Restricted to gaps this run actually swept, same reasoning as the round-trip tier.
        present_conversion_gaps =
            filter(k -> k in present, collect(keys(KNOWN_CONVERSION_GAPS)))
        stale_conversion_gaps =
            [k for k in present_conversion_gaps if !any(p -> p[1] == k, failures)]
        for name in stale_conversion_gaps
            @warn "KNOWN_CONVERSION_GAPS entry now passes; remove it" system = name
        end
        @test isempty(stale_conversion_gaps)

        @test length(report.systems) == length(systems)

        unexpected = setdiff(keys(report.unmapped_types), KNOWN_GAPS)
        if !isempty(unexpected)
            @error "unmapped types not in KNOWN_GAPS" types = collect(unexpected)
            println(sprint(show, MIME("text/plain"), report))
        end
        @test isempty(unexpected)
        @test isempty(report.cascaded_skips)

        @test !isempty(report.unmapped_fields)
        @test haskey(report.unmapped_fields, ("TapTransformer", "tap_limits"))

        # Every recorded dropped field is a finding about the PSY5 -> PSY6 mapping and is
        # the point of this package. Print, never assert empty.
        println(sprint(show, MIME("text/plain"), report))
    end
end

@testset "corpus round trip" begin
    systems = _corpus_systems()
    if !require_corpus_systems(systems, "data/ contains no systems for round-trip testing")
        # already reported by require_corpus_systems above
    else
        broke = Tuple{String, String}[]
        mktempdir() do tmp
            for path in systems
                name = basename(path)
                out = joinpath(tmp, name)
                try
                    PSU.convert_system(path, out; force = true)
                    PSU.PCOM.read_document(joinpath(out, "system.json"))
                catch e
                    push!(broke, (name, first(split(sprint(showerror, e), "\n"))))
                end
            end
        end

        # A system in KNOWN_CONVERSION_GAPS never reaches read_document — convert_system
        # itself throws — so it shows up here too and must be exempted the same way, or
        # every one of those systems would double as an "unexpected" round-trip failure.
        unexpected = [
            p for p in broke if
            !haskey(KNOWN_ROUNDTRIP_GAPS, p[1]) && !haskey(KNOWN_CONVERSION_GAPS, p[1])
        ]
        for (name, message) in unexpected
            @error "round trip failed and is not a known schema gap" system = name message
        end
        @test isempty(unexpected)

        # A known gap that starts passing means the schema was fixed upstream — remove the
        # entry rather than leaving a stale exemption that hides a future regression.
        # Restricted to gaps this run actually swept: the smaller fixture corpus
        # legitimately omits some of them, and an omitted system is not a passing one.
        present = Set(basename.(systems))
        applicable_gaps = filter(k -> k in present, collect(keys(KNOWN_ROUNDTRIP_GAPS)))
        stale = [k for k in applicable_gaps if !any(p -> p[1] == k, broke)]
        for name in stale
            @warn "KNOWN_ROUNDTRIP_GAPS entry now passes; remove it" system = name
        end
        @test isempty(stale)
    end
end
