# Step 4 of the PSY5 -> PSY6 comparison: diff each case's PSY5 and PSY6 snapshots, classify
# every difference against `known_differences.jl`, and write `comparison.md` and `diffs.json`
# per case plus `summary.md` for the whole run. Exits non-zero if any case has an unexpected
# difference or a failed step.
#
#   julia --project=scripts/psy5_psy6_compare/psy6_env \
#       scripts/psy5_psy6_compare/compare.jl <work_dir> <case.json>...
#
# Needs only JSON and HDF5; it never loads PowerSystems.

import HDF5
import JSON

include(joinpath(@__DIR__, "case_layout.jl"))
include(joinpath(@__DIR__, "known_differences.jl"))

const STEPS = ("psy5_snapshot", "convert", "psy6_snapshot")

"""
One difference between the snapshots. Kinds:

  - `missing_component` / `extra_component`: present on one side only
  - `missing_field` / `extra_field`: a field on one side of a matched component only
  - `moved_to_ext`: a PSY5 field with no PSY6 field, kept in the component's
    `ext["psy5_unmapped"]`
  - `value`: a field, time series or attribute value that differs
  - `unreadable`: the snapshot could read the value on one side only
  - `unreadable_both`: the snapshot could read the value on neither side
  - `missing_time_series` / `extra_time_series`
  - `missing_supplemental_attribute` / `extra_supplemental_attribute`
  - `system`: a system-level value that differs
"""
struct Difference
    kind::String
    psy5_type::String
    psy6_type::String
    name::String
    path::String
    psy5::Any
    psy6::Any
end

"""
The object a difference is recorded against.
"""
struct Site
    psy5_type::String
    psy6_type::String
    name::String
end

function glob_match(pattern::AbstractString, s::AbstractString)
    parts = split(pattern, '*')
    if length(parts) == 1
        return pattern == s
    end
    if !startswith(s, parts[1]) || !endswith(s, parts[end])
        return false
    end
    position = length(parts[1]) + 1
    for part in parts[2:(end - 1)]
        found = findnext(part, s, position)
        if isnothing(found)
            return false
        end
        position = last(found) + 1
    end
    return position <= length(s) - length(parts[end]) + 1
end

"""
`:expected` with its reason, `:informational`, or `:unexpected`.
"""
function classify(d::Difference)
    for e in EXPECTED
        if e.kind == d.kind && glob_match(e.psy5_type, d.psy5_type) &&
           glob_match(e.path, d.path)
            return (:expected, e.reason)
        end
    end
    if d.kind in INFORMATIONAL_KINDS
        return (:informational, "")
    end
    return (:unexpected, "")
end

is_error(x::AbstractDict) = haskey(x, "__error__")
is_error(x) = false

is_ref(x::AbstractDict) = haskey(x, "__ref__")
is_ref(x) = false

"""
Whether a PSY5 and a PSY6 component reference name the same component: same name, and the
PSY6 type is where `TYPE_MAPPINGS` says the PSY5 type went.
"""
refers_to_same(a::AbstractDict, b::AbstractDict) =
    a["name"] == b["name"] && glob_match(type_mapping(a["__ref__"]).psy6_type, b["__ref__"])

record!(out, site::Site, kind, path, a, b) =
    push!(out, Difference(kind, site.psy5_type, site.psy6_type, site.name, path, a, b))

join_path(path, key) = isempty(path) ? string(key) : "$path.$key"

function diff_values!(out, site::Site, path, a::AbstractDict, b::AbstractDict)
    if is_error(a) && is_error(b)
        # A limit of the snapshot, not a difference between versions; the two error texts
        # come from different package versions and are not compared.
        record!(out, site, "unreadable_both", path, a, b)
        return
    elseif is_error(a) || is_error(b)
        record!(out, site, "unreadable", path, a, b)
        return
    elseif is_ref(a) && is_ref(b)
        if !refers_to_same(a, b)
            record!(out, site, "value", path, a, b)
        end
        return
    end
    for key in sort!(collect(union(keys(a), keys(b))))
        diff_values!(
            out,
            site,
            join_path(path, key),
            get(a, key, nothing),
            get(b, key, nothing),
        )
    end
