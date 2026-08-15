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

        led = PSU.Ledger()
        owner = PSU.assign_id!(led, row["owner_uuid"])
        assoc = PSU.to_time_series_association(row, led)
        @test assoc.owner_id == owner
        @test assoc.time_series_uuid == row["time_series_uuid"]
        @test assoc.name == row["name"]

        mktempdir() do tmp
            dest = PSU.copy_time_series(case, tmp)
            @test basename(dest) == PSU.TIME_SERIES_FILENAME
            @test isfile(dest)
            @test filesize(dest) == filesize(case.time_series_path)
        end
    end

    # Nullable columns: c_sys5_uc's rows carry a null length, scaling_factor_multiplier,
    # and units; real data must translate to `nothing`, not a stringified "missing".
    if isfile(path)
        case = PSU.read_psy5(path)
        rows = PSU.read_associations(case.time_series_path)
        led = PSU.Ledger()
        for row in rows
            PSU.assign_id!(led, row["owner_uuid"])
        end
        for row in rows
            @test row["length"] === missing
            assoc = PSU.to_time_series_association(row, led)
            @test isnothing(assoc.length)
            @test isnothing(assoc.scaling_factor_multiplier)
            @test isnothing(assoc.units)
        end
    end

    # Every association in a real, multi-row system translates without throwing.
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
            assoc = PSU.to_time_series_association(row, led)
            @test typeof(assoc) === PSU.PCOM.TimeSeriesAssociation
        end
    end

    # `IS.from_h5_file` cannot load this sidecar at all: some of its associations carry a
    # non-null `scaling_factor_multiplier`, and reconstructing IS's full metadata store
    # deserializes that into a `Function` that needs `PowerSystems` loaded. `read_associations`
    # must not depend on that reconstruction, and the decoded value must be the dot-encoded
    # name PSY6's schema documents, not the raw serialized-function JSON.
    scaled_path = joinpath(dir, "c_sys5_all_components")
    if require_corpus_file(scaled_path)
        case = PSU.read_psy5(scaled_path)
        rows = PSU.read_associations(case.time_series_path)
        @test !isempty(rows)
        led = PSU.Ledger()
        for row in rows
            PSU.assign_id!(led, row["owner_uuid"])
        end
        scaled = [PSU.to_time_series_association(row, led) for row in rows]
        with_multiplier = filter(a -> !isnothing(a.scaling_factor_multiplier), scaled)
        @test !isempty(with_multiplier)
        for assoc in with_multiplier
            @test startswith(assoc.scaling_factor_multiplier, "PowerSystems.get_")
        end
    end

    # A system with no time series sidecar at all.
    no_ts_path = joinpath(dir, "case10_radial_series_reductions")
    if require_corpus_file(no_ts_path)
        case = PSU.read_psy5(no_ts_path)
        @test !PSU.has_time_series(case)
    end

    # Real corpus rows always carry empty features; this must survive as `[]`, not vanish.
    if isfile(path)
        case = PSU.read_psy5(path)
        rows = PSU.read_associations(case.time_series_path)
        led = PSU.Ledger()
        row = first(rows)
        PSU.assign_id!(led, row["owner_uuid"])
        assoc = PSU.to_time_series_association(row, led)
        @test isempty(assoc.features)
    end

    # A non-empty features list has no destination; it must fail loudly, not be dropped.
    let
        led = PSU.Ledger()
        PSU.assign_id!(led, "uuid-owner")
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
        @test_throws PSU.Psy5FormatError PSU.to_time_series_association(row, led)
    end

    # `lookup_id` resolves the owner unconditionally; a skipped owner must abort loudly
    # rather than silently produce a dangling `owner_id`. Filtering is the caller's job
    # (documented on `to_time_series_association`), not this function's.
    let
        led = PSU.Ledger()
        PSU.mark_skipped!(led, "uuid-owner", "no PSY6 schema for Widget")
        row = Dict{String, Any}(
            "id" => 1, "time_series_uuid" => "ts-uuid",
            "time_series_type" => "SingleTimeSeries",
            "initial_timestamp" => "2024-01-01T00:00:00",
            "resolution" => "P0DT3600.000S", "horizon" => nothing,
            "interval" => nothing, "window_count" => nothing, "length" => 24,
            "name" => "max_active_power", "owner_uuid" => "uuid-owner",
            "owner_type" => "PowerLoad", "owner_category" => "Component",
            "features" => "[]", "scaling_factor_multiplier" => nothing,
            "metadata_uuid" => "meta-uuid", "units" => nothing,
        )
        @test_throws PSU.DanglingReferenceError PSU.to_time_series_association(row, led)
    end
end
