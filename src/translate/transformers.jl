"""
PSY6 drops `WindingGroupNumber` and keeps only the angle, in `TransformerCircuit.alpha`
(radians).

A literal table, deliberately not `-n * pi / 6`: the enum is sparse, and its sign is
inverted relative to the obvious reading — `GROUP_1` is -30 degrees, not +30.
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
function _record_dropped_fields!(
    raw::AbstractDict,
    ctx::TranslationContext,
    consumed::AbstractVector{String} = String[],
)
    type_name = component_type(raw)
    for key in keys(raw)
        if key in PSY5_INTERNAL_FIELDS || key in CIRCUIT_FIELDS ||
           key in TRANSFORMER_CONSUMED_FIELDS || key in consumed
            continue
        end
        record_unmapped_field!(ctx.report, type_name, key)
        keep_unmapped!(ctx.ledger, key, raw[key])
    end
    return nothing
end

"""
PSY5's `primary_shunt` serializes a `Complex{Float64}` with keys `real`/`imag`, matching
PSY6's `TwoWindingTransformer.magnetizing_shunt` schema
(`SiennaSchemas/Operations/Branch/TwoWindingTransformer.json`) exactly. Built explicitly
rather than forwarding the raw dict so construction does not depend on the two shapes
coinciding.

`magnetizing_shunt` `\$ref`s `Core/common.json#/\$defs/ComplexNumber` and generates as the
shared `ComplexNumber` type, so that is what is built here.
"""
function _magnetizing_shunt(raw::AbstractDict)
    shunt = get(raw, "primary_shunt", nothing)
    if isnothing(shunt)
        return nothing
    end
    return ICOM.ComplexNumber(;
        real = Float64(shunt["real"]),
        imag = Float64(shunt["imag"]),
    )
end

"""
The bands each schema-0.2 `control_objective` requires on a `TransformerCircuit` (its
conditional `allOf` blocks). `UNDEFINED`, "no control block", requires none.
"""
const CONTROL_OBJECTIVE_BANDS = Dict{String, Tuple{Vararg{Symbol}}}(
    "FIXED" => (:controlled_voltage_limits,),
    "VOLTAGE" => (:controlled_voltage_limits,),
    "VOLTAGE_DISABLED" => (:controlled_voltage_limits,),
    "REACTIVE_POWER_FLOW" => (:controlled_reactive_power_flow_limits,),
    "REACTIVE_POWER_FLOW_DISABLED" => (:controlled_reactive_power_flow_limits,),
    "CONTROL_OF_DC_LINE" => (:controlled_active_power_flow_limits,),
    "CONTROL_OF_DC_LINE_DISABLED" => (:controlled_active_power_flow_limits,),
    "ACTIVE_POWER_FLOW" => (:phase_angle_limits, :controlled_active_power_flow_limits),
    "ACTIVE_POWER_FLOW_DISABLED" =>
        (:phase_angle_limits, :controlled_active_power_flow_limits),
    "ASYMMETRIC_ACTIVE_POWER_FLOW" =>
        (:phase_angle_limits, :controlled_active_power_flow_limits),
    "ASYMMETRIC_ACTIVE_POWER_FLOW_DISABLED" =>
        (:phase_angle_limits, :controlled_active_power_flow_limits),
)

"""
Objectives that move the tap rather than the phase angle. Schema 0.2 lets their actuator band,
`tap_ratio_limits`, be omitted ("defaults to 0.9 to 1.1, PSS/E's own RMI/RMA defaults"), but
PowerSystems 6 rejects a circuit with one of these objectives and no `tap_ratio_limits`
(`branchdata_checks.jl`), so it is always written: from the PSY5 fields or PSS/E `ext` like the
required bands, else the schema's documented default.
"""
const TAP_MOVING_OBJECTIVES = Set([
    "FIXED", "VOLTAGE", "VOLTAGE_DISABLED",
    "REACTIVE_POWER_FLOW", "REACTIVE_POWER_FLOW_DISABLED",
    "CONTROL_OF_DC_LINE", "CONTROL_OF_DC_LINE_DISABLED",
])

const DEFAULT_TAP_RATIO_LIMITS = (0.9, 1.1)

"""
PSY5's `TransformerControlObjective` values are PSS/E's `COD` codes. A PSS/E `ext` row's
bands are only used when its `COD` agrees with the objective, so they describe that control.
"""
const PSSE_CONTROL_CODE = Dict{String, Int}(
    "FIXED" => 0,
    "VOLTAGE" => 1,
    "VOLTAGE_DISABLED" => -1,
    "REACTIVE_POWER_FLOW" => 2,
    "REACTIVE_POWER_FLOW_DISABLED" => -2,
    "ACTIVE_POWER_FLOW" => 3,
    "ACTIVE_POWER_FLOW_DISABLED" => -3,
    "CONTROL_OF_DC_LINE" => 4,
    "CONTROL_OF_DC_LINE_DISABLED" => -4,
    "ASYMMETRIC_ACTIVE_POWER_FLOW" => 5,
    "ASYMMETRIC_ACTIVE_POWER_FLOW_DISABLED" => -5,
)

_min_max(lo::Real, hi::Real) = Dict{String, Any}("min" => Float64(lo), "max" => Float64(hi))

"""
A band from the PSY5 transformer's own fields, with the PSY5 key it came from, or `nothing`.
Tried first: any PSY5 system has these, whatever it was built from. `TapTransformer`'s single
`voltage_setpoint` becomes a zero-width voltage band and its `tap_limits` the tap-ratio band;
`PhaseShiftingTransformer`'s `phase_angle_limits` (radians) carries straight across.
"""
function _band_from_fields(raw::AbstractDict, band::Symbol)
    if band === :controlled_voltage_limits && haskey(raw, "voltage_setpoint")
        setpoint = raw["voltage_setpoint"]
        return (_min_max(setpoint, setpoint), "voltage_setpoint")
    elseif band === :tap_ratio_limits && haskey(raw, "tap_limits")
        limits = raw["tap_limits"]
        return (_min_max(limits["min"], limits["max"]), "tap_limits")
    elseif band === :phase_angle_limits && haskey(raw, "phase_angle_limits")
        limits = raw["phase_angle_limits"]
        return (_min_max(limits["min"], limits["max"]), "phase_angle_limits")
    end
    return nothing
end

_ext_number(ext::AbstractDict, key::AbstractString) = _ext_number(get(ext, key, nothing))
_ext_number(value::Real) = Float64(value)
_ext_number(::Any) = nothing

"""
A band from the PSS/E columns a PSS/E-sourced PSY5 system keeps in `ext`, for winding
`winding` (1 for a two-winding transformer, 1-3 for a three-winding one), or `nothing` when
they are absent or describe a different control (`COD` disagreeing with the objective).