end

function diff_values!(out, site::Site, path, a::AbstractVector, b::AbstractVector)
    if all(is_ref, a) && all(is_ref, b)
        # Each side sorted its references by its own type labels; line them up by name.
        a = sort(a; by = r -> r["name"])
        b = sort(b; by = r -> r["name"])
    end
    if length(a) != length(b)
        record!(out, site, "value", path, a, b)
        return
    end
    for (i, (x, y)) in enumerate(zip(a, b))
        diff_values!(out, site, "$path[$i]", x, y)
    end
end

function diff_values!(out, site::Site, path, a::Real, b::Real)
    if !isapprox(a, b; rtol = RTOL, atol = ATOL)
        record!(out, site, "value", path, a, b)
    end
end

function diff_values!(out, site::Site, path, a::AbstractDict, b)
    record!(out, site, is_error(a) ? "unreadable" : "value", path, a, b)
end

function diff_values!(out, site::Site, path, a, b::AbstractDict)
    record!(out, site, is_error(b) ? "unreadable" : "value", path, a, b)
end

function diff_values!(out, site::Site, path, a, b)
    if a != b
        record!(out, site, "value", path, a, b)
    end
end

"""
`NESTED_ALIGNMENTS` applied to every struct inside `x`, innermost first.
"""
function align_nested(x::AbstractDict)
    aligned = Dict{String, Any}(k => align_nested(v) for (k, v) in x)
    for f in NESTED_ALIGNMENTS
        aligned = f(aligned)
    end
    return aligned
end
align_nested(x::AbstractVector) = Any[align_nested(v) for v in x]
align_nested(x) = x

"""
Apply `FIELD_RULES` for `psy5_type` to an already-renamed PSY6 record.
"""
function apply_field_rules(record::Dict{String, Any}, psy5_type::AbstractString)
    applied = Set{String}()
    for rule in FIELD_RULES
        field = rule.psy6_field
        if field in applied || !haskey(record, field) ||
           !glob_match(rule.psy5_type, psy5_type)
            continue
        end
        push!(applied, field)
        value = pop!(record, field)
        record[rule.psy5_field] = rule.to_psy5(value)
    end
    return record
end

"""
The PSY6 record reshaped to line up with the PSY5 one: nested structs named in
`mapping.flatten` are lifted to the top level, fields are renamed to their PSY5 names, then
`FIELD_RULES` and `NESTED_ALIGNMENTS` translate the forms PSY6 changed.
"""
function align(record::AbstractDict, mapping::TypeMapping, psy5_type::AbstractString)
    lifted = Dict{String, Any}()
    for (key, value) in record
        if key in mapping.flatten
            for (inner_key, inner_value) in value
                if inner_key != "__type__"
                    lifted[inner_key] = inner_value
                end
            end
        else
            lifted[key] = value
        end
    end
    renamed = Dict{String, Any}(get(mapping.renames, k, k) => v for (k, v) in lifted)
    return align_nested(apply_field_rules(renamed, psy5_type))
end

"""
The `ext` key under which the updater keeps PSY5 values that have no PSY6 field
(`UNMAPPED_EXT_KEY` in the updater's `convert.jl`).
"""
const MOVED_TO_EXT_KEY = "psy5_unmapped"

_moved(ext::AbstractDict) = get(ext, MOVED_TO_EXT_KEY, Dict{String, Any}())
_moved(::Any) = Dict{String, Any}()

