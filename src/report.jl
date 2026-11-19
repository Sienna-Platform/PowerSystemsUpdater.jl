"""
Aggregated findings from one or more conversions. Root skips (`unmapped_types`) are counted
apart from `cascaded_skips`, which are components dropped only because something they
reference was dropped, so one missing type does not read as many failures.

Counts are by type or `(type, field)`:

  - `unmapped_fields`: PSY5 fields with no PSY6 counterpart, kept in the component's `ext`.
  - `unverified_units`: a PSY5 value that could not be converted to the physical unit PSY6
    declares; written as stored if required, else kept in `ext`.
  - `dropped_dynamic_models`: static devices kept without their dynamic model.
  - `dropped_invalid_values`: non-physical PSY5 values (such as a base voltage of 0), left unset.
  - `approximate_mappings`: written, but known not to reproduce PSY5 exactly.
  - `schema_defaults`: schema defaults written where PowerSystems requires the field.
  - `psy5_defaults`: PSY5's own defaults filled for fields an older file omits.
"""
Base.@kwdef mutable struct ConversionReport
    unmapped_types::Dict{String, Int} = Dict{String, Int}()
    cascaded_skips::Dict{String, Int} = Dict{String, Int}()
    unmapped_fields::Dict{Tuple{String, String}, Int} =
        Dict{Tuple{String, String}, Int}()
    unverified_units::Dict{Tuple{String, String}, Int} =
        Dict{Tuple{String, String}, Int}()
    dropped_dynamic_models::Dict{String, Int} = Dict{String, Int}()
    dropped_invalid_values::Dict{Tuple{String, String}, Int} =
        Dict{Tuple{String, String}, Int}()
    approximate_mappings::Dict{Tuple{String, String}, Int} =
        Dict{Tuple{String, String}, Int}()
    schema_defaults::Dict{Tuple{String, String}, Int} = Dict{Tuple{String, String}, Int}()
    psy5_defaults::Dict{Tuple{String, String}, Int} = Dict{Tuple{String, String}, Int}()
    systems::Vector{String} = String[]
end

function _bump!(counts::AbstractDict, key)
    counts[key] = get(counts, key, 0) + 1
    return nothing
end

record_unmapped_type!(report::ConversionReport, type_name::AbstractString) =
    _bump!(report.unmapped_types, String(type_name))

record_cascaded_skip!(report::ConversionReport, type_name::AbstractString) =
    _bump!(report.cascaded_skips, String(type_name))

record_unmapped_field!(
    report::ConversionReport,
    type_name::AbstractString,
    field::AbstractString,
) = _bump!(report.unmapped_fields, (String(type_name), String(field)))

record_unverified_unit!(
    report::ConversionReport,
    type_name::AbstractString,
    field::AbstractString,
) = _bump!(report.unverified_units, (String(type_name), String(field)))

record_dropped_dynamic_model!(report::ConversionReport, static_type::AbstractString) =
    _bump!(report.dropped_dynamic_models, String(static_type))

record_dropped_invalid_value!(
    report::ConversionReport,
    type_name::AbstractString,
    field::AbstractString,
) = _bump!(report.dropped_invalid_values, (String(type_name), String(field)))

record_approximate_mapping!(
    report::ConversionReport,
    type_name::AbstractString,
    field::AbstractString,
) = _bump!(report.approximate_mappings, (String(type_name), String(field)))

record_schema_default!(
    report::ConversionReport,
    type_name::AbstractString,
    field::AbstractString,
) = _bump!(report.schema_defaults, (String(type_name), String(field)))

record_psy5_default!(
    report::ConversionReport,
    type_name::AbstractString,
    field::AbstractString,
) = _bump!(report.psy5_defaults, (String(type_name), String(field)))

"""Report fields in display order, with each one's section title."""
const REPORT_SECTIONS = (
    (:unmapped_types, "UNMAPPED TYPES (skipped, no PSY6 model)"),
    (:cascaded_skips, "CASCADED SKIPS (skipped, reference a skipped component)"),
    (:unmapped_fields, "UNMAPPED FIELDS (no PSY6 field, kept in ext)"),
    (:unverified_units, "UNVERIFIED UNITS (PSY5 unit unknown, not converted)"),
    (:dropped_dynamic_models, "DYNAMIC MODELS DROPPED (static device kept)"),
    (:dropped_invalid_values, "INVALID VALUES DROPPED (non-physical, left unset)"),
    (:approximate_mappings, "APPROXIMATE MAPPINGS (written, see log for components)"),
    (:schema_defaults, "SCHEMA DEFAULTS WRITTEN (no PSY5 value)"),
    (:psy5_defaults, "PSY5 DEFAULTS FILLED (field missing from an older file)"),
)

const REPORT_SECTIONS_FIELDS = first.(REPORT_SECTIONS)

function has_findings(report::ConversionReport)
    return any(!isempty(getfield(report, name)) for name in REPORT_SECTIONS_FIELDS)
end

function Base.show(io::IO, ::MIME"text/plain", report::ConversionReport)
    println(io, "ConversionReport over $(length(report.systems)) system(s)")
    for (name, title) in REPORT_SECTIONS
        counts = getfield(report, name)
        if isempty(counts)
            continue
        end
        println(io, "  $title")
        for (key, count) in sort(collect(counts); by = first)
            println(io, "    $(_finding_label(key))  x$count")
        end
    end
    if !has_findings(report)
        println(io, "  no findings")
    end
    return nothing
end

_finding_label(type_name::AbstractString) = type_name
_finding_label(key::Tuple{String, String}) = "$(key[1]).$(key[2])"
