"""
PSY5 `WindingGroupNumber` as the angle PSY6 keeps in `TransformerCircuit.alpha` (radians).
A literal table, not `-n * pi / 6`: the enum is sparse and `GROUP_1` is -30 degrees.
"""
const WINDING_GROUP_ALPHA = Dict{String, Float64}(
    "GROUP_0" => 0.0,
    "GROUP_1" => -pi / 6,
    "GROUP_5" => -5pi / 6,
    "GROUP_6" => pi,
    "GROUP_7" => 5pi / 6,
    "GROUP_11" => pi / 6,
    "UNDEFINED" => 0.0,
)

function winding_group_alpha(group::AbstractString)
    key = String(group)
    if !haskey(WINDING_GROUP_ALPHA, key)
        throw(Psy5FormatError("unknown WindingGroupNumber $key"))
    end
    return WINDING_GROUP_ALPHA[key]
end

# Fields that go to the `TransformerCircuit` rather than the transformer.
const CIRCUIT_FIELDS = Set([
    "arc", "tap", "r", "x", "rating", "rating_b", "rating_c",
    "active_power_flow", "reactive_power_flow", "base_power",
    "base_voltage_primary", "base_voltage_secondary", "control_objective",
    "regulated_bus_number", "number_of_tap_positions", "available",
])

"""Objectives under which a `TransformerCircuit` names the bus its tap regulates."""
const REGULATED_BUS_OBJECTIVES = Set(["VOLTAGE", "VOLTAGE_DISABLED"])

"""
PSY5 `regulated_bus_number` (PSS/E CONT) as `regulated_bus` (an id) and
`regulated_bus_orientation`. PSS/E holds the orientation in the sign: positive is `TO`
(winding two side), negative `FROM`. It is stated only for a bus off the arc, else `UNDEFINED`.

0 means none. Under an objective outside `REGULATED_BUS_OBJECTIVES` the number has no PSY6
field, so it is kept in ext and reported.
"""
function _regulated_bus_fields(
    raw::AbstractDict,
    objective,
    ctx::TranslationContext,
)
    number = get(raw, "regulated_bus_number", 0)
    if iszero(number)
        return Dict{Symbol, Any}()
    end
    if !(objective in REGULATED_BUS_OBJECTIVES)
        record_unmapped_field!(ctx.report, component_type(raw), "regulated_bus_number")
        keep_unmapped!(ctx.ledger, "regulated_bus_number", number)
        return Dict{Symbol, Any}()
    end
    name = get(raw, "name", "<unnamed>")
    regulated = bus_id_for_number(
        ctx,
        abs(number),
        "transformer \"$name\" regulated_bus_number",
    )
    ends = ctx.buses.arcs[reference_uuid(raw["arc"])]
    end_numbers = (bus_number(ctx, ends[1]), bus_number(ctx, ends[2]))
    orientation = "UNDEFINED"
    if !(abs(number) in end_numbers) && number > 0
        orientation = "TO"
    elseif !(abs(number) in end_numbers)
        orientation = "FROM"
    end
    return Dict{Symbol, Any}(
        :regulated_bus => regulated,
        :regulated_bus_orientation => orientation,
    )
end

function _circuit_source(raw::AbstractDict)
    source = Dict{String, Any}("__metadata__" => raw["__metadata__"])
    for (key, value) in raw
        if key in CIRCUIT_FIELDS && key != "regulated_bus_number"
            source[key] = value
        end
    end
    return source
end

# Fields the two-winding transformer consumes itself, with `CIRCUIT_FIELDS`.
const TWO_WINDING_KNOWN_FIELDS =
    union(CIRCUIT_FIELDS, ["name", "primary_shunt", "winding_group_number", "α"])

"""
Report and keep in ext every PSY5 key of `raw` that is not internal, in `known`, or in
`consumed`. Translation reads only the keys it knows, so without this the rest would vanish.
"""
function _record_dropped_fields!(
    raw::AbstractDict,
    ctx::TranslationContext,
    known::AbstractSet{String},
    consumed::AbstractVector{String},
)
    type_name = component_type(raw)
    for key in keys(raw)
        if key in PSY5_INTERNAL_FIELDS || key in known || key in consumed
            continue
        end
        record_unmapped_field!(ctx.report, type_name, key)
        keep_unmapped!(ctx.ledger, key, raw[key])
    end
    return nothing
end

"""PSY5 `primary_shunt` (`real`/`imag`) as PSY6's `magnetizing_shunt` `ComplexNumber`."""
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