"""
Split the PSY5 values the updater moved to `ext` off an aligned PSY6 record, so the record's
`ext` compares against PSY5's own `ext` and the moved values can account for missing fields.
"""
function split_moved(record::Dict{String, Any})
    moved = _moved(get(record, "ext", nothing))
    if !isempty(moved)
        record["ext"] = without(record["ext"], MOVED_TO_EXT_KEY)
    end
    return record, moved
end

function diff_records!(
    out,
    site::Site,
    a::AbstractDict,
    b::AbstractDict,
    moved::AbstractDict = Dict{String, Any}(),
)
    for key in sort!(collect(union(keys(a), keys(b))))
        if !haskey(b, key) && haskey(moved, key)
            # Kept as PSY5 stored it, so its value is not compared against the getter's.
            record!(out, site, "moved_to_ext", key, a[key], moved[key])
        elseif !haskey(b, key)
            record!(out, site, "missing_field", key, a[key], nothing)
        elseif !haskey(a, key)
            record!(out, site, "extra_field", key, nothing, b[key])
        else
            diff_values!(out, site, key, a[key], b[key])
        end
    end
end

"""
Every PSY6 entry, keyed by name, under a type label matching `pattern` (a `TypeMapping`'s
`psy6_type`), with the label it was found under. PSY6 can parameterize a type PSY5 did not
(`OnlineReserve{ReserveUp, NaturalUnit}`), so a mapping names its target by pattern.
"""
function psy6_matching(psy6::AbstractDict, pattern::AbstractString)
    found = Dict{String, Tuple{String, Any}}()
    for label in keys(psy6)
        if glob_match(pattern, label)
            for (name, entry) in psy6[label]
                found[name] = (label, entry)
            end
        end
    end
    return found
end

function diff_components!(out, psy5::AbstractDict, psy6::AbstractDict)
    matched = Set{Tuple{String, String}}()
    for psy5_type in sort!(collect(keys(psy5)))
        mapping = type_mapping(psy5_type)
        candidates = psy6_matching(psy6, mapping.psy6_type)
        for name in sort!(collect(keys(psy5[psy5_type])))
            if !haskey(candidates, name)
                record!(
                    out,
                    Site(psy5_type, mapping.psy6_type, name),
                    "missing_component",
                    "",
                    name,
                    nothing,
                )
                continue
            end
            psy6_type, record = candidates[name]
            push!(matched, (psy6_type, name))
            aligned, moved = split_moved(align(record, mapping, psy5_type))
            diff_records!(
                out,
                Site(psy5_type, psy6_type, name),
                psy5[psy5_type][name],
                aligned,
                moved,
            )
        end
    end
    for psy6_type in sort!(collect(keys(psy6))),
        name in sort!(collect(keys(psy6[psy6_type])))

        if (psy6_type, name) ∉ matched
            record!(out, Site("", psy6_type, name), "extra_component", "", nothing, name)
        end
    end
end

time_series_key(r::AbstractDict) =
    (r["type"], r["name"], JSON.json(get(r, "resolution", nothing)))
time_series_label(key) = "$(key[1]) \"$(key[2])\" @ $(key[3])"

keyed(records::AbstractVector, key) = Dict(key(r) => r for r in records)
# An `attempt` error record in place of the list: nothing to key, compared whole instead.
keyed(records::AbstractDict, key) = Dict(("__error__",) => records)

"""
Match two lists of records by `key`, diffing the matched pairs with `diff_pair` and reporting
the rest.
"""
function diff_keyed!(
    out,
    site::Site,
    psy5_records,
    psy6_records,
    key,
    label,
    noun;
    diff_pair = diff_values!,
)
    a = keyed(psy5_records, key)
    b = keyed(psy6_records, key)
    for k in sort!(collect(union(keys(a), keys(b))); by = string)
        if !haskey(b, k)
            record!(out, site, "missing_$noun", label(k), a[k], nothing)
        elseif !haskey(a, k)
            record!(out, site, "extra_$noun", label(k), nothing, b[k])
        else
            diff_pair(out, site, label(k), a[k], b[k])
        end
    end
