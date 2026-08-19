"""
Assemble a PSY6 `SystemDocument` from a PSY5 case.

Two passes: the first assigns every component an id so references resolve regardless of the
order PSY5 wrote them; the second translates.
"""
function build_document(case::Psy5Case, report::ConversionReport)
    ledger = Ledger()
    own_components = components(case)
    masked = masked_components(case)
    for raw in own_components
        assign_id!(ledger, component_uuid(raw))
    end
    for raw in masked
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
    # Masked sub-units translate before the HybridSystem that references them, so a
    # sub-unit's skip is known to references_skipped by the time its owner is checked.
    for raw in masked
        for model in translate_component(raw, ctx)
            PCOM.add_component!(doc, model)
        end
    end
    for raw in own_components
        for model in translate_component(raw, ctx)
            PCOM.add_component!(doc, model)
        end
    end
    # allocate_id! may have advanced past the ids reserved above
    PCOM.reserve_ids!(doc, ledger.counter[])

    _add_supplemental_attributes!(doc, case, ctx)
    _add_service_associations!(doc, case, ctx)
    _add_time_series!(doc, case, ledger, report)
    return doc, ledger
end

"""
Push only the association row for an attribute already added under a different owner. IS
supports one attribute shared by many components, and `assign_id!` is idempotent, so a naive
repeat would push the same model twice under one id and `validate_document` would reject it.
"""
function _add_supplemental_association!(
    doc::PCOM.SystemDocument,
    attribute_id::Int,
    owner_id::Int,
    type_name::AbstractString,
)
    push!(
        doc.supplemental_attribute_associations,
        PCOM.SupplementalAttributeAssociation(;
            attribute_id = attribute_id,
            entity_id = owner_id,
            attribute_type = String(type_name),
        ),
    )
    return nothing
end

"""
`raw`'s `services` list (PSY5's `Device.services`, also carried by branches and by
`GroupReserve` for nested membership) names, per entry, a service this entity contributes
to. PSY6 has no such field on the entity itself: the membership becomes one
`ServiceAssociation` row per (service, entity) pair, mirroring how
`_add_supplemental_attributes!` turns PSY5's attribute manager into association rows.

Silently returns when either side was skipped, recording a cascaded skip for the dropped
membership, since the entity or the service not making it into the document is already
recorded once at its own root.
"""
function _add_service_associations_for!(
    doc::PCOM.SystemDocument,
    raw::AbstractDict,
    ctx::TranslationContext,
)
    services = get(raw, "services", nothing)
    if isnothing(services) || isempty(services)
        return nothing
    end
    entity_uuid = component_uuid(raw)
    if is_skipped(ctx.ledger, entity_uuid)
        return nothing
    end
    entity_id = lookup_id(ctx.ledger, entity_uuid)
    for reference in services
        service_uuid = reference_uuid(reference)
        if is_skipped(ctx.ledger, service_uuid)
            record_cascaded_skip!(ctx.report, "ServiceAssociation")
            continue
        end
        service_id = lookup_id(ctx.ledger, service_uuid)
        PCOM.add_service_association!(
            doc,
            POM.ServiceAssociation(; service_id = service_id, entity_id = entity_id),
        )
    end
    return nothing
end

function _add_service_associations!(
    doc::PCOM.SystemDocument,
    case::Psy5Case,
    ctx::TranslationContext,
)
    for raw in masked_components(case)
        _add_service_associations_for!(doc, raw, ctx)
    end
    for raw in components(case)
        _add_service_associations_for!(doc, raw, ctx)
    end
    return nothing
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
    added = Set{String}()
    for association in supplemental_associations(case)
        attribute_uuid = association["attribute_uuid"]
        owner_uuid = association["component_uuid"]
        if !haskey(by_uuid, attribute_uuid)
            record_cascaded_skip!(ctx.report, association["attribute_type"])
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
        owner_id = lookup_id(ctx.ledger, owner_uuid)
        attribute_id = assign_id!(ctx.ledger, attribute_uuid)
        if attribute_uuid in added
            _add_supplemental_association!(doc, attribute_id, owner_id, type_name)
            continue
        end
        push!(added, attribute_uuid)
        model_type = PCOM.model_type(type_name)
        kwargs = build_kwargs(
            model_type,
            raw_attribute,
            ctx.ledger,
            ctx.report;
            extra = Dict{Symbol, Any}(:id => attribute_id),
        )
        PCOM.add_supplemental_attribute!(doc, model_type(; kwargs...), owner_id)
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
        if !owner_translated(ledger, row)
            record_cascaded_skip!(report, string(row["owner_type"]))
            continue
        end
        PCOM.add_time_series_association!(
            doc,
            to_time_series_association(row, ledger, report),
        )
    end
    return nothing
end

"""
The result of one conversion: the assembled `PCOM.SystemDocument`, the `ConversionReport`
of what could not be carried across, and the path to the rewritten time-series sidecar
(`nothing` when the source had none). The sidecar named here is the `.h5` half of the
InfraStore pair [`convert_time_series`](@ref) writes; its `.sqlite` catalog sits beside it
and the two only mean anything together.
"""
struct ConversionResult
    document::PCOM.SystemDocument
    report::ConversionReport
    time_series_file::Union{Nothing, String}
end

"""
Convert one PSY5 case into `out_dir/system.json` plus, when the source has time series, the
`out_dir/time_series.h5` + `out_dir/time_series.h5.sqlite` InfraStore pair.

Passing the same `report` into repeated calls accumulates findings across systems; the
returned `ConversionResult` wraps that same report.
"""
function convert_system(
    src::AbstractString,
    out_dir::AbstractString;
    report::ConversionReport = ConversionReport(),
    force::Bool = false,
)
    case = read_psy5(src)
    push!(report.systems, basename(src))
    doc, ledger = build_document(case, report)
    mkpath(out_dir)
    time_series_file = nothing
    if has_time_series(case)
        time_series_file = convert_time_series(case, ledger, out_dir)
    end
    PCOM.write_document(doc, joinpath(out_dir, "system.json"); force = force)
    return ConversionResult(doc, report, time_series_file)
end