"""The bands the schema requires on a `TransformerCircuit` for each `control_objective`."""
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
Objectives that move the tap. The schema lets `tap_ratio_limits` default to 0.9-1.1, but
PowerSystems 6 rejects such a circuit without them (`branchdata_checks.jl`), so they are always
written.
"""
const TAP_MOVING_OBJECTIVES = Set([
    "FIXED", "VOLTAGE", "VOLTAGE_DISABLED",
    "REACTIVE_POWER_FLOW", "REACTIVE_POWER_FLOW_DISABLED",
    "CONTROL_OF_DC_LINE", "CONTROL_OF_DC_LINE_DISABLED",
])

const DEFAULT_TAP_RATIO_LIMITS = (0.9, 1.1)

"""PSY5's default `TapTransformer.voltage_setpoint`, filled in for older files that omit it."""
const PSY5_DEFAULT_VOLTAGE_SETPOINT = 1.0

"""PSS/E `COD` code of each PSY5 `TransformerControlObjective`."""
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
A band from the transformer's own fields, with the PSY5 key it came from, or `nothing`:
`voltage_setpoint` becomes a zero-width voltage band, `tap_limits` the tap-ratio band, and
`phase_angle_limits` (radians) carries across.
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

"""
The voltage band of a `TapTransformer` whose older file omits `voltage_setpoint`, from
PSY5's own default, or `nothing`. Recorded as a PSY5 default.
"""
function _band_from_psy5_default(
    raw::AbstractDict,
    band::Symbol,
    ctx::TranslationContext,
)
    if band !== :controlled_voltage_limits || component_type(raw) != "TapTransformer" ||
       haskey(raw, "voltage_setpoint")
        return nothing
    end
    record_psy5_default!(ctx.report, "TapTransformer", "voltage_setpoint")
    return _min_max(PSY5_DEFAULT_VOLTAGE_SETPOINT, PSY5_DEFAULT_VOLTAGE_SETPOINT)
end

_ext_number(ext::AbstractDict, key::AbstractString) = _ext_number(get(ext, key, nothing))
_ext_number(value::Real) = Float64(value)
_ext_number(::Any) = nothing

"""
A band from the PSS/E columns kept in `ext`, for winding `winding`, or `nothing` when they are
absent or their `COD` disagrees with the objective.

`VMI`/`VMA` are the target band: per unit voltage, or MVAr/MW converted to per unit on
`base_power`. `RMI`/`RMA` are the actuator band: tap ratio, or a phase shifter's angle limits in
degrees.
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
The `control_objective`, its bands, and the PSY5 keys used, for one circuit.

Each band in `CONTROL_OBJECTIVE_BANDS` (and `tap_ratio_limits` for `TAP_MOVING_OBJECTIVES`) is
taken from the PSY5 fields (`_band_from_fields`), else PSS/E `ext` (`_band_from_psse_ext`), else
PSY5's default (`_band_from_psy5_default`). If a required band is in none, the circuit gets
`UNDEFINED` so the document stays valid, and the objective is reported and kept in ext.
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
            from_ext = _band_from_psy5_default(raw, band, ctx)
        end
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
            from_ext =
                _band_from_psse_ext(ext, :tap_ratio_limits, winding, objective, base_power)
            if isnothing(from_ext)
                from_ext = _min_max(DEFAULT_TAP_RATIO_LIMITS...)
                record_schema_default!(ctx.report, component_type(raw), "tap_ratio_limits")
            end
            bands[:tap_ratio_limits] = from_ext
        end
    end
    return (objective, bands, consumed)
end

"""Build a two-winding transformer's `TransformerCircuit`, and the PSY5 keys its bands used."""
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
        _regulated_bus_fields(raw, objective, ctx)...,
    )
    if !isnothing(objective)
        extra[:control_objective] = objective
    end
    if !haskey(raw, "tap")
        extra[:tap] = 1.0
    end
    source = _circuit_source(raw)
    kwargs = build_kwargs(
        POOM.TransformerCircuit,
        source,
        ctx.ledger,
        ctx.report;
        extra = extra,
        units = component_units(source, ctx),
    )
    return POOM.TransformerCircuit(; kwargs...), consumed
end

function _translate_two_winding(
    raw::AbstractDict,
    ctx::TranslationContext,
    alpha::Float64,
)
    circuit, consumed = _build_circuit(raw, ctx, alpha)
    _record_dropped_fields!(raw, ctx, TWO_WINDING_KNOWN_FIELDS, consumed)
    transformer = POOM.TwoWindingTransformer(;
        id = lookup_id(ctx.ledger, component_uuid(raw)),
        name = raw["name"],
        circuit = circuit.id,
        magnetizing_shunt = _magnetizing_shunt(raw),
    )
    return ICOM.APIModel[circuit, transformer]
end

_group_alpha(raw::AbstractDict) =
    winding_group_alpha(get(raw, "winding_group_number", "GROUP_0"))

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

# Keys `translate(::Val{:Transformer3W}, ...)` and `_winding_circuit` read.
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
                    "α_$suffix",
                ] for suffix in string.(THREE_WINDING_TERMINALS)
            ]...,
        ),
    ),
)

