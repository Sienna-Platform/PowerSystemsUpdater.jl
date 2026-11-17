# Step 4 of the PSY5 -> PSY6 comparison: diff each case's snapshots, classify every difference
# against `known_differences.jl`, and write `comparison.md` and `diffs.json` per case plus
# `summary.md`. Exits non-zero if any case has an unexpected difference or a failed step.
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
One difference between the snapshots. `kind` is one of `missing_`/`extra_` + `component`,
`field`, `time_series` or `supplemental_attribute`; `value` (a value differs); `unreadable` /
`unreadable_both` (one / neither side could be read); `moved_to_ext` (a PSY5 field kept in
`ext["psy5_unmapped"]`); `system` (a system-level value differs).
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
`(:expected, reason)`, `(:informational, "")` or `(:unexpected, "")`.
"""
function classify(d::Difference)
    for e in EXPECTED
        if e.kind == d.kind && glob_match(e.psy5_type, d.psy5_type) &&
           glob_match(e.path, d.path) && e.when(d.psy5, d.psy6)
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
Whether the references name the same component, the PSY6 type being where `TYPE_MAPPINGS`
sent the PSY5 type.
"""
refers_to_same(a::AbstractDict, b::AbstractDict) =
    a["name"] == b["name"] && glob_match(type_mapping(a["__ref__"]).psy6_type, b["__ref__"])

record!(out, site::Site, kind, path, a, b) =
    push!(out, Difference(kind, site.psy5_type, site.psy6_type, site.name, path, a, b))

join_path(path, key) = isempty(path) ? string(key) : "$path.$key"

function diff_values!(out, site::Site, path, a::AbstractDict, b::AbstractDict)
    if is_error(a) && is_error(b)
        # A limit of the snapshot, not a difference between versions.
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
        # Each side sorted its references by its own type labels.
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

mismatch_kind(x) = is_error(x) ? "unreadable" : "value"

diff_values!(out, site::Site, path, a::AbstractDict, b) =
    record!(out, site, mismatch_kind(a), path, a, b)

diff_values!(out, site::Site, path, a, b::AbstractDict) =
    record!(out, site, mismatch_kind(b), path, a, b)

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
function apply_field_rules(
    record::Dict{String, Any},
    psy5_type::AbstractString,
    system::AbstractDict,
)
    applied = Set{String}()
    for rule in FIELD_RULES
        field = rule.psy6_field
        if field in applied || !haskey(record, field) ||
           !glob_match(rule.psy5_type, psy5_type)
            continue
        end
        push!(applied, field)
        value = rule.to_psy5(pop!(record, field), system, record)
        # Several PSY6 fields fold into one PSY5 field (a setpoint per mode); an unset one
        # must not overwrite the one the mode selected.
        if !isnothing(value) || !haskey(record, rule.psy5_field)
            record[rule.psy5_field] = value
        end
    end
    return record
end

"""
Lift one winding's circuit onto `lifted`, each field under its PSY5 per-winding name
(`WINDING_FIELDS`), or `<field>@<circuit_key>` when PSY5 has none. A value that is not a
circuit is kept under its own key.
"""
function lift_winding!(lifted, circuit_key, winding, circuit::AbstractDict)
    for (inner_key, inner_value) in circuit
        inner_key == "__type__" && continue
        template = get(WINDING_FIELDS, inner_key, nothing)
        name =
            isnothing(template) ? "$(inner_key)@$(circuit_key)" :
            replace(template, "{w}" => winding)
        lifted[name] = inner_value
    end
    return lifted
end
lift_winding!(lifted, circuit_key, _, value) = (lifted[circuit_key] = value; lifted)

"""
The PSY6 record reshaped to line up with the PSY5 one: `mapping.flatten` structs lifted,
fields renamed, then `FIELD_RULES` and `NESTED_ALIGNMENTS` applied.
"""
function align(
    record::AbstractDict,
    mapping::TypeMapping,
    psy5_type::AbstractString,
    system::AbstractDict,
)
    lifted = Dict{String, Any}()
    for (key, value) in record
        if haskey(mapping.windings, key)
            lift_winding!(lifted, key, mapping.windings[key], value)
        elseif key in mapping.flatten
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
    reshaped = mapping.reshape(renamed)
    return align_nested(apply_field_rules(reshaped, psy5_type, system))