end

"""
Each side's time series values file, open for reading.
"""
struct ValueFiles
    psy5::HDF5.File
    psy6::HDF5.File
end

without(x::AbstractDict, key) = Dict{String, Any}(k => v for (k, v) in x if k != key)
without(x, key) = x

has_dataset(x::AbstractDict) = haskey(x, "dataset")
has_dataset(x) = false

elements_match(x::Real, y::Real) =
    isapprox(x, y; rtol = RTOL, atol = ATOL) || (isnan(x) && isnan(y))
elements_match(x, y) = x == y

element_location(i::Integer, window_starts) = "[$i]"
element_location(i::CartesianIndex{2}, window_starts::AbstractVector) =
    "window $(window_starts[i[2]]) [$(i[1])]"
element_location(i::CartesianIndex, window_starts) = string(Tuple(i))

json_safe(x::AbstractFloat) = isfinite(x) ? x : string(x)
json_safe(x) = x

"""
Compare two series' values element by element, recording one difference that gives the
number of mismatched elements and the first of them.
"""
function diff_arrays!(
    out,
    site::Site,
    path,
    a::AbstractArray,
    b::AbstractArray,
    window_starts,
)
    mismatched = findall(.!elements_match.(a, b))
    if isempty(mismatched)
        return
    end
    i = first(mismatched)
    at = element_location(i, window_starts)
    record!(
        out,
        site,
        "value",
        path,
        (value = json_safe(a[i]), at = at, mismatched_elements = length(mismatched)),
        (value = json_safe(b[i]), at = at, mismatched_elements = length(mismatched)),
    )
end

"""
A matched pair of time series: metadata as values, then the arrays themselves, read from each
side's values file. The dataset paths are per file and never compared.
"""
function diff_series!(
    out,
    site::Site,
    path,
    a::AbstractDict,
    b::AbstractDict,
    files::ValueFiles,
)
    diff_values!(out, site, path, without(a, "values"), without(b, "values"))
    values_a = get(a, "values", nothing)
    values_b = get(b, "values", nothing)
    values_path = "$path.values"
    diff_values!(
        out,
        site,
        values_path,
        without(values_a, "dataset"),
        without(values_b, "dataset"),
    )
    if has_dataset(values_a) && has_dataset(values_b) &&
       values_a["shape"] == values_b["shape"]
        diff_arrays!(
            out,
            site,
            values_path,
            read(files.psy5[values_a["dataset"]]),
            read(files.psy6[values_b["dataset"]]),
            values_a["window_starts"],
        )
    end
end

# An `attempt` error record on either side: nothing to read, compared as values.
diff_series!(out, site::Site, path, a, b, ::ValueFiles) =
    diff_values!(out, site, path, a, b)

series_differ(files::ValueFiles) =
    (out, site, path, a, b) -> diff_series!(out, site, path, a, b, files)

"""
A matched pair of supplemental attributes: fields as values, then their time series as series.
"""
function diff_attribute!(
    out,
    site::Site,
    path,
    a::AbstractDict,
    b::AbstractDict,
    files::ValueFiles,
)
    diff_values!(out, site, path, without(a, "time_series"), without(b, "time_series"))
    diff_keyed!(
        out,
        Site(site.psy5_type, site.psy6_type, path),
        get(a, "time_series", Any[]),
        get(b, "time_series", Any[]),
        time_series_key,
        time_series_label,
        "time_series";
        diff_pair = series_differ(files),
    )
end

diff_attribute!(out, site::Site, path, a, b, ::ValueFiles) =
    diff_values!(out, site, path, a, b)

