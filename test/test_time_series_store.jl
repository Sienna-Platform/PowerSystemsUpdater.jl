import PowerSystems as PSY
using PowerSystems: @u_str

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
                        metadata = only(InfraStore.list_metadata(store))
                        stored = InfraStore.read_by_id(store, metadata.id)
                        @test stored.element_type == "piecewise_step"
                        # read_by_id decodes piecewise_step natively into one
                        # InfraStore.PiecewiseStep(x, y) per timestep, not the raw
                        # (steps, padded_width) matrix `encoded` holds — so the expected
                        # coordinates come straight from the legacy array, not through
                        # `decode_piecewise_step_row`'s matrix-row decoder.
                        @test length(stored.data) == size(legacy_data, 1)
                        for i in 1:size(legacy_data, 1)
                            x, y = decode_legacy_piecewise_step(legacy_data, i)
                            @test stored.data[i].x == x
                            @test stored.data[i].y == y
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
                metadata = InfraStore.list_metadata(catalog)
                @test length(metadata) == length(rows)
                scaled = filter(m -> !isnothing(m.unit_system), metadata)
                @test !isempty(scaled)
                for entry in scaled
                    if entry.units == "MW"
                        @test entry.unit_system === InfraStore.NaturalUnits
                    else
                        @test entry.unit_system === InfraStore.ComponentBase
                    end
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

# ── Scale, label, drop ─────────────────────────────────────────────────────────

const MAX_ACTIVE_MARKER = """{"__metadata__":{"module":"PowerSystems","function":"get_max_active_power"}}"""
const INFLOW_MARKER = """{"__metadata__":{"module":"PowerSystems","function":"get_inflow"}}"""
const REQUIREMENT_MARKER = """{"__metadata__":{"module":"PowerSystems","function":"get_requirement"}}"""

function synthetic_owner(type_name, uuid, fields)
    return Dict{String, Any}(
        "__metadata__" => Dict("type" => type_name),
        "internal" => Dict("uuid" => Dict("value" => uuid)),
        "name" => uuid,
        fields...,
    )
end

function synthetic_row(
    id,
    uuid,
    owner_uuid,
    owner_type,
    marker;
    name = "ts",
    type = "SingleTimeSeries",
    horizon = nothing,
    interval = nothing,
    window_count = nothing,
)
    return Dict{String, Any}(
        "id" => id, "time_series_uuid" => uuid, "time_series_type" => type,
        "initial_timestamp" => "2020-01-01T00:00:00", "resolution" => "P0DT1H",
        "horizon" => horizon, "interval" => interval, "window_count" => window_count,
        "length" => 3, "name" => name, "owner_uuid" => owner_uuid,
        "owner_type" => owner_type, "owner_category" => "Component",
        "features" => "[]", "scaling_factor_multiplier" => marker, "units" => nothing,
    )
end

"""
Write a PSY5 sidecar holding `rows` and one array per row UUID, and return a `Psy5Case` over
`owners`, with every owner assigned an id in the returned ledger.
"""
function synthetic_case(dir, rows, arrays, owners; base = 100.0)
    path = joinpath(dir, "ts_psy5.h5")
    db_path = joinpath(dir, "assoc.sqlite")
    db = PSU.SQLite.DB(db_path)
    columns = collect(keys(first(rows)))
    PSU.SQLite.DBInterface.execute(
        db,
        "CREATE TABLE time_series_associations (" * join(columns, ", ") * ")",
    )
    for row in rows
        PSU.SQLite.DBInterface.execute(
            db,
            "INSERT INTO time_series_associations VALUES (" *
            join(fill("?", length(columns)), ", ") * ")",
            [row[c] for c in columns],
        )
    end
    PSU.SQLite.DBInterface.close!(db)
    PSU.HDF5.h5open(path, "w") do file
        file[PSU.PSY5_TS_METADATA_ROOT_PATH] = read(db_path)
        group = PSU.HDF5.create_group(file, PSU.PSY5_TS_ROOT_PATH)
        for (uuid, data) in arrays
            sub = PSU.HDF5.create_group(group, uuid)
            sub["data"] = data
            PSU.HDF5.attributes(sub)["data_type"] = "CONSTANT"
        end
    end
    raw = Dict{String, Any}(
        "units_settings" => Dict("base_value" => base),
        "data" => Dict("components" => collect(values(owners))),
    )
    ledger = PSU.Ledger()
    for uuid in keys(owners)
        PSU.assign_id!(ledger, uuid)
    end
    return PSU.Psy5Case(raw, path, path), ledger