end

# The `ext` key the updater keeps PSY5 values with no PSY6 field under (`UNMAPPED_EXT_KEY`).
const MOVED_TO_EXT_KEY = "psy5_unmapped"

_moved(ext::AbstractDict) = get(ext, MOVED_TO_EXT_KEY, Dict{String, Any}())
_moved(::Any) = Dict{String, Any}()

"""
Split the values the updater moved to `ext` off an aligned PSY6 record, so its `ext` compares
against PSY5's and the moved values can account for missing fields.
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
        if haskey(moved, key) && (!haskey(b, key) || isnothing(b[key]))
            # Kept as PSY5 stored it, not through a getter, so not compared. PSY6 may have the
            # field but leave it unset.
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
Every PSY6 entry under a type label matching `pattern`, by name, with the label it was found
under.
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

function diff_components!(out, psy5::AbstractDict, psy6::AbstractDict, system::AbstractDict)
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
            aligned, moved = split_moved(align(record, mapping, psy5_type, system))
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
# An `attempt` error record in place of the list: compared whole.
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
    keyer = keyed,
)
    a = keyer(psy5_records, key)
    b = keyer(psy6_records, key)
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
Compare two series element by element, recording one difference with the number of
mismatched elements and the first of them.
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
A matched pair of time series: metadata, then the arrays read from each values file.
"""
function diff_series!(
    out,
    site::Site,
    path,
    a::AbstractDict,
    b::AbstractDict,
    files::ValueFiles,
)
    diff_values!(
        out,
        site,
        path,
        without(without(a, "values"), "natural_scale"),
        without(without(b, "values"), "natural_scale"),
    )
    values_a = get(a, "values", nothing)
    values_b = get(b, "values", nothing)
    scale_a = get(a, "natural_scale", 1.0)
    scale_b = get(b, "natural_scale", 1.0)
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
        diff_scaled_arrays!(
            out,
            site,
            values_path,
            read(files.psy5[values_a["dataset"]]),
            read(files.psy6[values_b["dataset"]]),
            scale_a,
            scale_b,
            values_a["window_starts"],
        )
    end
end

"""
Compare two series in natural units (stored values times `natural_scale`). A scale that could
not be computed is recorded as unreadable and the raw values are compared.
"""
function diff_scaled_arrays!(out, site::Site, path, a, b, scale_a::Real, scale_b::Real, starts)
    return diff_arrays!(out, site, path, _scaled(a, scale_a), _scaled(b, scale_b), starts)
end

function diff_scaled_arrays!(out, site::Site, path, a, b, scale_a, scale_b, starts)
    diff_values!(out, site, "$path.natural_scale", scale_a, scale_b)
    return diff_arrays!(out, site, path, a, b, starts)
end

_scaled(values::AbstractArray{<:Real}, scale::Real) = values .* scale
_scaled(values::AbstractArray, ::Real) = values

# An `attempt` error record on either side.
diff_series!(out, site::Site, path, a, b, ::ValueFiles) =
    diff_values!(out, site, path, a, b)

series_differ(files::ValueFiles) =
    (out, site, path, a, b) -> diff_series!(out, site, path, a, b, files)

"""
A matched pair of supplemental attributes: fields, then their time series.
"""
function diff_attribute!(
    out,
    site::Site,
    path,
    a::AbstractDict,
    b::AbstractDict,
    files::ValueFiles,
    system::AbstractDict,
)
    aligned =
        apply_field_rules(Dict{String, Any}(b), string(get(a, "__type__", "")), system)
    diff_values!(
        out,
        site,
        path,
        without(a, "time_series"),
        without(aligned, "time_series"),
    )
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

diff_attribute!(out, site::Site, path, a, b, ::ValueFiles, ::AbstractDict) =
    diff_values!(out, site, path, a, b)

