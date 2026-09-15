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

function has_findings(report::ConversionReport)
    return !isempty(report.unmapped_types) ||
           !isempty(report.cascaded_skips) ||
           !isempty(report.unmapped_fields)
end

function Base.show(io::IO, ::MIME"text/plain", report::ConversionReport)
    println(io, "ConversionReport over $(length(report.systems)) system(s)")
    _show_section(io, "UNMAPPED TYPES (root skips)", report.unmapped_types)
    _show_section(io, "CASCADED SKIPS", report.cascaded_skips)
    _show_section(
        io, "UNMAPPED FIELDS", report.unmapped_fields;
        label = key -> "$(key[1]).$(key[2])",
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
