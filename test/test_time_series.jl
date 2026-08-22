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

    # A non-empty features list has no destination; it must fail loudly, not be dropped.
    let
        row = Dict{String, Any}(
            "id" => 1, "time_series_uuid" => "ts-uuid",
            "time_series_type" => "SingleTimeSeries",
            "initial_timestamp" => "2024-01-01T00:00:00",
            "resolution" => "P0DT3600.000S", "horizon" => nothing,
            "interval" => nothing, "window_count" => nothing, "length" => 24,
            "name" => "max_active_power", "owner_uuid" => "uuid-owner",
            "owner_type" => "PowerLoad", "owner_category" => "Component",
            "features" => "[{\"type\":\"scenario\"}]",
            "scaling_factor_multiplier" => nothing, "metadata_uuid" => "meta-uuid",
            "units" => nothing,
        )
        @test_throws PSU.Psy5FormatError PSU._features(row)
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