"""
A PSY5 component reference in PSY6 terms; unchanged when nothing matches, so the owner still
reads as missing.
"""
function psy6_ref(ref::AbstractDict, psy6_components::AbstractDict)
    candidates = psy6_matching(psy6_components, type_mapping(ref["__ref__"]).psy6_type)
    match = get(candidates, ref["name"], nothing)
    if isnothing(match)
        return ref
    end
    return Dict{String, Any}("__ref__" => first(match), "name" => ref["name"])
end

_psy6_owners(owners::AbstractVector, psy6_components::AbstractDict) = sort!(
    Any[psy6_ref(r, psy6_components) for r in owners];
    by = r -> (r["__ref__"], r["name"]),
)
_psy6_owners(owners, ::AbstractDict) = owners

"""
PSY5 supplemental attributes with their owners named in PSY6 terms, so they match by owner
(`attribute_key`) even where the owner's type was renamed.
"""
function with_psy6_owners(records::AbstractVector, psy6_components::AbstractDict)
    return Any[
        merge(
            Dict{String, Any}(r),
            Dict{String, Any}(
                "components" => _psy6_owners(get(r, "components", Any[]), psy6_components),
            ),
        ) for r in records
    ]
end
with_psy6_owners(records, ::AbstractDict) = records

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
attribute_label(key) = "$(key[1]) on $(key[2])" * (key[3] > 1 ? " #$(key[3])" : "")

# Tells apart attributes of one type on one owner (a table per transformer winding).
attribute_order(r::AbstractDict) =
    (string(get(r, "transformer_winding", "")), string(get(r, "table_number", "")))

"""
Attributes keyed by type, owners and occurrence (in `attribute_order`), so several of one type
on one owner pair up one to one.
"""
function keyed_attributes(records::AbstractVector, key)
    groups = Dict{Any, Vector{Any}}()
    for r in records
        push!(get!(Vector{Any}, groups, key(r)), r)
    end
    out = Dict{Any, Any}()
    for (k, group) in groups
        for (i, r) in enumerate(sort(group; by = attribute_order))
            out[(k..., i)] = r
        end
    end
    return out
end
keyed_attributes(records::AbstractDict, key) = Dict(("__error__", "", 1) => records)

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
    index_psy6_buses!(psy6["components"], psy6["system"])
    diff_components!(out, psy5["components"], psy6["components"], psy6["system"])
    diff_time_series!(out, psy5["time_series"], psy6["time_series"], files)
    diff_keyed!(
        out,
        Site("SupplementalAttribute", "SupplementalAttribute", ""),
        with_psy6_owners(psy5["supplemental_attributes"], psy6["components"]),
        psy6["supplemental_attributes"],
        attribute_key,
        attribute_label,
        "supplemental_attribute";
        keyer = keyed_attributes,
        diff_pair = (out, site, path, a, b) ->
            diff_attribute!(out, site, path, a, b, files, psy6["system"]),
    )
    return out
end

# Reporting

group_path(path::AbstractString) = replace(path, r"\[\d+\]" => "[*]")

function brief(x; limit = 60)
    s = isnothing(x) ? "—" : JSON.json(x)
    if length(s) > limit
        return first(s, limit) * "…"
    end
    return s
end

md_cell(x) = replace(string(x), "|" => "\\|", "\n" => " ")

function md_table(io, header, rows)
    println(io, "| ", join(header, " | "), " |")
    println(io, "|", repeat(":--|", length(header)))
    for row in rows
        println(io, "| ", join(md_cell.(row), " | "), " |")
    end
    println(io)
end

"""
The type a difference is about: the PSY5 type, with the PSY6 type after an arrow if it differs.
"""
function site_type(d::Difference)
    if isempty(d.psy5_type)
        return d.psy6_type
    elseif isempty(d.psy6_type) || d.psy6_type == d.psy5_type
        return d.psy5_type
    end
    return "$(d.psy5_type) → $(d.psy6_type)"
end

location(d::Difference) = isempty(d.path) ? site_type(d) : "$(site_type(d)).$(group_path(d.path))"

example(d::Difference) = "$(d.name): $(brief(d.psy5)) → $(brief(d.psy6))"