PSS/E's `VMA`/`VMI` are the target band: per unit voltage for the voltage objectives, MVAr or
MW for the flow objectives, converted here to per unit on the circuit's own base. `RMA`/`RMI`
are the actuator band: the tap ratio for the tap-moving objectives, a phase shifter's angle
limits (degrees) for the others.
"""
function _band_from_psse_ext(
    ext::AbstractDict,
    band::Symbol,
    winding::Int,
    objective::AbstractString,
    base_power::Real,
)
    code = _ext_number(ext, "COD$winding")
    if isnothing(code) || code != PSSE_CONTROL_CODE[objective]
        return nothing
    end
    if band === :phase_angle_limits || band === :tap_ratio_limits
        lo, hi = _ext_number(ext, "RMI$winding"), _ext_number(ext, "RMA$winding")
        scale = band === :phase_angle_limits ? pi / 180 : 1.0
    else
        lo, hi = _ext_number(ext, "VMI$winding"), _ext_number(ext, "VMA$winding")
        scale = band === :controlled_voltage_limits ? 1.0 : 1.0 / base_power
    end
    if isnothing(lo) || isnothing(hi)
        return nothing
    end
    return _min_max(lo * scale, hi * scale)
end

"""
The `control_objective` and bands to write on one circuit, and the PSY5 keys used for them.

