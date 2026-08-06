"""
Assemble a PSY6 `SystemDocument` from a PSY5 case.

Two passes: the first assigns every component an id so references resolve regardless of the
order PSY5 wrote them; the second translates.
"""
function build_document(case::Psy5Case, report::ConversionReport)
    ledger = Ledger()
    raw_components = components(case)
    for raw in raw_components
        assign_id!(ledger, component_uuid(raw))
    end

    storage_file = nothing
    if has_time_series(case)
        storage_file = TIME_SERIES_FILENAME
    end

    metadata = get(case.raw, "metadata", Dict{String, Any}())
    doc = PCOM.SystemDocument(
        system_base_power(case);
        unit_system = "DEVICE_BASE",
        name = get(metadata, "name", nothing),
        description = get(metadata, "description", nothing),
        frequency = get(case.raw, "frequency", nothing),
        time_series_storage_file = storage_file,
    )
    PCOM.reserve_ids!(doc, ledger.counter[])

    ctx = TranslationContext(ledger, report, system_base_power(case))
    for raw in raw_components
        for model in translate_component(raw, ctx)
            PCOM.add_component!(doc, model)
        end
    end
    # allocate_id! may have advanced past the ids reserved above
    PCOM.reserve_ids!(doc, ledger.counter[])

    _add_supplemental_attributes!(doc, case, ctx)
    _add_time_series!(doc, case, ledger, report)
    return doc, ledger
end

function _add_supplemental_attributes!(
    doc::PCOM.SystemDocument,
    case::Psy5Case,
    ctx::TranslationContext,
)
    by_uuid = Dict{String, Any}()
    for attribute in supplemental_attributes(case)
        by_uuid[attribute["internal"]["uuid"]["value"]] = attribute
    end
    for association in supplemental_associations(case)
        attribute_uuid = association["attribute_uuid"]
        owner_uuid = association["component_uuid"]
        if !haskey(by_uuid, attribute_uuid)
            continue
        end
        if is_skipped(ctx.ledger, owner_uuid)
            record_cascaded_skip!(ctx.report, association["attribute_type"])
            continue
        end
        raw_attribute = by_uuid[attribute_uuid]
        type_name = component_type(raw_attribute)
        if !PCOM.has_model_type(type_name)
            record_unmapped_type!(ctx.report, type_name)
            continue
        end
        model_type = PCOM.model_type(type_name)
        attribute_id = assign_id!(ctx.ledger, attribute_uuid)
        kwargs = build_kwargs(
            model_type,
            raw_attribute,
            ctx.ledger,
            ctx.report;
            extra = Dict{Symbol, Any}(:id => attribute_id),
        )
        PCOM.add_supplemental_attribute!(
            doc,
            model_type(; kwargs...),
            lookup_id(ctx.ledger, owner_uuid),
        )
    end
    PCOM.reserve_ids!(doc, ctx.ledger.counter[])
    return nothing
end

"""
Owners that were skipped take their time series with them. `to_time_series_association`
resolves the owner unconditionally, so this filter is what keeps a dropped owner from
raising `DanglingReferenceError` and aborting the whole system — and every association it
drops is recorded rather than silently discarded.
"""
function _add_time_series!(
    doc::PCOM.SystemDocument,
    case::Psy5Case,
    ledger::Ledger,
    report::ConversionReport,
)
    if !has_time_series(case)
        return nothing
    end
    for row in read_associations(case.time_series_path)
        owner_uuid = row["owner_uuid"]
        if is_skipped(ledger, owner_uuid) || !has_id(ledger, owner_uuid)
            record_cascaded_skip!(report, string(row["owner_type"]))
            continue
        end
        PCOM.add_time_series_association!(doc, to_time_series_association(row, ledger))
    end
    return nothing
end

"""
Convert one PSY5 case into `out_dir/system.json` plus `out_dir/time_series.h5`.

Returns the report so a caller converting a corpus can accumulate findings across systems.
"""
function convert_system(
    src::AbstractString,
    out_dir::AbstractString;
    report::ConversionReport = ConversionReport(),
    force::Bool = false,
)
    case = read_psy5(src)
    push!(report.systems, basename(src))
    doc, _ = build_document(case, report)
    mkpath(out_dir)
    if has_time_series(case)
        copy_time_series(case, out_dir)
    end
    PCOM.write_document(doc, joinpath(out_dir, "system.json"); force = force)
    return report
end