"""
`diffs` grouped by `key`, largest group first.
"""
function group_by(key, items)
    groups = Dict{Any, Vector{eltype(items)}}()
    for item in items
        push!(get!(Vector{eltype(items)}, groups, key(item)), item)
    end
    return sort!(collect(groups); by = g -> (-length(last(g)), string(first(g))))
end

"""
The first `n` distinct `items`, then how many more there are.
"""
function listed(items, n)
    distinct = unique(items)
    shown = join(first(distinct, n), ", ")
    if length(distinct) > n
        shown *= " (+$(length(distinct) - n) more)"
    end
    return shown
end

function write_unexpected(io, diffs)
    rows = [
        (kind, type, path, length(group), example(first(group))) for
        ((kind, type, path), group) in
        group_by(d -> (d.kind, site_type(d), group_path(d.path)), diffs)
    ]
    md_table(io, ("kind", "type", "path", "count", "example (name: PSY5 → PSY6)"), rows)
end

function write_expected(io, classified)
    rows = [
        (
            length(group),
            first(group)[1].kind,
            listed([location(d) for (d, _) in group], 3),
            reason,
        ) for (reason, group) in group_by(((_, reason),) -> reason, classified)
    ]
    md_table(io, ("count", "kind", "where", "reason"), rows)
end

function write_informational(io, diffs)
    rows = [
        (
            length(group),
            kind,
            type,
            listed([group_path(d.path) for d in group], 4),
            example(first(group)),
        ) for ((kind, type), group) in group_by(d -> (d.kind, site_type(d)), diffs)
    ]
    md_table(io, ("count", "kind", "type", "fields", "example"), rows)
end

const CONVERSION_FINDINGS = (
    "unmapped_types" => "Unmapped types (components skipped)",
    "cascaded_skips" => "Cascaded skips (reference a skipped component)",
    "unmapped_fields" => "Unmapped fields (kept in ext)",
    "unverified_units" => "Unverified units",
    "dropped_dynamic_models" => "Dynamic models dropped",
    "dropped_invalid_values" => "Invalid values dropped",
    "approximate_mappings" => "Approximate mappings",
    "schema_defaults" => "Schema defaults written",
    "psy5_defaults" => "PSY5 defaults filled",
)

function write_conversion(io, conversion::AbstractDict)
    rows = []
    for (key, title) in CONVERSION_FINDINGS
        counts = get(conversion, key, Dict{String, Any}())
        if !isempty(counts)
            top = sort!(collect(counts); by = p -> (-last(p), first(p)))
            most = listed(["$k (×$n)" for (k, n) in top], 3)
            push!(rows, (title, length(counts), sum(values(counts)), most))
        end
    end
    println(io, "## Conversion report\n")
    if isempty(rows)
        println(io, "No findings.\n")
    else
        md_table(io, ("finding", "entries", "total", "most common"), rows)
    end
end

function write_conversion(io, ::Nothing)
    println(io, "## Conversion report\n\nNone written.\n")
end

function read_conversion(dir)
    path = joinpath(dir, CONVERSION_REPORT_JSON)
    return isfile(path) ? JSON.parsefile(path) : nothing
end

struct CaseResult
    case::String
    failed_step::Union{Nothing, String}
    unexpected::Int
    expected::Int
    informational::Int
    reason::String
end

CaseResult(case, failed_step, reason) = CaseResult(case, failed_step, 0, 0, 0, reason)

passed(r::CaseResult) = isnothing(r.failed_step) && r.unexpected == 0

function status(r::CaseResult)
    if !isnothing(r.failed_step)
        return "ERROR ($(r.failed_step))"
    end
    if passed(r)
        return "PASS"
    end
    return "FAIL"
end

const ERROR_KINDS = Dict(
    "psy5_snapshot" => "load error",
    "psy6_snapshot" => "load error",
    "convert" => "convert error",
)

function outcome(r::CaseResult)
    if !isnothing(r.failed_step)
        return get(ERROR_KINDS, r.failed_step, "compare error")
    end
    if passed(r)
        return "pass"
    end
    return "differ"
end