Schema 0.2 requires, for each objective other than `UNDEFINED`, the bands in
`CONTROL_OBJECTIVE_BANDS`; tap-moving objectives also get `tap_ratio_limits` (see
`TAP_MOVING_OBJECTIVES`). Each band is taken from the PSY5 transformer's own fields where it
has one (`_band_from_fields`), else from PSS/E columns in its `ext`
(`_band_from_psse_ext`). If a required band is in neither, the circuit is written with
`UNDEFINED` (no control block) so the document stays valid; the PSY5 objective is recorded
against `objective_key` in the report and kept in the component's `ext`.
"""
function _control_block(
    raw::AbstractDict,
    objective_key::AbstractString,
    winding::Int,
    base_power::Real,
    ctx::TranslationContext,
)
    objective = get(raw, objective_key, nothing)
    if isnothing(objective) || objective == "UNDEFINED"
        return (objective, Dict{Symbol, Any}(), String[])
    end
    if !haskey(CONTROL_OBJECTIVE_BANDS, objective)
        throw(Psy5FormatError("unknown transformer control objective $objective"))
    end
    ext = something(get(raw, "ext", nothing), Dict{String, Any}())
    bands = Dict{Symbol, Any}()
    consumed = String[]
    for band in CONTROL_OBJECTIVE_BANDS[objective]
        from_fields = _band_from_fields(raw, band)
        if !isnothing(from_fields)
            bands[band], key = from_fields
            push!(consumed, key)
            continue
        end
        from_ext = _band_from_psse_ext(ext, band, winding, objective, base_power)
        if isnothing(from_ext)
            record_unmapped_field!(ctx.report, component_type(raw), objective_key)
            keep_unmapped!(ctx.ledger, objective_key, objective)
            return ("UNDEFINED", Dict{Symbol, Any}(), String[])
        end
        bands[band] = from_ext
    end
    if objective in TAP_MOVING_OBJECTIVES
        from_fields = _band_from_fields(raw, :tap_ratio_limits)
        if !isnothing(from_fields)
            bands[:tap_ratio_limits], key = from_fields
            push!(consumed, key)
        else
            bands[:tap_ratio_limits] = something(
                _band_from_psse_ext(ext, :tap_ratio_limits, winding, objective, base_power),
                _min_max(DEFAULT_TAP_RATIO_LIMITS...),
            )
        end
    end
    return (objective, bands, consumed)
end

"""
Build the `TransformerCircuit` for a two-winding transformer.

`alpha` comes from `α` when the PSY5 type carries one (`PhaseShiftingTransformer`) and from
the winding group otherwise. The two never coexist on the same PSY5 type, so nothing is
summed.

