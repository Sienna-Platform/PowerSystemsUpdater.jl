"""
Assemble a PSY6 `SystemDocument` from a PSY5 case: first assign every component an id so
references resolve in any order, then translate.
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
    doc = PCOM.SystemDocument(;
        name = get(metadata, "name", nothing),
        description = get(metadata, "description", nothing),
        frequency = get(case.raw, "frequency", nothing),
        time_series_storage_file = storage_file,
    )
    PCOM.reserve_ids!(doc, ledger.counter)

    ctx = TranslationContext(
        ledger,
        report,
        system_base_power(case),
        BusIndex(vcat(own_components, masked)),
    )
    # Masked sub-units go first so their skips are known when their HybridSystem is checked.
    for raw in masked
        _add_translated!(doc, raw, ctx)
    end
    for raw in own_components
        _add_translated!(doc, raw, ctx)
    end
    PCOM.reserve_ids!(doc, ledger.counter)

    _add_supplemental_attributes!(doc, case, ctx)
    _add_service_associations!(doc, case, ctx)
    _record_time_series_skips!(case, ledger, report)
    doc = _apply_bus_voltage_setpoints(doc, ledger)
    PCOM.reserve_ids!(doc, ledger.counter)
    return doc, ledger
end

"""
`doc` with each bus's `voltage_setpoint` set from the setpoints recorded during translation
(`record_bus_voltage_setpoint!`). Buses are translated before the converters that regulate
them, so this runs afterwards through the document tree, as `resolve_series_refs` does.
"""
function _apply_bus_voltage_setpoints(doc::PCOM.SystemDocument, ledger::Ledger)
    if isempty(ledger.bus_voltage_setpoints)
        return doc
    end
    setpoints = Dict{Int, Float64}(
        lookup_id(ledger, uuid) => value for (uuid, value) in ledger.bus_voltage_setpoints
    )
    tree = PCOM.document_tree(doc)
    for bus in get(tree["components"], "ACBus", Any[])
        if haskey(setpoints, bus["id"])
            bus["voltage_setpoint"] = setpoints[bus["id"]]
        end
    end
    return PCOM.document_from_json(tree)
end

"""Translate `raw`, add the models to `doc`, and carry its `ext` across unless skipped."""
function _add_translated!(
    doc::PCOM.SystemDocument,
    raw::AbstractDict,
    ctx::TranslationContext,
)
    models = translate_component(raw, ctx)
    for model in models
        PCOM.add_component!(doc, model)
    end
    if !isempty(models)
        _carry_ext!(doc, raw, ctx)
    end
    return nothing
end

"""PSY5 types whose PSY6 model has no `ext`; PowerSystems' importer ignores their entries."""
const TYPES_WITHOUT_EXT = Set(["Arc", "TransmissionInterface"])

"""
The `ext` key holding a component's PSY5 values with no PSY6 field, as `field => value` (a
nested struct's field is `Type.field`), as PSY5 stored them.
"""
const UNMAPPED_EXT_KEY = "psy5_unmapped"

"""
Carry `raw`'s PSY5 `ext`, plus the values translation kept (`keep_unmapped!`, under
`UNMAPPED_EXT_KEY`), into `doc.ext` by PSY6 id. A transformer's entry goes on the transformer,
not its circuits, which have no `ext`.
"""
function _carry_ext!(doc::PCOM.SystemDocument, raw::AbstractDict, ctx::TranslationContext)
    uuid = component_uuid(raw)
    ext = Dict{String, Any}(something(get(raw, "ext", nothing), Dict{String, Any}()))
    unmapped = unmapped_values(ctx.ledger, uuid)
    has_unmapped = !isnothing(unmapped) && !isempty(unmapped)
    if isempty(ext) && !has_unmapped
        return nothing
    end
    type_name = component_type(raw)
    if type_name in TYPES_WITHOUT_EXT
        if !isempty(ext)
            record_unmapped_field!(ctx.report, type_name, "ext")
        end
        return nothing
    end
    if has_unmapped
        if haskey(ext, UNMAPPED_EXT_KEY)
            throw(
                Psy5FormatError(
                    "$type_name $(get(raw, "name", uuid)) already has an ext key " *
                    "\"$UNMAPPED_EXT_KEY\", which the updater reserves for unmapped PSY5 fields",
                ),
            )
        end
        ext[UNMAPPED_EXT_KEY] = unmapped
    end
    doc.ext[lookup_id(ctx.ledger, uuid)] = ext
    return nothing