function write_case_report(dir, case, diffs, psy5_version, psy6_version, conversion)
    classified = [(d, classify(d)...) for d in diffs]
    of(class) = [(d, reason) for (d, c, reason) in classified if c == class]
    unexpected = first.(of(:unexpected))
    expected = of(:expected)
    informational = first.(of(:informational))

    open(joinpath(dir, COMPARISON_REPORT), "w") do io
        println(io, "# $(case_name(case)): $(isempty(unexpected) ? "PASS" : "FAIL")\n")
        println(io, "`$case`  ")
        println(io, "PowerSystems $psy5_version → $psy6_version\n")
        println(
            io,
            "**$(length(unexpected)) unexpected** · $(length(expected)) expected · " *
            "$(length(informational)) informational\n",
        )
        if !isempty(unexpected)
            println(io, "## Unexpected differences\n")
            write_unexpected(io, unexpected)
        end
        if !isempty(expected)
            println(io, "## Expected (accepted PSY5 → PSY6 changes)\n")
            write_expected(io, expected)
        end
        if !isempty(informational)
            println(io, "## Informational (new in PSY6, moved to ext, or unreadable)\n")
            write_informational(io, informational)
        end
        write_conversion(io, conversion)
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

    top = group_by(d -> (d.kind, location(d)), unexpected)
    reason = join(
        ["$kind $at ×$(length(group))" for ((kind, at), group) in first(top, 2)],
        "; ",
    )
    if length(top) > 2
        reason *= "; +$(length(top) - 2) more"
    end
    return CaseResult(
        case_name(case),
        nothing,
        length(unexpected),
        length(expected),
        length(informational),
        reason,
    )
end

function compare_case(work_dir, case)
    dir = case_dir(work_dir, case)
    mkpath(dir)
    clear_step!(dir, "compare")
    for step in STEPS
        error_path = joinpath(dir, error_file(step))
        if isfile(error_path)
            return CaseResult(case_name(case), step, first_error_line(error_path))
        end
    end
    for file in (PSY5_SNAPSHOT, PSY5_VALUES, PSY6_SNAPSHOT, PSY6_VALUES)
        if !isfile(joinpath(dir, file))
            return CaseResult(case_name(case), "missing $file", "step did not run")
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
        read_conversion(dir),
    )
end

"""
The case's comparison, else its failed step's error file, else its directory.
"""
function report_path(work_dir, r::CaseResult)
    if isnothing(r.failed_step)
        return joinpath(r.case, COMPARISON_REPORT)
    end
    error_path = joinpath(r.case, error_file(r.failed_step))
    if isfile(joinpath(work_dir, error_path))
        return error_path
    end
    return r.case
end

report_link(work_dir, r::CaseResult) = "[report](<$(report_path(work_dir, r))>)"

const OUTCOMES = ("pass", "differ", "load error", "convert error", "compare error")

function totals_line(results)
    counts = [o => count(r -> outcome(r) == o, results) for o in OUTCOMES]
    shown = ["$n $o" for (o, n) in counts if n > 0 || o == "pass"]
    return "$(join(shown, " · ")) — $(length(results)) cases"
end

function write_summary(io, work_dir, results)
    println(io, "# PSY5 → PSY6 comparison\n")
    println(io, totals_line(results), "\n")
    failing = filter(!passed, results)
    if !isempty(failing)
        println(io, "## Needs attention ($(length(failing)))\n")
        sort!(failing; by = r -> !isnothing(r.failed_step))
        md_table(
            io,
            ("case", "result", "reason", "report"),
            [(r.case, status(r), r.reason, report_link(work_dir, r)) for r in failing],
        )
    end
    println(io, "## All cases\n")
    md_table(
        io,
        ("case", "result", "unexpected", "expected", "informational", "report"),
        [
            (
                r.case,
                status(r),
                r.unexpected,
                r.expected,
                r.informational,
                report_link(work_dir, r),
            ) for r in results
        ],
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
            CaseResult(case_name(case), "compare", first_error_line(joinpath(dir, error_file("compare"))))
        end
        push!(results, result)
    end
    summary_path = joinpath(work_dir, SUMMARY)
    open(io -> write_summary(io, work_dir, results), summary_path, "w")
    println("compare: ", totals_line(results), "\nsummary: ", summary_path)
    return all(passed, results) ? 0 : 1
end

exit(main(ARGS))
