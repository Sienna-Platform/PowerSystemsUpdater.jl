const InfraStore = PSU.InfraStore
const Dates = PSU.Dates

"""
Decode one row of InfraStore's `piecewise_step` encoding back into `(x_coords, y_coords)`.

Spelled out here rather than called from IS so the assertion is against the *format* — the
row is self-describing: the coordinate count, then that many x-coordinates, then one fewer
y-coordinates.
"""
function decode_piecewise_step_row(mat::AbstractMatrix{Float64}, i::Integer)
    n = Int(round(mat[i, 1]))
    return ([mat[i, 1 + j] for j in 1:n], [mat[i, 1 + n + j] for j in 1:(n - 1)])
end

"""
The `(x_coords, y_coords)` PSY5 stored for timestep `i` of a static piecewise-step array,
read straight off its `(steps, padded_width, 2)` layout: the x-column's non-NaN prefix, and
the y-column's matching entries less the placeholder NaN PSY5 prepended to line the two
columns up.
"""
function decode_legacy_piecewise_step(data::AbstractArray{<:Real, 3}, i::Integer)
    n = count(!isnan, view(data, i, :, 1))
    return ([data[i, j, 1] for j in 1:n], [data[i, j, 2] for j in 2:n])
end

@testset "time series store" begin
    # ── Durations ──────────────────────────────────────────────────────────────
    # PSY5 wrote one pattern per Dates.Period, and the patterns overlap: the same digits
    # mean milliseconds, seconds or minutes depending on the suffix and the `T`.
    @test PSU._psy5_duration("P0DT3600.000S") == Dates.Millisecond(3600000)
    @test PSU._psy5_duration("P0DT3600S") == Dates.Second(3600)
    @test PSU._psy5_duration("P0DT5M") == Dates.Minute(5)
    @test PSU._psy5_duration("P0DT1H") == Dates.Hour(1)
    @test PSU._psy5_duration("P7D") == Dates.Day(7)
    @test PSU._psy5_duration("P2W") == Dates.Week(2)
    @test PSU._psy5_duration("P3M") == Dates.Month(3)
    @test PSU._psy5_duration("P1Y") == Dates.Year(1)
    @test_throws PSU.Psy5FormatError PSU._psy5_duration("PT1H")
    @test_throws PSU.Psy5FormatError PSU._psy5_duration("P0DT0.0001S")

    # ── Element layouts ────────────────────────────────────────────────────────
    # A layout with no InfraStore encoding must abort, not pass bytes through: the stores
    # agree on plain scalars and nothing else, so unknown bytes would decode as a different
    # value with no complaint from either side.
    unmapped = Dict{String, Any}(
        "name" => "max_active_power",
        "owner_type" => "PowerLoad",
        "time_series_type" => "SingleTimeSeries",
    )
    @test_throws PSU.Psy5FormatError PSU._element_layout("PiecewiseLinearData", unmapped)
    @test PSU._element_layout("CONSTANT", unmapped) === PSU.ScalarLayout()

    # Scalars carry no element_type: InfraStore derives the dtype from the array itself.
    values, element_type = PSU._static_values(PSU.ScalarLayout(), [1.0, 2.0, 3.0])
    @test values == [1.0, 2.0, 3.0]
    @test isnothing(element_type)

    # A PSY5 piecewise-step element is an (n, 2) matrix NaN-padded along its first axis and
    # stacked; InfraStore wants one self-describing row per timestep. Two timesteps of
    # different length exercise the padding.
    legacy = fill(NaN, 2, 4, 2)
    legacy[1, 1:3, 1] = [0.0, 1.0, 2.0]
    legacy[1, 2:3, 2] = [10.0, 20.0]
    legacy[2, 1:2, 1] = [0.0, 5.0]
    legacy[2, 2, 2] = 30.0
    encoded, element_type = PSU._static_values(PSU.PiecewiseStepLayout(), legacy)
    @test element_type == "piecewise_step"
    # Width is 2 * the widest real coordinate count, not 2 * the stored padded width: PSY5
    # padded each element to the widest one's *element* count, which for an (n, 2) matrix
    # is 2n, so the stored axis is twice as wide as any real coordinate list.
    @test size(encoded) == (2, 6)
    @test decode_piecewise_step_row(encoded, 1) == ([0.0, 1.0, 2.0], [10.0, 20.0])
    @test decode_piecewise_step_row(encoded, 2) == ([0.0, 5.0], [30.0])

    # Deterministic windows gain a window axis and keep the same row encoding per timestep.
    legacy_windows = fill(NaN, 2, 2, 4, 2)
    for w in 1:2
        legacy_windows[1, w, 1:3, 1] = [0.0, 1.0, 2.0]
        legacy_windows[1, w, 2:3, 2] = [10.0 * w, 20.0 * w]
        legacy_windows[2, w, 1:2, 1] = [0.0, 5.0]
        legacy_windows[2, w, 2, 2] = 30.0 * w
    end
    encoded, element_type = PSU._window_values(PSU.PiecewiseStepLayout(), legacy_windows)
    @test element_type == "piecewise_step"
    @test size(encoded) == (2, 2, 6)
    for w in 1:2
        @test decode_piecewise_step_row(encoded[:, w, :], 1) ==
              ([0.0, 1.0, 2.0], [10.0 * w, 20.0 * w])
        @test decode_piecewise_step_row(encoded[:, w, :], 2) == ([0.0, 5.0], [30.0 * w])
    end

    # A layout and an array shape that disagree is malformed data, not a reshape to guess at.
    @test_throws PSU.Psy5FormatError PSU._static_values(
        PSU.PiecewiseStepLayout(),
        [1.0, 2.0],
    )
    @test_throws PSU.Psy5FormatError PSU._window_values(
        PSU.ScalarLayout(),
        fill(0.0, 2, 2, 2),
    )

    # ── Time series kinds ──────────────────────────────────────────────────────
    # Probabilistic and Scenarios have no conversion: their percentiles and scenario count
    # live on the PSY5 metadata object, not in the association table this package reads.
    @test PSU._time_series_kind(
        Dict{String, Any}(
            "time_series_type" => "SingleTimeSeries",
            "name" => "x", "owner_type" => "PowerLoad",
        ),
    ) === PSU.SingleKind()
    @test_throws PSU.Psy5FormatError PSU._time_series_kind(
        Dict{String, Any}(
            "time_series_type" => "Probabilistic",
            "name" => "x", "owner_type" => "PowerLoad",
        ),
    )

    # Real PSY5 piecewise-step bytes, encoded and then written to and read back from an
    # InfraStore store: the store accepts the shape and element type, and every timestep
    # comes back as the coordinates PSY5 stored. `c_sys5_hybrid`'s components cannot be
    # translated yet (MarketBidCost carries an embedded time-series key), so its sidecar is
    # read directly rather than through `convert_system`.
    hybrid = joinpath(@__DIR__, "..", "data", "PSITestSystems", "c_sys5_hybrid")
    if require_corpus_file(hybrid)
        case = PSU.read_psy5(hybrid)
        found = 0
        PSU.HDF5.h5open(case.time_series_path, "r") do file
            root = file[PSU.PSY5_TS_ROOT_PATH]
            for uuid in keys(root)
                group = root[uuid]
                attributes = PSU.HDF5.attributes(group)
                PSU.HDF5.read(attributes["data_type"]) == "PiecewiseStepData" || continue
                PSU.HDF5.read(attributes["type"]) == "SingleTimeSeries" || continue
                legacy_data = PSU.HDF5.read(group["data"])
                encoded, element_type =
                    PSU._static_values(PSU.PiecewiseStepLayout(), legacy_data)
                found += 1
                mktempdir() do tmp
                    store = InfraStore.Store(;
                        path = joinpath(tmp, "pwl.h5"),
                        in_memory = false,
                        overwrite = true,
                    )
                    series = InfraStore.SingleTimeSeries(
                        Dates.DateTime(2020, 1, 1),
                        Dates.Hour(1),
                        encoded,
                        "market_bid_cost";
                        element_type = element_type,
                    )
                    try
                        InfraStore.add_time_series!(
                            store, 1, "ThermalStandard", InfraStore.Component, series,
                        )
                        InfraStore.flush!(store)
                        stored = InfraStore.get_time_series(
                            InfraStore.SingleTimeSeries, store, 1,
                            InfraStore.Component, "market_bid_cost",
                        )
                        @test stored.element_type == "piecewise_step"
                        @test size(stored.data) == size(encoded)
                        for i in 1:size(legacy_data, 1)
                            @test decode_piecewise_step_row(stored.data, i) ==
                                  decode_legacy_piecewise_step(legacy_data, i)
                        end
                    finally
                        InfraStore.close!(store)
                    end
                end
                break
            end
        end
        @test found == 1
    end

    # ── Round trip through the reader PSY6 actually uses ───────────────────────
    # `IS.open_deserialized_infrastore_store` is the call `from_openapi` makes to adopt a
    # bundle's sidecar as the System's store, so a sidecar it can open with every declared
    # series present is one PSY6 can read. A byte-copied PSY5 sidecar cannot get here at
    # all: it has no catalog, and its arrays are keyed by a UUID nothing addresses any more.
    dir = joinpath(@__DIR__, "..", "data", "PSISystems")
    path = joinpath(dir, "5_bus_hydro_ed_sys")
    if require_corpus_file(path)
        case = PSU.read_psy5(path)
        rows = PSU.read_associations(case.time_series_path)
        mktempdir() do tmp
            PSU.convert_system(path, tmp; force = true)
            sidecar = joinpath(tmp, PSU.TIME_SERIES_FILENAME)
            @test isfile(sidecar)
            # The pair is one artifact: the arrays are addressed by content hash and the
            # catalog is the only record of which association owns which hash.
            @test isfile(sidecar * ".sqlite")

            store = IS.open_deserialized_infrastore_store(sidecar, nothing, true)
            try
                counts = InfraStore.get_counts(store.inner)
                expected_static =
                    count(r -> r["time_series_type"] == "SingleTimeSeries", rows)
                expected_forecasts = count(
                    r -> r["time_series_type"] in
                    ("Deterministic", "DeterministicSingleTimeSeries"),
                    rows,
                )
                @test counts.static_time_series == expected_static
                @test counts.forecasts == expected_forecasts
            finally
                IS.close!(store)
            end

            # Every declared series is addressable in the catalog under the document id of
            # its owner, and carries the basis and quantity the association row declares.
            catalog = InfraStore.open_store(sidecar; read_only = true)
            try
                metadata = InfraStore.list_time_series(catalog)
                @test length(metadata) == length(rows)
                scaled = filter(m -> !isnothing(m.unit_system), metadata)
                @test !isempty(scaled)
                for entry in scaled
                    @test entry.unit_system === InfraStore.ComponentBase
                end
                for entry in metadata
                    @test entry.owner_id > 0
                end
            finally
                InfraStore.close!(catalog)
            end
        end
    end

    # A sidecar whose derived forecasts cover only some of the SingleTimeSeries at a
    # resolution cannot be reproduced: InfraStore derives from every series at a resolution
    # or none. Dropping one static row from the corpus's row set makes the derived set
    # over-cover, and that must abort rather than write a store with extra forecasts.
    if isfile(path)
        case = PSU.read_psy5(path)
        rows = PSU.read_associations(case.time_series_path)
        derived = filter(
            r -> r["time_series_type"] == "DeterministicSingleTimeSeries",
            rows,
        )
        statics = filter(r -> r["time_series_type"] == "SingleTimeSeries", rows)
        @test !isempty(derived)
        @test length(derived) == length(statics)
        mktempdir() do tmp
            store = InfraStore.Store(;
                path = joinpath(tmp, "partial.h5"),
                in_memory = false,
                overwrite = true,
            )
            try
                @test_throws PSU.Psy5FormatError PSU._derive_forecasts!(
                    store,
                    vcat(derived, statics[2:end]),
                )
            finally
                InfraStore.close!(store)
            end
        end
    end
end
