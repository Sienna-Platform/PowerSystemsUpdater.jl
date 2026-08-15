"""
Aggregated findings from one or more conversions. Root skips (a type with no PSY6 model) are
counted separately from cascaded skips (a component dropped only because something it
references was dropped), so one missing type does not read as many independent failures.
"""
mutable struct ConversionReport
    unmapped_types::Dict{String, Int}
    cascaded_skips::Dict{String, Int}
    unmapped_fields::Dict{Tuple{String, String}, Int}
    systems::Vector{String}
end

function ConversionReport()
    return ConversionReport(
        Dict{String, Int}(),
        Dict{String, Int}(),
        Dict{Tuple{String, String}, Int}(),
        String[],
    )
end

function record_unmapped_type!(report::ConversionReport, type_name::AbstractString)
    key = String(type_name)
    report.unmapped_types[key] = get(report.unmapped_types, key, 0) + 1
    return nothing
end

function record_cascaded_skip!(report::ConversionReport, type_name::AbstractString)
    key = String(type_name)
    report.cascaded_skips[key] = get(report.cascaded_skips, key, 0) + 1
    return nothing
end

function record_unmapped_field!(
    report::ConversionReport,
    type_name::AbstractString,
    field::AbstractString,
)
    key = (String(type_name), String(field))
    report.unmapped_fields[key] = get(report.unmapped_fields, key, 0) + 1
    return nothing
end

function has_findings(report::ConversionReport)
    return !isempty(report.unmapped_types) ||
           !isempty(report.cascaded_skips) ||
           !isempty(report.unmapped_fields)
end

function Base.show(io::IO, ::MIME"text/plain", report::ConversionReport)
    println(io, "ConversionReport over $(length(report.systems)) system(s)")
    _show_section(io, "UNMAPPED TYPES (root skips)", report.unmapped_types)
    _show_section(io, "CASCADED SKIPS", report.cascaded_skips)
    if !isempty(report.unmapped_fields)
        println(io, "  UNMAPPED FIELDS")
        for (key, count) in sort(collect(report.unmapped_fields); by = first)
            println(io, "    $(key[1]).$(key[2])  x$count")
        end
    end
    if !has_findings(report)
        println(io, "  no findings")
    end
    return nothing
end

function _show_section(io::IO, title::AbstractString, counts::AbstractDict)
    if isempty(counts)
        return nothing
    end
    println(io, "  $title")
    for (name, count) in sort(collect(counts); by = first)
        println(io, "    $name  x$count")
    end
    return nothing
end
