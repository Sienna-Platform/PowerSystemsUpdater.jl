"""
PSY6 drops `WindingGroupNumber` and keeps only the angle, in `TransformerCircuit.alpha`
(radians).

A literal table, deliberately not `-n * pi / 6`: the enum is sparse, and its sign is
inverted relative to the obvious reading — `GROUP_1` is -30 degrees, not +30. See
`PowerSystems/src/definitions.jl:229-236` and the inverse map at
`src/parsers/power_models_data.jl:1229`.
"""
const WINDING_GROUP_ALPHA = Dict{String, Float64}(
    "GROUP_0" => 0.0,
    "GROUP_1" => -pi / 6,
    "GROUP_5" => -5pi / 6,
    "GROUP_6" => pi,
    "GROUP_7" => 5pi / 6,
    "GROUP_11" => pi / 6,
    # "not specified" takes PSY6's own schema default for alpha, not an invented angle.
    "UNDEFINED" => 0.0,
)

function winding_group_alpha(group::AbstractString)
    key = String(group)
    if !haskey(WINDING_GROUP_ALPHA, key)
        throw(Psy5FormatError("unknown WindingGroupNumber $key"))
    end
    return WINDING_GROUP_ALPHA[key]
end

# Fields consumed by the circuit rather than the transformer container.
const CIRCUIT_FIELDS = Set([
    "arc", "tap", "r", "x", "rating", "rating_b", "rating_c",
    "active_power_flow", "reactive_power_flow", "base_power",
    "base_voltage_primary", "base_voltage_secondary", "control_objective",
    "regulated_bus_number", "number_of_tap_positions", "available",
])

function _circuit_source(raw::AbstractDict)
    source = Dict{String, Any}("__metadata__" => raw["__metadata__"])
    for (key, value) in raw
        if key in CIRCUIT_FIELDS
            source[key] = value
        end
    end
    return source
end

"""
Fields consumed directly by the `TwoWindingTransformer` container rather than by
`_circuit_source`'s allow-list or `build_kwargs`.
"""
const TRANSFORMER_CONSUMED_FIELDS =
    Set(["name", "primary_shunt", "winding_group_number", "α"])

"""
Record every PSY5 key on `raw` that is neither internal, nor routed to the circuit via
`CIRCUIT_FIELDS`, nor consumed directly by the transformer container. `_circuit_source`'s
allow-list means such keys never reach `build_kwargs`, so without this they would vanish
with no trace in `ConversionReport` — exactly the silent loss this package exists to catch.
"""
function _record_dropped_fields!(raw::AbstractDict, ctx::TranslationContext)
    type_name = component_type(raw)
    for key in keys(raw)
        if key in PSY5_INTERNAL_FIELDS || key in CIRCUIT_FIELDS ||
           key in TRANSFORMER_CONSUMED_FIELDS
            continue
        end
        record_unmapped_field!(ctx.report, type_name, key)
    end
    return nothing
end

"""
PSY5's `primary_shunt` serializes a `Complex{Float64}` with keys `real`/`imag`, matching
PSY6's `ComplexNumber` schema (`SiennaSchemas/Core/common.json#/definitions/ComplexNumber`)
exactly. Built explicitly rather than forwarding the raw dict so construction does not
depend on the two shapes coinciding.
"""
function _magnetizing_shunt(raw::AbstractDict)
    shunt = get(raw, "primary_shunt", nothing)
    if isnothing(shunt)
        return nothing
    end
    return PCOM.ComplexNumber(;
        real = Float64(shunt["real"]),
        imag = Float64(shunt["imag"]),
    )
end

"""
Build the `TransformerCircuit` for a two-winding transformer.

`alpha` comes from `α` when the PSY5 type carries one (`PhaseShiftingTransformer`) and from
the winding group otherwise. The two never coexist on the same PSY5 type, so nothing is
summed.
"""
function _build_circuit(raw::AbstractDict, ctx::TranslationContext, alpha::Float64)
    circuit_id = allocate_id!(ctx.ledger)
    extra = Dict{Symbol, Any}(
        :id => circuit_id,
        :alpha => alpha,
        :base_power => base_power_for(raw, ctx.system_base),
    )
    if !haskey(raw, "tap")
        extra[:tap] = 1.0
    end
    kwargs = build_kwargs(
        POM.TransformerCircuit,
        _circuit_source(raw),
        ctx.ledger,
        ctx.report;
        extra = extra,
    )
    return POM.TransformerCircuit(; kwargs...)
end

function _translate_two_winding(
    raw::AbstractDict,
    ctx::TranslationContext,
    alpha::Float64,
)
    _record_dropped_fields!(raw, ctx)
    circuit = _build_circuit(raw, ctx, alpha)
    transformer = POM.TwoWindingTransformer(;
        id = lookup_id(ctx.ledger, component_uuid(raw)),
        name = raw["name"],
        circuit = circuit.id,
        magnetizing_shunt = _magnetizing_shunt(raw),
    )
    return OpenAPI.APIModel[circuit, transformer]
end

function _group_alpha(raw::AbstractDict)
    group = get(raw, "winding_group_number", "GROUP_0")
    return winding_group_alpha(group)
end