end

function catalog_entries(out)
    catalog =
        InfraStore.open_store(joinpath(out, PSU.TIME_SERIES_FILENAME); read_only = true)
    try
        return InfraStore.list_metadata(catalog)
    finally
        InfraStore.close!(catalog)
    end
end

@testset "time series scale, label, drop" begin
    owners = Dict(
        "u-gen" => synthetic_owner(
            "ThermalStandard", "u-gen", Dict("max_active_power" => 0.25),
        ),
        "u-unit" => synthetic_owner(
            "ThermalStandard", "u-unit", Dict("max_active_power" => 1.0),
        ),
        "u-res" =>
            synthetic_owner("VariableReserve", "u-res", Dict("requirement" => 0.5)),
        "u-adm" => synthetic_owner("FixedAdmittance", "u-adm", Dict()),
        "u-hyd" => synthetic_owner("HydroReservoir", "u-hyd", Dict()),
    )
    profile = [0.2, 0.4, 0.8]
    rows = [
        synthetic_row(1, "ts-gen", "u-gen", "ThermalStandard", MAX_ACTIVE_MARKER),
        synthetic_row(2, "ts-unit", "u-unit", "ThermalStandard", MAX_ACTIVE_MARKER),
        synthetic_row(3, "ts-res", "u-res", "VariableReserve", REQUIREMENT_MARKER),
        synthetic_row(4, "ts-adm", "u-adm", "FixedAdmittance", MAX_ACTIVE_MARKER),
        synthetic_row(
            5, "fc-adm", "u-adm", "FixedAdmittance", MAX_ACTIVE_MARKER;
            name = "fc", type = "Deterministic", horizon = "P0DT2H",
            interval = "P0DT1H",
            window_count = 2,
        ),
        synthetic_row(
            6, "dst-adm", "u-adm", "FixedAdmittance", nothing;
            name = "ts", type = "DeterministicSingleTimeSeries", horizon = "P0DT2H",
            interval = "P0DT1H",
        ),
        synthetic_row(
            7, "fc-gen", "u-gen", "ThermalStandard", MAX_ACTIVE_MARKER;
            name = "fc", type = "Deterministic", horizon = "P0DT2H",
            interval = "P0DT1H",
            window_count = 2,
        ),
        synthetic_row(
            8,
            "ts-hyd",
            "u-hyd",
            "HydroReservoir",
            INFLOW_MARKER;
            name = "inflow",
        ),
    ]
    windows = [0.2 0.4; 0.6 0.8]
    arrays = Dict{String, Array{Float64}}()
    for r in rows
        if r["time_series_type"] == "Deterministic"
            arrays[r["time_series_uuid"]] = windows
        else
            arrays[r["time_series_uuid"]] = profile
        end
    end
    mktempdir() do tmp
        case, ledger = synthetic_case(tmp, rows, arrays, owners)
        out = joinpath(tmp, "out")
        mkpath(out)
        report = PSU.ConversionReport()
        _, associations = PSU.convert_time_series(case, ledger, out, report)
        entries = catalog_entries(out)
        @test length(entries) == 5
        @test length(associations) == 5

        store = InfraStore.open_store(
            joinpath(out, PSU.TIME_SERIES_FILENAME); read_only = true,
        )
        try
            by_owner = Dict(
                (e.owner_id, e.name) => e for e in entries
            )
            gen = by_owner[(PSU.lookup_id(ledger, "u-gen"), "ts")]
            @test InfraStore.read_by_id(store, gen.id).data == profile .* 0.25
            @test gen.per_unit_of == "base_power"
            @test gen.unit_system === InfraStore.ComponentBase
            @test gen.quantity_kind == "ActivePower"

            unit = by_owner[(PSU.lookup_id(ledger, "u-unit"), "ts")]
            @test InfraStore.read_by_id(store, unit.id).data == profile
            plain = InfraStore.Store(; path = joinpath(tmp, "plain.h5"), overwrite = true)
            try
                InfraStore.add_time_series!(
                    plain, 1, "ThermalStandard", InfraStore.Component,
                    InfraStore.SingleTimeSeries(
                        Dates.DateTime(2020, 1, 1), Dates.Hour(1), profile, "ts";
                        unit_system = InfraStore.ComponentBase,
                        quantity_kind = "ActivePower", per_unit_of = "base_power",
                    ),
                )
                InfraStore.flush!(plain)
                @test only(InfraStore.list_metadata(plain)).data_hash == unit.data_hash
            finally
                InfraStore.close!(plain)
            end

            res = by_owner[(PSU.lookup_id(ledger, "u-res"), "ts")]
            @test InfraStore.read_by_id(store, res.id).data == profile .* 50.0
            @test res.units == "MW"
            @test isnothing(res.per_unit_of)
            @test res.unit_system === InfraStore.NaturalUnits

            forecast = by_owner[(PSU.lookup_id(ledger, "u-gen"), "fc")]
            @test InfraStore.read_by_id(store, forecast.id).data == windows .* 0.25

            inflow = by_owner[(PSU.lookup_id(ledger, "u-hyd"), "inflow")]
            @test InfraStore.read_by_id(store, inflow.id).data == profile
            @test inflow.unit_system === InfraStore.ComponentBase
            @test isnothing(inflow.per_unit_of)
        finally
            InfraStore.close!(store)
        end

        @test report.dropped_time_series ==
              Dict(("FixedAdmittance", "get_max_active_power") => 3)
        @test PSU.has_findings(report)
    end

    # A multiplier on a piecewise layout has no scalar to multiply.
    piecewise_scale() = PSU._scale_values(
        PSU.PiecewiseStepLayout(),
        zeros(2, 4),
        PSU._declaration(
            "get_max_active_power",
            rows[1],
            Dict{String, Any}("u-gen" => owners["u-gen"]),
            100.0,
            PSU.ConversionReport(),
        ),
        rows[1],
    )
    for part in ("ThermalStandard", "u-gen", "name=ts", "get_max_active_power")
        @test_throws part piecewise_scale()
    end
    @test_throws PSU.Psy5FormatError piecewise_scale()