Returns the circuit and the PSY5 keys its control block consumed (see `_control_block`).
"""
function _build_circuit(raw::AbstractDict, ctx::TranslationContext, alpha::Float64)
    circuit_id = allocate_id!(ctx.ledger)
    base_power = base_power_for(raw, ctx.system_base)
    objective, bands, consumed =
        _control_block(raw, "control_objective", 1, base_power, ctx)
    extra = Dict{Symbol, Any}(
        :id => circuit_id,
        :alpha => alpha,
        :base_power => base_power,
        :power_units => "COMPONENT_BASE",
        bands...,
    )
    if !isnothing(objective)
        extra[:control_objective] = objective
    end
    if !haskey(raw, "tap")
        extra[:tap] = 1.0
    end
    kwargs = build_kwargs(
        POOM.TransformerCircuit,
        _circuit_source(raw),
        ctx.ledger,
        ctx.report;
        extra = extra,
    )
    return POOM.TransformerCircuit(; kwargs...), consumed
end

function _translate_two_winding(
    raw::AbstractDict,
    ctx::TranslationContext,
    alpha::Float64,
)
    circuit, consumed = _build_circuit(raw, ctx, alpha)
    _record_dropped_fields!(raw, ctx, consumed)
    transformer = POOM.TwoWindingTransformer(;
        id = lookup_id(ctx.ledger, component_uuid(raw)),
        name = raw["name"],
        circuit = circuit.id,
        magnetizing_shunt = _magnetizing_shunt(raw),
    )
    return ICOM.APIModel[circuit, transformer]
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
        keep_unmapped!(ctx.ledger, key, raw[key])
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
    base_power = base_power_for(raw, ctx.system_base)
    winding = findfirst(==(terminal), THREE_WINDING_TERMINALS)
    objective, bands, _ =
        _control_block(raw, "control_objective_$suffix", winding, base_power, ctx)
    # Built as a plain kwargs Dict and run through `_decode_kwargs`, the same as
    # `build_kwargs`'s output, rather than passed straight to the constructor: `power_units`
    # and `control_objective` are bare `String`s here (a schema enum spelling), and
    # `TransformerCircuit`'s fields are strictly typed (`UnitSystem`,
    # `TransformerCircuitControlObjective`) under the OpenAPI 1.1 generator.
    kwargs = Dict{Symbol, Any}(
        :id => circuit_id,
        :available => raw["available_$suffix"],
        :arc => lookup_id(ctx.ledger, reference_uuid(raw["$(suffix)_star_arc"])),
        :tap => raw["$(suffix)_turns_ratio"],
        :alpha => winding_group_alpha(get(raw, "$(suffix)_group_number", "UNDEFINED")),
        :r => raw["r_$suffix"],
        :x => raw["x_$suffix"],
        :rating => get(raw, "rating_$suffix", nothing),
        :active_power_flow => get(raw, "active_power_flow_$suffix", nothing),
        :reactive_power_flow => get(raw, "reactive_power_flow_$suffix", nothing),
        :base_power => base_power,
        :power_units => "COMPONENT_BASE",
        :base_voltage_primary => get(raw, "base_voltage_$suffix", nothing),
        :control_objective => objective,
    )
    merge!(kwargs, bands)
    return POOM.TransformerCircuit(; _decode_kwargs(POOM.TransformerCircuit, kwargs)...)
end

"""
`_winding_circuit` fills each circuit's `available`/`rating` from `available_\$suffix`/
`rating_\$suffix`, whose PSY5 defaults are `true`/`0.0` — the same values a genuinely
redundant top-level field would have. A real top-level `available=false` would be silently
replaced by three available circuits, and a real top-level `rating` would be silently
replaced by a zero-capacity one, if any per-winding rating is still at its default. Recording
the drop (`_record_dropped_three_winding_fields!`) is not the same as not producing a wrong
value, so both cases error instead.
"""
function _check_transformer3w_top_level!(raw::AbstractDict)
    name = get(raw, "name", "<unnamed>")
    available = get(raw, "available", true)
    if available === false
        throw(
            Psy5FormatError(
                "Transformer3W \"$name\": top-level available=false would be silently " *
                "replaced by available_\$suffix's default (true) on every TransformerCircuit",
            ),
        )
    end
    rating = get(raw, "rating", 0.0)
    if !iszero(rating)
        for suffix in string.(THREE_WINDING_TERMINALS)
            winding_rating = get(raw, "rating_$suffix", 0.0)
            if isnothing(winding_rating) || iszero(winding_rating)
                throw(
                    Psy5FormatError(
                        "Transformer3W \"$name\": top-level rating=$rating is non-zero " *
                        "but rating_$suffix is zero — the circuit would silently get a " *
                        "zero-capacity rating",
                    ),
                )
            end
        end
    end
    return nothing
end

"""
PSY5 stores both the pairwise-measured and the star-equivalent forms, so nothing is
inverted. Note PSY5's 1-3 pair is PSY6's 3-1: the index order flips.
"""
function translate(::Val{:Transformer3W}, raw::AbstractDict, ctx::TranslationContext)
    _check_transformer3w_top_level!(raw)
    _record_dropped_three_winding_fields!(raw, ctx)
    circuits = [_winding_circuit(raw, ctx, t) for t in THREE_WINDING_TERMINALS]
    transformer = POOM.ThreeWindingTransformer(;
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
        # stores it as one shared ComplexNumber (see _magnetizing_shunt above).
        magnetizing_shunt = ICOM.ComplexNumber(;
            real = Float64(raw["g"]),
            imag = Float64(raw["b"]),
        ),
        # PSY5's g/b are star-bus-to-ground, not primary-side, so
        # the schema's PRIMARY default is wrong here — unlike the two-winding path.
        shunt_location = POOM.ThreeWindingTransformerShuntLocation("STAR"),
    )
    models = ICOM.APIModel[c for c in circuits]
    push!(models, transformer)
    return models
end