end

"""
PSY5 `ImpedanceCorrectionData.impedance_correction_curve` becomes the PSY6 field named for its
`transformer_control_mode`. A phase-shift curve's x axis is degrees in PSY5, radians in PSY6.
"""
function _impedance_correction_curve(raw::AbstractDict)
    curve = get(raw, "impedance_correction_curve", nothing)
    mode = get(raw, "transformer_control_mode", nothing)
    if isnothing(curve) || !(mode in ("TAP_RATIO", "PHASE_SHIFT_ANGLE"))
        return raw
    end
    derived = copy(raw)
    delete!(derived, "impedance_correction_curve")
    if mode == "TAP_RATIO"
        derived["tap_ratio_correction_curve"] = curve
    else
        radians = Dict{String, Any}(curve)
        radians["points"] = [
            merge(Dict{String, Any}(p), Dict{String, Any}("x" => p["x"] * pi / 180))
            for
            p in curve["points"]
        ]
        derived["phase_angle_correction_curve"] = radians
    end
    return derived
end

"""Supplemental attribute fields mapped onto differently named PSY6 fields, by attribute type."""
const ATTRIBUTE_DERIVATIONS =
    Dict{String, Function}("ImpedanceCorrectionData" => _impedance_correction_curve)

_derive_attribute_fields(type_name::AbstractString, raw::AbstractDict) =
    get(ATTRIBUTE_DERIVATIONS, type_name, identity)(raw)

"""
Add only the association row for an attribute already added under another owner (IS shares one
attribute among components); adding the model again would fail `validate_document`. Type names
are PSY6's.
"""
function _add_supplemental_association!(
    doc::PCOM.SystemDocument,
    attribute_id::Int,
    owner_id::Int,
    attribute_model_type::Type,
)
    if !haskey(doc.component_types_by_id, owner_id)
        throw(
            ArgumentError(
                "supplemental attribute $attribute_id: owner id $owner_id is not in the document",
            ),
        )
    end
    push!(
        doc.supplemental_attribute_associations,
        ICOM.SupplementalAttributeAssociation(;
            component_id = owner_id,
            component_type = doc.component_types_by_id[owner_id],
            attribute_id = attribute_id,
            attribute_type = string(nameof(attribute_model_type)),
        ),
    )
    return nothing
end