end

@testset "time series unknown accessor and reservoir piecewise" begin
    owners = Dict{String, Any}(
        "u-gen" => synthetic_owner(
            "ThermalStandard", "u-gen", Dict("max_active_power" => 0.25),
        ),
        "u-hyd" => synthetic_owner("HydroReservoir", "u-hyd", Dict()),
    )
    bad_marker = """{"__metadata__":{"module":"PowerSystems","function":"get_nonexistent"}}"""
    bad = synthetic_row(7, "ts-bad", "u-gen", "ThermalStandard", bad_marker; name = "bad")
    for part in ("id=7", "ThermalStandard", "u-gen", "name=bad", "get_nonexistent")
        @test_throws part PSU._has_scale("get_nonexistent", bad, owners, 100.0)
    end
    @test_throws PSU.Psy5FormatError PSU._has_scale("get_nonexistent", bad, owners, 100.0)

    hydro = synthetic_row(
        8, "ts-hyd", "u-hyd", "HydroReservoir", INFLOW_MARKER; name = "inflow",
    )
    declaration = PSU._declaration(
        "get_inflow", hydro, owners, 100.0, PSU.ConversionReport(),
    )
    @test isone(declaration.factor)
    @test declaration.unit_system === InfraStore.ComponentBase
    @test isnothing(declaration.per_unit_of)
    values = zeros(2, 4)
    @test PSU._scale_values(PSU.PiecewiseStepLayout(), values, declaration, hydro) ===
          values
end

# ── Corpus magnitudes ──────────────────────────────────────────────────────────

const RAW_CU_FACTORS = Dict{String, Function}(
    "PowerLoad" => owner -> owner["max_active_power"],
    "RenewableDispatch" => owner -> owner["rating"] * owner["power_factor"],
    "RenewableNonDispatch" => owner -> owner["rating"] * owner["power_factor"],
)