function diff_time_series!(out, psy5::AbstractDict, psy6::AbstractDict, files::ValueFiles)
    seen = Set{Tuple{String, String}}()
    for psy5_type in sort!(collect(keys(psy5)))
        mapping = type_mapping(psy5_type)
        candidates = psy6_matching(psy6, mapping.psy6_type)
        for name in sort!(collect(keys(psy5[psy5_type])))
            psy6_type, records = get(candidates, name, (mapping.psy6_type, Any[]))
            push!(seen, (psy6_type, name))
            diff_keyed!(
                out,
                Site(psy5_type, psy6_type, name),
                psy5[psy5_type][name],
                records,
                time_series_key,
                time_series_label,
                "time_series";
                diff_pair = series_differ(files),
            )
        end
    end
    for psy6_type in sort!(collect(keys(psy6))),
        name in sort!(collect(keys(psy6[psy6_type])))

        if (psy6_type, name) ∉ seen
            diff_keyed!(
                out,
                Site("", psy6_type, name),
                Any[],
                psy6[psy6_type][name],
                time_series_key,
                time_series_label,
                "time_series";
                diff_pair = series_differ(files),
            )
        end
    end
end

attribute_key(r::AbstractDict) = (r["__type__"], JSON.json(r["components"]))
attribute_label(key) = "$(key[1]) on $(key[2])"

function diff_system!(out, psy5::AbstractDict, psy6::AbstractDict)
    found = Difference[]
    for key in sort!(collect(union(keys(psy5), keys(psy6))))
        if key != "psy_version"
            diff_values!(
                found,
                Site("System", "System", ""),
                key,
                get(psy5, key, nothing),
                get(psy6, key, nothing),
            )
        end
    end
    # Their own kind, so system-level mismatches group apart from component values.
    for d in found
        push!(
            out,
            Difference("system", d.psy5_type, d.psy6_type, d.name, d.path, d.psy5, d.psy6),
        )
    end
end

function compare_snapshots(psy5::AbstractDict, psy6::AbstractDict, files::ValueFiles)
    out = Difference[]
    diff_system!(out, psy5["system"], psy6["system"])
    diff_components!(out, psy5["components"], psy6["components"])
    diff_time_series!(out, psy5["time_series"], psy6["time_series"], files)
    diff_keyed!(
        out,
        Site("SupplementalAttribute", "SupplementalAttribute", ""),
        psy5["supplemental_attributes"],
        psy6["supplemental_attributes"],
        attribute_key,
        attribute_label,
        "supplemental_attribute";
        diff_pair = (out, site, path, a, b) ->
            diff_attribute!(out, site, path, a, b, files),
    )
    return out
end

# Report

"""
Group key for the report: indices are folded so `points[1]` and `points[7]` group together.
"""
group_path(path::AbstractString) = replace(path, r"\[\d+\]" => "[*]")

function brief(x; limit = 70)
    s = isnothing(x) ? "—" : JSON.json(x)
    return length(s) > limit ? first(s, limit) * "…" : s
end

md_cell(x) = replace(string(x), "|" => "\\|", "\n" => " ")

struct CaseResult
    case::String
    failed_step::Union{Nothing, String}
    unexpected::Int
    expected::Int
    informational::Int
    # The updater's report counts (`conversion_report.json`), or `nothing` if it never wrote
    # one because conversion failed or did not run.
    conversion::Union{Nothing, AbstractDict}
end

CaseResult(case, failed_step, conversion) =
    CaseResult(case, failed_step, 0, 0, 0, conversion)

function read_conversion_counts(dir)
    path = joinpath(dir, CONVERSION_REPORT_JSON)
    return isfile(path) ? JSON.parsefile(path) : nothing
end

"""
Components the updater left out: those of a type with no PSY6 counterpart, plus those skipped
because they reference one.
"""
skipped_components(c::AbstractDict) =
    sum(values(c["unmapped_types"]); init = 0) + sum(values(c["cascaded_skips"]); init = 0)
skipped_components(::Nothing) = "—"

"""
Distinct `Type.field` pairs the updater found no PSY6 home for.
"""
dropped_fields(c::AbstractDict) = length(c["unmapped_fields"])
dropped_fields(::Nothing) = "—"