function translate(::Val{:Transformer2W}, raw::AbstractDict, ctx::TranslationContext)
    return _translate_two_winding(raw, ctx, _group_alpha(raw))
end

function translate(::Val{:TapTransformer}, raw::AbstractDict, ctx::TranslationContext)
    return _translate_two_winding(raw, ctx, _group_alpha(raw))
end

function translate(
    ::Val{:PhaseShiftingTransformer},
    raw::AbstractDict,
    ctx::TranslationContext,
)
    return _translate_two_winding(raw, ctx, Float64(raw["α"]))
end

const THREE_WINDING_TERMINALS = (:primary, :secondary, :tertiary)

# Fields consumed by `translate(::Val{:Transformer3W}, ...)` and `_winding_circuit`,
# mirroring their exact key-name construction so this stays in lockstep with the reader.
const THREE_WINDING_CONSUMED_FIELDS = Set{String}(
    vcat(
        [
            "name", "star_bus", "r_12", "x_12", "r_23", "x_23", "r_13", "x_13",
            "base_power_12", "base_power_23", "base_power_13", "g", "b",
        ],
        vcat(
            [
                [
                    "$(suffix)_star_arc",
                    "$(suffix)_turns_ratio",
                    "$(suffix)_group_number",
                    "available_$suffix",
                    "r_$suffix",
                    "x_$suffix",
                    "rating_$suffix",
                    "active_power_flow_$suffix",
                    "reactive_power_flow_$suffix",
                    "base_voltage_$suffix",
                    "control_objective_$suffix",
                ] for suffix in string.(THREE_WINDING_TERMINALS)
            ]...,
        ),
    ),
)

"""
Record every PSY5 key on `raw` that is neither internal nor consumed by
`translate(::Val{:Transformer3W}, ...)`. PSY5's `Transformer3W` carries a top-level
`available` and a top-level `rating` alongside the per-winding fields; PSY6's
`ThreeWindingTransformer` has neither, since availability and rating are circuit-level
(each `TransformerCircuit` already carries its own, from `available_\$suffix`/
`rating_\$suffix`). Those two keys are genuinely redundant with the per-circuit data and are
dropped; recording them keeps that finding visible instead of silent.
"""
function _record_dropped_three_winding_fields!(raw::AbstractDict, ctx::TranslationContext)
    type_name = component_type(raw)
    for key in keys(raw)
        if key in PSY5_INTERNAL_FIELDS || key in THREE_WINDING_CONSUMED_FIELDS
            continue
        end
        record_unmapped_field!(ctx.report, type_name, key)
    end
    return nothing
end

function _winding_circuit(
    raw::AbstractDict,
    ctx::TranslationContext,
    terminal::Symbol,
)
    suffix = string(terminal)
    circuit_id = allocate_id!(ctx.ledger)
    return POM.TransformerCircuit(;
        id = circuit_id,
        available = raw["available_$suffix"],
        arc = lookup_id(ctx.ledger, reference_uuid(raw["$(suffix)_star_arc"])),
        tap = raw["$(suffix)_turns_ratio"],
        alpha = winding_group_alpha(get(raw, "$(suffix)_group_number", "UNDEFINED")),
        r = raw["r_$suffix"],
        x = raw["x_$suffix"],
        rating = get(raw, "rating_$suffix", nothing),
        active_power_flow = get(raw, "active_power_flow_$suffix", nothing),
        reactive_power_flow = get(raw, "reactive_power_flow_$suffix", nothing),
        base_power = base_power_for(raw, ctx.system_base),
        base_voltage_primary = get(raw, "base_voltage_$suffix", nothing),
        control_objective = get(raw, "control_objective_$suffix", nothing),
    )
end

"""
PSY5 stores both the pairwise-measured and the star-equivalent forms, so nothing is
inverted. Note PSY5's 1-3 pair is PSY6's 3-1: the index order flips.
"""
function translate(::Val{:Transformer3W}, raw::AbstractDict, ctx::TranslationContext)
    _record_dropped_three_winding_fields!(raw, ctx)
    circuits = [_winding_circuit(raw, ctx, t) for t in THREE_WINDING_TERMINALS]
    transformer = POM.ThreeWindingTransformer(;
        id = lookup_id(ctx.ledger, component_uuid(raw)),
        name = raw["name"],
        primary_circuit = circuits[1].id,
        secondary_circuit = circuits[2].id,
        tertiary_circuit = circuits[3].id,
        star_bus = lookup_id(ctx.ledger, reference_uuid(raw["star_bus"])),
        r_12 = raw["r_12"],
        x_12 = raw["x_12"],
        r_23 = raw["r_23"],
        x_23 = raw["x_23"],
        r_31 = raw["r_13"],
        x_31 = raw["x_13"],
        base_power_12 = raw["base_power_12"],
        base_power_23 = raw["base_power_23"],
        base_power_31 = raw["base_power_13"],
        # PSY5 stores the star-to-ground magnetizing shunt as two floats (g, b); PSY6
        # stores it as one ComplexNumber.
        magnetizing_shunt = PCOM.ComplexNumber(;
            real = Float64(raw["g"]),
            imag = Float64(raw["b"]),
        ),
    )
    models = OpenAPI.APIModel[c for c in circuits]
    push!(models, transformer)
    return models
end
