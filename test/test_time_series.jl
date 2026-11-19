@testset "time series" begin
    dir = joinpath(@__DIR__, "..", "data", "PSITestSystems")
    path = joinpath(dir, "c_sys5_uc")
    if require_corpus_file(path)
        case = PSU.read_psy5(path)
        @test PSU.has_time_series(case)

        rows = PSU.read_associations(case.time_series_path)
        @test !isempty(rows)
        row = first(rows)
        for col in ("time_series_uuid", "time_series_type", "owner_uuid", "name")
            @test haskey(row, col)
        end
    end

    # Nullable columns: c_sys5_uc's rows carry a null length, scaling_factor_multiplier,
    # and units; real data must translate to `nothing`, not a stringified "missing".
    if isfile(path)
        case = PSU.read_psy5(path)
        rows = PSU.read_associations(case.time_series_path)
        for row in rows
            @test row["length"] === missing
            @test isnothing(PSU._optional_string_field(row, "units"))
        end
    end

    # Every association in a real, multi-row system's owner survives translation once its
    # owner has an id.
    many_path = joinpath(dir, "c_sys5_hy_ed")
    if require_corpus_file(many_path)
        case = PSU.read_psy5(many_path)
        rows = PSU.read_associations(case.time_series_path)
        @test length(rows) > 1
        led = PSU.Ledger()
        for row in rows
            PSU.assign_id!(led, row["owner_uuid"])
        end
        for row in rows
            @test PSU.owner_translated(led, row)
        end
    end

    # `IS.from_h5_file` cannot load this sidecar at all: some of its associations carry a
    # non-null `scaling_factor_multiplier`, and reconstructing IS's full metadata store
    # deserializes that into a `Function` that needs `PowerSystems` loaded. `read_associations`
    # must not depend on that reconstruction. PSY6 dropped the column, so what the decoded
    # value must produce is, where the accessor names a determinable quantity, a
    # `quantity_kind` — the basis itself is recorded directly in the InfraStore sidecar,
    # not translated here.
    scaled_path = joinpath(dir, "c_sys5_all_components")
    if require_corpus_file(scaled_path)
        case = PSU.read_psy5(scaled_path)
        rows = PSU.read_associations(case.time_series_path)
        @test !isempty(rows)
        multipliers = [PSU._scaling_factor_multiplier(row) for row in rows]
        @test any(!isnothing, multipliers)
        for multiplier in multipliers
            if !isnothing(multiplier)
                # The module prefix is dropped: the name is a label, never resolved.
                @test !startswith(multiplier, "PowerSystems.")
            end
        end
        # Every quantity_kind emitted is a units.json vocabulary name, never an accessor.
        rep = PSU.ConversionReport()
        for (row, multiplier) in zip(rows, multipliers)
            kind = PSU._quantity_kind(multiplier, row, rep)
            if !isnothing(kind)
                @test kind in values(PSU.MULTIPLIER_QUANTITY_KINDS)
            end
        end
    end

    # A multiplier whose quantity cannot be determined from the row alone (the reservoir
    # accessors, whose quantity depends on the owner's level_data_type) is reported rather
    # than guessed at or silently dropped.
    let
        rep = PSU.ConversionReport()
        marker = """{"__metadata__":{"module":"PowerSystems","function":"get_storage_capacity"}}"""
        row = Dict{String, Any}(
            "id" => 1, "time_series_uuid" => "ts-uuid",
            "time_series_type" => "SingleTimeSeries",
            "initial_timestamp" => "2024-01-01T00:00:00",
            "resolution" => "P0DT3600.000S", "horizon" => nothing,
            "interval" => nothing, "window_count" => nothing, "length" => 24,
            "name" => "storage_capacity", "owner_uuid" => "uuid-reservoir-owner",
            "owner_type" => "HydroReservoir", "owner_category" => "Component",
            "features" => "[]", "scaling_factor_multiplier" => marker,
            "metadata_uuid" => "meta-uuid", "units" => nothing,
        )
        multiplier = PSU._scaling_factor_multiplier(row)
        @test isnothing(PSU._quantity_kind(multiplier, row, rep))
        @test haskey(rep.unmapped_fields, ("HydroReservoir", "quantity_kind"))
    end

    # A determinable multiplier maps to its units.json quantity and reports nothing.
    let
        rep = PSU.ConversionReport()
        marker = """{"__metadata__":{"module":"PowerSystems","function":"get_max_active_power"}}"""
        row = Dict{String, Any}(
            "id" => 1, "time_series_uuid" => "ts-uuid",
            "time_series_type" => "SingleTimeSeries",
            "initial_timestamp" => "2024-01-01T00:00:00",
            "resolution" => "P0DT3600.000S", "horizon" => nothing,
            "interval" => nothing, "window_count" => nothing, "length" => 24,
            "name" => "max_active_power", "owner_uuid" => "uuid-load-owner",
            "owner_type" => "PowerLoad", "owner_category" => "Component",
            "features" => "[]", "scaling_factor_multiplier" => marker,
            "metadata_uuid" => "meta-uuid", "units" => nothing,
        )
        multiplier = PSU._scaling_factor_multiplier(row)
        @test PSU._quantity_kind(multiplier, row, rep) == "ActivePower"
        @test isempty(rep.unmapped_fields)
    end

    # A system with no time series sidecar at all.
    no_ts_path = joinpath(dir, "case10_radial_series_reductions")
    if require_corpus_file(no_ts_path)
        case = PSU.read_psy5(no_ts_path)
        @test !PSU.has_time_series(case)
    end

    # Real corpus rows always carry empty features; this must survive as an empty `Dict`,
    # not vanish or turn into a stringified "missing".
    if isfile(path)
        case = PSU.read_psy5(path)
        rows = PSU.read_associations(case.time_series_path)
        @test isempty(PSU._features(first(rows)))
    end

    # PSY5's list of one-pair objects becomes one dictionary; malformed or reserved names
    # fail loudly instead of being dropped.
    let
        row = Dict{String, Any}(
            "name" => "max_active_power", "owner_type" => "PowerLoad",
            "features" => "[{\"year\":2024},{\"scenario\":\"high\"},{\"peak\":true}]",
        )
        @test PSU._features(row) ==
              Dict{String, Any}("year" => 2024, "scenario" => "high", "peak" => true)
        for bad in (
            "[{\"horizon\":2024},{\"horizon_feature\":2030}]",
            "[{\"year\":2024},{\"year\":2030}]",
            "[{\"year\":2024,\"scenario\":\"high\"}]",
        )
            row["features"] = bad
            @test_throws PSU.Psy5FormatError PSU._features(row)
        end
        row["features"] = missing
        @test isempty(PSU._features(row))
    end

    # A reserved name, such as the `horizon` tools that build PSY5 systems from other models
    # write, is carried with a `_feature` suffix, warned about once and reported.
    let
        row = Dict{String, Any}(
            "name" => "max_active_power", "owner_type" => "PowerLoad",
            "features" => "[{\"horizon\":2024}]",
        )
        @test PSU._features(row) == Dict{String, Any}("horizon_feature" => 2024)
        rep = PSU.ConversionReport()
        @test_logs (:warn, r"carried as \"horizon_feature\"") PSU._record_feature_renames!(
            row,
            rep,
        )
        @test rep.approximate_mappings[("PowerLoad", "features.horizon")] == 1
    end

    # The reserved names mirror the schema's TimeSeriesFeatures exclusion list.
    let
        schemas = (PSU.JSON.parse(r.json) for r in PSU.ITSOM._SCHEMA_RESOURCE_DATA)
        defs = only(
            s["\$defs"] for s in schemas if
            haskey(get(s, "\$defs", Dict()), "TimeSeriesFeatures")
        )
        reserved = defs["TimeSeriesFeatures"]["propertyNames"]["not"]["enum"]
        @test PSU.RESERVED_FEATURE_NAMES == Set(String.(reserved))
    end

    # A cost curve's time series key picks its series by features as well as by name.
    let
        led = PSU.Ledger()
        PSU.assign_id!(led, "uuid-owner")
        owner_id = PSU.lookup_id(led, "uuid-owner")
        rows = [
            Dict{String, Any}(
                "association_id" => id, "owner_id" => owner_id, "name" => "fuel_cost",
                "time_series_type" => "SingleTimeSeries", "resolution" => "PT1H",
                "features" => Dict{String, Any}(name => year),
            ) for
            (id, name, year) in ((11, "horizon_feature", 2024), (12, "year", 2030))
        ]
        key = Dict{String, Any}(
            "__metadata__" => Dict("type" => "StaticTimeSeriesKey"),
            "name" => "fuel_cost",
            "features" => Dict{String, Any}("year" => 2030),
        )
        ref = PSU.SeriesRef(-1, "uuid-owner", key)
        @test PSU._series_association_id(ref, rows, led) == 12
        # A key written with the PSY5 name finds the renamed series.
        key["features"] = Dict{String, Any}("horizon" => 2024)
        @test PSU._series_association_id(ref, rows, led) == 11
    end

    # `owner_translated` is what keeps a skipped owner's time series out of both the
    # document and the InfraStore sidecar; `lookup_id` (tested in test_ledger.jl) is what
    # aborts loudly if a row slips through that filter anyway.
    let
        led = PSU.Ledger()
        PSU.mark_skipped!(led, "uuid-owner", "no PSY6 schema for Widget")
        row = Dict{String, Any}("owner_uuid" => "uuid-owner", "owner_type" => "Widget")
        @test !PSU.owner_translated(led, row)
    end
end