"""
Turn `raw`'s `services` list into one `ServiceAssociation` row per (service, entity). A
skipped service is recorded as a cascaded skip; a skipped entity is already on the report.
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
            POOM.ServiceAssociation(; service_id = service_id, entity_id = entity_id),
        )
    end
    return nothing
end

function _add_service_associations!(
    doc::PCOM.SystemDocument,
    case::Psy5Case,
    ctx::TranslationContext,
)
    for raw in all_components(case)
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
        if !ICOM.has_model_type(type_name)
            record_unmapped_type!(ctx.report, type_name)
            continue
        end
        owner_id = lookup_id(ctx.ledger, owner_uuid)
        attribute_id = assign_id!(ctx.ledger, attribute_uuid)
        model_type = ICOM.model_type(type_name)
        if attribute_uuid in added
            _add_supplemental_association!(doc, attribute_id, owner_id, model_type)
            continue
        end
        push!(added, attribute_uuid)
        kwargs = build_kwargs(
            model_type,
            _derive_attribute_fields(type_name, raw_attribute),
            ctx.ledger,
            ctx.report;
            extra = Dict{Symbol, Any}(:id => attribute_id),
        )
        PCOM.add_supplemental_attribute!(doc, model_type(; kwargs...), owner_id)
    end
    PCOM.reserve_ids!(doc, ctx.ledger.counter)
    return nothing
end

"""
Record on `report` the time series lost with skipped owners. The document's association rows
come from [`convert_time_series`](@ref) reading back the sidecar, not from here.
"""
function _record_time_series_skips!(
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
        end
    end
    return nothing
end

"""PSY5 key types, by the association `time_series_type`s each can name."""
const SERIES_KEY_TYPES = Dict(
    "StaticTimeSeriesKey" => Set(["SingleTimeSeries"]),
    "ForecastKey" => Set([
        "Deterministic", "DeterministicSingleTimeSeries", "Probabilistic",
        "Scenarios",
    ]),
)

const ISO_DURATION =
    r"^P(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+(?:\.\d+)?)S)?)?$"

"""Milliseconds in a PSY5 period (`{"value": 1, "type": "Hour"}`) or an ISO 8601 duration."""
function _milliseconds(period::AbstractDict)
    unit = getproperty(Dates, Symbol(period["type"]))
    return Dates.value(Dates.Millisecond(unit(period["value"])))
end
function _milliseconds(iso::AbstractString)
    m = match(ISO_DURATION, iso)
    if isnothing(m)
        throw(Psy5FormatError("unrecognized ISO 8601 duration $iso"))
    end
    parts = (something(x, "0") for x in m.captures)
    days, hours, minutes, seconds = (parse(Float64, p) for p in parts)
    return round(Int, ((days * 24 + hours) * 60 + minutes) * 60_000 + seconds * 1000)
end
_milliseconds(::Nothing) = nothing

"""
The id of the one association row matching a deferred `SeriesRef`: same owner, name, kind,
features and, if the key gives one, resolution.
"""
function _series_association_id(ref::SeriesRef, rows, ledger::Ledger)
    key = ref.key
    key_type = _psy5_type_name(key)
    owner_id = lookup_id(ledger, ref.owner_uuid)
    resolution = _milliseconds(get(key, "resolution", nothing))
    matches = [
        row for row in rows if row["owner_id"] == owner_id &&
        row["name"] == key["name"] &&
        row["time_series_type"] in SERIES_KEY_TYPES[key_type] &&
        get(row, "features", Dict()) == get(key, "features", Dict()) &&
        (isnothing(resolution) || _milliseconds(row["resolution"]) == resolution)
    ]
    if length(matches) != 1
        throw(
            Psy5FormatError(
                "time series key $(key["name"]) ($key_type) on owner id $owner_id names " *
                "$(length(matches)) associations in the converted sidecar, not one",
            ),
        )
    end
    return Int(only(matches)["association_id"])
end

_replace_placeholders!(x, ::AbstractDict{Int, Int}) = x
_replace_placeholders!(x::AbstractVector, ids::AbstractDict{Int, Int}) =
    foreach(v -> _replace_placeholders!(v, ids), x)
function _replace_placeholders!(x::AbstractDict, ids::AbstractDict{Int, Int})
    for (k, v) in x
        if k in values(SERIES_REF_FIELDS) && haskey(ids, v)
            x[k] = ids[v]
        else
            _replace_placeholders!(v, ids)
        end
    end
    return x
end

"""
`doc` with each deferred `SeriesRef` placeholder replaced by its association id. The catalog
that mints the ids is written after the components, so the document is rebuilt from its tree.
"""
function resolve_series_refs(doc::PCOM.SystemDocument, ledger::Ledger)
    if isempty(ledger.series_refs)
        return doc
    end
    tree = PCOM.document_tree(doc)
    rows = get(tree, "time_series_associations", Any[])
    ids = Dict{Int, Int}(
        ref.placeholder => _series_association_id(ref, rows, ledger) for
        ref in ledger.series_refs
    )
    _replace_placeholders!(tree, ids)
    return PCOM.document_from_json(tree)
end

"""
The result of one conversion: the `PCOM.SystemDocument`, the `ConversionReport`, and the
time series `.h5` sidecar path (`nothing` without time series); its `.sqlite` catalog sits
beside it.
"""
struct ConversionResult
    document::PCOM.SystemDocument
    report::ConversionReport
    time_series_file::Union{Nothing, String}
end

"""
Convert one PSY5 case into `out_dir/system.json` plus, with time series, the InfraStore pair
`out_dir/time_series.h5` and `out_dir/time_series.h5.sqlite`. The catalog also holds the
supplemental attribute associations, so PSY6 can adopt it read-only.

The document's time series association rows are read back from the sidecar
([`convert_time_series`](@ref)), since only its catalog has the `uri`/`data_hash`/etc. PSY6
validates. Passing the same `report` to repeated calls accumulates findings across systems.
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
        time_series_file, associations = convert_time_series(
            case, ledger, out_dir, report;
            supplemental_associations = doc.supplemental_attribute_associations,
        )
        for assoc in associations
            PCOM.add_time_series_association!(doc, assoc)
        end
    end
    doc = resolve_series_refs(doc, ledger)
    PCOM.write_document(doc, joinpath(out_dir, "system.json"); force = force)
    return ConversionResult(doc, report, time_series_file)
end
