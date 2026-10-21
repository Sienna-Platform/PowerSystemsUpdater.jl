"""
Aggregated findings from one or more conversions. Root skips (a type with no PSY6 model) are
counted separately from cascaded skips (a component dropped only because something it
references was dropped), so one missing type does not read as many independent failures.
"""
Base.@kwdef mutable struct ConversionReport
    unmapped_types::Dict{String, Int} = Dict{String, Int}()
    cascaded_skips::Dict{String, Int} = Dict{String, Int}()
    unmapped_fields::Dict{Tuple{String, String}, Int} =
        Dict{Tuple{String, String}, Int}()
    # Fields whose PSY6 unit is physical and whose PSY5 value could not be converted into it
    # (`convert_units` in translate/units.jl): written as PSY5 stored them if required, else
    # kept in ext. Each is a value that may be in the wrong unit.
    unverified_units::Dict{Tuple{String, String}, Int} =
        Dict{Tuple{String, String}, Int}()
    # Static devices kept without their dynamic model, by static type. The dynamic models
    # themselves are counted under `unmapped_types`.
    dropped_dynamic_models::Dict{String, Int} = Dict{String, Int}()
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

function has_findings(report::ConversionReport)
    return !isempty(report.unmapped_types) ||
           !isempty(report.cascaded_skips) ||
           !isempty(report.unmapped_fields) ||
           !isempty(report.unverified_units) ||
           !isempty(report.dropped_dynamic_models)
end

function Base.show(io::IO, ::MIME"text/plain", report::ConversionReport)
    println(io, "ConversionReport over $(length(report.systems)) system(s)")
    _show_section(io, "UNMAPPED TYPES (root skips)", report.unmapped_types)
    _show_section(io, "CASCADED SKIPS", report.cascaded_skips)
    _show_section(
        io,
        "UNMAPPED FIELDS (values kept in the component's ext[\"psy5_unmapped\"], " *
        "except on a skipped component or one with no ext)",
        report.unmapped_fields;
        label = key -> "$(key[1]).$(key[2])",
    )
    _show_section(
        io,
        "UNVERIFIED UNITS (PSY5 value could not be converted to the PSY6 unit: written as " *
        "stored if required, else kept in ext[\"psy5_unmapped\"])",
        report.unverified_units;
        label = key -> "$(key[1]).$(key[2])",
    )
    _show_section(
        io,
        "DYNAMIC MODELS DROPPED (static device kept; its dynamic model has no PSY6 schema " *
        "home and is lost)",
        report.dropped_dynamic_models,
    )
    if !has_findings(report)
        println(io, "  no findings")
    end
    return nothing
end

function _show_section(
    io::IO,
    title::AbstractString,
    counts::AbstractDict;
    label = string,
)
    if isempty(counts)
        return nothing
    end
    println(io, "  $title")
    for (key, count) in sort(collect(counts); by = first)
        println(io, "    $(label(key))  x$count")
    end
    return nothing
end