"""
Every `SingleTimeSeries` of `case` that has a PSY5 multiplier and a load or renewable owner,
as `(row, owner, profile)`: the association row, the raw owner and the normalized array PSY5
stored. The test reads the multiplier from the raw owner fields in `RAW_CU_FACTORS`, not
from `PSU.scale_factor`.
"""
function psy5_profiles(case)
    owners = Dict(PSU.component_uuid(raw) => raw for raw in PSU.all_components(case))
    rows = filter(
        r ->
            r["time_series_type"] == "SingleTimeSeries" &&
                !isnothing(PSU._scaling_factor_multiplier(r)) &&
                haskey(RAW_CU_FACTORS, r["owner_type"]),
        PSU.read_associations(case.time_series_path),
    )
    return PSU.HDF5.h5open(case.time_series_path, "r") do file
        [
            (
                row = row,
                owner = owners[row["owner_uuid"]],
                profile = first(PSU._legacy_array(file, row)),
            ) for row in rows
        ]
    end
end

function raw_cu_factor(item)
    return RAW_CU_FACTORS[item.row["owner_type"]](item.owner)
end

is_static_series(::Type{<:InfraStore.SingleTimeSeries}) = true
is_static_series(::Type) = false

@testset "time series corpus magnitudes" begin
    dir = joinpath(@__DIR__, "..", "data")
    for path in (
        joinpath(dir, "PSISystems", "5_bus_matpower_DA"),
        joinpath(dir, "PSITestSystems", "c_sys5_all_components"),
    )
        require_corpus_file(path) || continue
        case = PSU.read_psy5(path)
        _, ledger = PSU.build_document(case, PSU.ConversionReport())
        items = psy5_profiles(case)
        @test !isempty(items)
        mktempdir() do tmp
            PSU.convert_system(path, tmp; force = true)
            entries = catalog_entries(tmp)
            store = InfraStore.open_store(
                joinpath(tmp, PSU.TIME_SERIES_FILENAME); read_only = true,
            )
            try
                by_key = Dict(
                    (e.owner_id, e.name) => e for
                    e in entries if is_static_series(e.time_series_type)
                )
                for item in items
                    entry = by_key[(
                        PSU.lookup_id(ledger, item.row["owner_uuid"]),
                        string(item.row["name"]),
                    )]
                    @test InfraStore.read_by_id(store, entry.id).data ≈
                          item.profile .* raw_cu_factor(item)
                end
            finally
                InfraStore.close!(store)
            end
        end
    end
end

const PSY6_OWNER_TYPES = Dict(
    "PowerLoad" => PSY.PowerLoad,
    "RenewableDispatch" => PSY.RenewableDispatch,
)

const PSY6_SYSTEMS = ("5_bus_matpower_DA", "modified_RTS_GMLC_DA_sys")

@testset "time series PSY6 magnitudes" begin
    for name in PSY6_SYSTEMS
        path = joinpath(@__DIR__, "..", "data", "PSISystems", name)
        require_corpus_file(path) || continue
        case = PSU.read_psy5(path)
        items = filter(
            i -> haskey(PSY6_OWNER_TYPES, i.row["owner_type"]),
            psy5_profiles(case),
        )
        @test !isempty(items)
        if name == "modified_RTS_GMLC_DA_sys"
            system_base = case.raw["units_settings"]["base_value"]
            @test any(i -> i.owner["base_power"] != system_base, items)
        end
        mktempdir() do tmp
            PSU.convert_system(path, tmp; force = true)
            sys = PSY.from_file(joinpath(tmp, "system.json"))
            for item in items
                owner = PSY.get_component(
                    PSY6_OWNER_TYPES[item.row["owner_type"]], sys, item.owner["name"],
                )
                expected = item.profile .* raw_cu_factor(item) .* item.owner["base_power"]
                @test PSY.get_time_series_values(
                    PSY.SingleTimeSeries, owner, string(item.row["name"]), u"MW",
                ) ≈ expected
            end
        end
    end
end