function write_conversion_section(io, c::AbstractDict)
    println(io, "## Conversion report\n")
    println(
        io,
        "What the updater itself recorded as not carried across (`$CONVERSION_REPORT`).\n",
    )
    sections = (
        ("Unmapped types (components skipped)", c["unmapped_types"]),
        ("Cascaded skips (components referencing a skipped one)", c["cascaded_skips"]),
        ("Unmapped fields (values dropped)", c["unmapped_fields"]),
    )
    if all(isempty(counts) for (_, counts) in sections)
        println(io, "No findings.\n")
        return
    end
    for (title, counts) in sections
        if isempty(counts)
            continue
        end
        println(io, "**$title**\n")
        println(io, "| | count |")
        println(io, "|:--|--:|")
        for key in sort!(collect(keys(counts)))
            println(io, "| ", md_cell(key), " | ", counts[key], " |")
        end
        println(io)
    end
end

write_conversion_section(io, ::Nothing) =
    println(io, "## Conversion report\n\nNo `$CONVERSION_REPORT_JSON` was written.\n")

passed(r::CaseResult) = isnothing(r.failed_step) && r.unexpected == 0

function grouped(diffs)
    groups = Dict{Tuple{String, String, String, String}, Vector{Difference}}()
    for d in diffs
        push!(
            get!(
                Vector{Difference},
                groups,
                (d.kind, d.psy5_type, d.psy6_type, group_path(d.path)),
            ),
            d,
        )
    end
    return sort!(collect(groups); by = first)
end

function write_group_table(io, diffs; reasons = nothing)
    if isempty(diffs)
        println(io, "None.\n")
        return
    end
    header = isnothing(reasons) ? "example (name: PSY5 → PSY6)" : "reason"
    println(io, "| kind | PSY5 type | PSY6 type | path | count | $header |")
    println(io, "|:--|:--|:--|:--|--:|:--|")
    for ((kind, t5, t6, path), group) in grouped(diffs)
        d = first(group)
        detail = if isnothing(reasons)
            "$(d.name): $(brief(d.psy5)) → $(brief(d.psy6))"
        else
            reasons[d]
        end
        println(
            io,
            "| ", join(md_cell.((kind, t5, t6, path, length(group), detail)), " | "), " |",
        )
    end
    println(io)
end

function write_case_report(dir, case, diffs, psy5_version, psy6_version, conversion)
    classified = [(d, classify(d)...) for d in diffs]
    unexpected = [d for (d, c, _) in classified if c == :unexpected]
    expected = [d for (d, c, _) in classified if c == :expected]
    informational = [d for (d, c, _) in classified if c == :informational]
    reasons =
        IdDict{Difference, String}(d => r for (d, c, r) in classified if c == :expected)

    open(joinpath(dir, COMPARISON_REPORT), "w") do io
        println(io, "# $(case_name(case)): PSY5 → PSY6\n")
        println(io, "Source: `$case`  ")
        println(io, "PowerSystems $psy5_version → PowerSystems $psy6_version\n")
        verdict = isempty(unexpected) ? "PASS" : "FAIL"
        println(
            io,
            "**$verdict** — $(length(unexpected)) unexpected, $(length(expected)) expected, " *
            "$(length(informational)) informational difference(s).\n",
        )
        println(io, "## Unexpected\n")
        write_group_table(io, unexpected)
        println(io, "## Expected (accepted breaking changes)\n")
        write_group_table(io, expected; reasons = reasons)
        println(
            io,
            "## Informational (new in PSY6, moved to ext, or unreadable on both sides)\n",
        )
        write_group_table(io, informational)
        write_conversion_section(io, conversion)
    end

    open(joinpath(dir, COMPARISON_DIFFS), "w") do io
        records = [
            Dict(
                "classification" => string(c),
                "reason" => r,
                "kind" => d.kind,
                "psy5_type" => d.psy5_type,
                "psy6_type" => d.psy6_type,
                "name" => d.name,
                "path" => d.path,
                "psy5" => d.psy5,
                "psy6" => d.psy6,
            ) for (d, c, r) in classified
        ]
        JSON.json(io, records; pretty = true)
    end
    return CaseResult(
        case_name(case),
        nothing,
        length(unexpected),
        length(expected),
        length(informational),
        conversion,
    )