"""
`raw[key]` if it is a physical base voltage; otherwise `nothing`, reported and kept in ext
as `build_kwargs` does (`_non_physical_base`).
"""
function _physical_base_voltage(
    raw::AbstractDict,
    key::AbstractString,
    ctx::TranslationContext,
)
    value = get(raw, key, nothing)
    if _non_physical_base(key, value)
        record_dropped_invalid_value!(ctx.report, component_type(raw), key)
        keep_unmapped!(ctx.ledger, key, value)
        return nothing
    end
    return value
end

"""
The pair base each winding's values are stored on (PSY5 `_get_winding_base_power`), used as the
circuit's `base_power` so the values are not scaled.
"""
const THREE_WINDING_BASE_POWER_KEY = Dict(
    :primary => "base_power_12",
    :secondary => "base_power_23",
    :tertiary => "base_power_13",
)

"""
A winding circuit's availability: the transformer's `available` AND `available_\$suffix`. PSY6
derives the transformer's availability from its circuits.
"""
_winding_available(raw::AbstractDict, suffix::AbstractString) =
    get(raw, "available", true) && raw["available_$suffix"]

function _winding_circuit(
    raw::AbstractDict,
    ctx::TranslationContext,
    terminal::Symbol,
)
    suffix = string(terminal)
    circuit_id = allocate_id!(ctx.ledger)
    base_power = Float64(raw[THREE_WINDING_BASE_POWER_KEY[terminal]])
    winding = findfirst(==(terminal), THREE_WINDING_TERMINALS)
    objective, bands, consumed =
        _control_block(raw, "control_objective_$suffix", winding, base_power, ctx)
    # `_decode_kwargs` turns the enum strings into the strictly typed fields.
    kwargs = Dict{Symbol, Any}(
        :id => circuit_id,
        :available => _winding_available(raw, suffix),
        :arc => lookup_id(ctx.ledger, reference_uuid(raw["$(suffix)_star_arc"])),
        :tap => raw["$(suffix)_turns_ratio"],
        :alpha => _winding_alpha(raw, suffix),
        :r => raw["r_$suffix"],
        :x => raw["x_$suffix"],
        :rating => get(raw, "rating_$suffix", nothing),
        :active_power_flow => get(raw, "active_power_flow_$suffix", nothing),
        :reactive_power_flow => get(raw, "reactive_power_flow_$suffix", nothing),
        :base_power => base_power,
        :power_units => "COMPONENT_BASE",
        :base_voltage_primary =>
            _physical_base_voltage(raw, "base_voltage_$suffix", ctx),
        :control_objective => objective,
    )
    merge!(kwargs, bands)
    circuit = POOM.TransformerCircuit(; _decode_kwargs(POOM.TransformerCircuit, kwargs)...)
    return circuit, consumed
end

"""A winding's phase shift: `α_\$suffix` (radians) if present, else its group number's angle."""
_winding_alpha(raw::AbstractDict, suffix::AbstractString) = get(
    raw,
    "α_$suffix",
    winding_group_alpha(get(raw, "$(suffix)_group_number", "UNDEFINED")),
)

"""
Circuits take `rating` from `rating_\$suffix` (PSY5 default `0.0`) and the top-level `rating`
is dropped, so a non-zero top-level rating with a zero winding rating would silently give a
zero-capacity circuit: error instead.
"""
function _check_transformer3w_top_level!(raw::AbstractDict)
    name = get(raw, "name", "<unnamed>")
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
PSY5 stores both the pairwise and the star-equivalent forms, so nothing is inverted. PSY5's
1-3 pair is PSY6's 3-1.
"""
function translate(::Val{:Transformer3W}, raw::AbstractDict, ctx::TranslationContext)
    _check_transformer3w_top_level!(raw)
    built = [_winding_circuit(raw, ctx, t) for t in THREE_WINDING_TERMINALS]
    circuits = first.(built)
    _record_dropped_fields!(
        raw,
        ctx,
        THREE_WINDING_CONSUMED_FIELDS,
        reduce(vcat, last.(built)),
    )
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
        # PSY5's star-to-ground shunt is two floats (g, b).
        magnetizing_shunt = ICOM.ComplexNumber(;
            real = Float64(raw["g"]),
            imag = Float64(raw["b"]),
        ),
        # g/b sit at the star bus, unlike the schema's PRIMARY default.
        shunt_location = POOM.ThreeWindingTransformerShuntLocation("STAR"),
    )
    models = ICOM.APIModel[c for c in circuits]
    push!(models, transformer)
    return models
end

"""
PSY6 has no phase-shifting three-winding type: each circuit carries its own `alpha`. A
`PhaseShiftingTransformer3W` differs only by `α_\$suffix` per winding, so it translates as a
`Transformer3W`.
"""
translate(::Val{:PhaseShiftingTransformer3W}, raw::AbstractDict, ctx::TranslationContext) =
    translate(Val(:Transformer3W), raw, ctx)