end

function compare_case(work_dir, case)
    dir = case_dir(work_dir, case)
    mkpath(dir)
    clear_step!(dir, "compare")
    conversion = read_conversion_counts(dir)
    for step in STEPS
        if isfile(joinpath(dir, error_file(step)))
            return CaseResult(case_name(case), step, conversion)
        end
    end
    for file in (PSY5_SNAPSHOT, PSY5_VALUES, PSY6_SNAPSHOT, PSY6_VALUES)
        if !isfile(joinpath(dir, file))
            return CaseResult(case_name(case), "missing $file", conversion)
        end
    end
    psy5 = JSON.parsefile(joinpath(dir, PSY5_SNAPSHOT))
    psy6 = JSON.parsefile(joinpath(dir, PSY6_SNAPSHOT))
    diffs = HDF5.h5open(joinpath(dir, PSY5_VALUES), "r") do psy5_values
        HDF5.h5open(joinpath(dir, PSY6_VALUES), "r") do psy6_values
            compare_snapshots(psy5, psy6, ValueFiles(psy5_values, psy6_values))
        end
    end
    return write_case_report(
        dir,
        case,
        diffs,
        psy5["system"]["psy_version"],
        psy6["system"]["psy_version"],
        conversion,
    )
end

"""
Where to look for a case: its comparison, else the error file of the step that failed, else
(an output was missing without an error, e.g. a step was skipped) the case directory.
"""
report_path(work_dir, r::CaseResult) =
    if isnothing(r.failed_step)
        joinpath(r.case, COMPARISON_REPORT)
    else
        _failure_path(work_dir, r.case, error_file(r.failed_step))
    end

_failure_path(work_dir, case, file) =
    isfile(joinpath(work_dir, case, file)) ? joinpath(case, file) : case

function write_summary(io, work_dir, results)
    println(
        io,
        "| case | result | unexpected | expected | informational | " *
        "skipped components | dropped fields | report |",
    )
    println(io, "|:--|:--|--:|--:|--:|--:|--:|:--|")
    for r in results
        status = if !isnothing(r.failed_step)
            "ERROR ($(r.failed_step))"
        else
            passed(r) ? "PASS" : "FAIL"
        end
        report = report_path(work_dir, r)
        println(
            io,
            "| ",
            join(
                md_cell.((
                    r.case,
                    status,
                    r.unexpected,
                    r.expected,
                    r.informational,
                    skipped_components(r.conversion),
                    dropped_fields(r.conversion),
                    report,
                )),
                " | ",
            ),
            " |",
        )
    end
    n_pass = count(passed, results)
    println(
        io,
        "\n$n_pass of $(length(results)) case(s) passed. Results under `$work_dir`.",
    )
end

function main(args)
    work_dir, cases = parse_step_args(args)
    results = CaseResult[]
    for case in cases
        result = try
            compare_case(work_dir, case)
        catch e
            dir = case_dir(work_dir, case)
            mkpath(dir)
            open(joinpath(dir, error_file("compare")), "w") do io
                showerror(io, e, catch_backtrace())
            end
            CaseResult(case_name(case), "compare", read_conversion_counts(dir))
        end
        push!(results, result)
    end
    open(joinpath(work_dir, SUMMARY), "w") do io
        write_summary(io, work_dir, results)
    end
    write_summary(stdout, work_dir, results)
    return all(passed, results) ? 0 : 1
end

exit(main(ARGS))
