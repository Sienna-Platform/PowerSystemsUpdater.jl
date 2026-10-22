"""
PSY5 keys that never become PSY6 properties on the entity itself. `services` is carried
separately as `ServiceAssociation` rows (`_add_service_associations!` in convert.jl), not as
a field on the component; `ext` is carried in the document's own `ext` table, keyed by
component id (`_carry_ext!` in convert.jl), which is also where any PSY5 field with no PSY6
counterpart is kept (under `UNMAPPED_EXT_KEY`); `internal` and `__metadata__` are
serialization scaffolding.
"""
const PSY5_INTERNAL_FIELDS = Set(["__metadata__", "internal", "services", "ext"])

"""
PSY5 fields linking a static device to its dynamic model (`DynamicGenerator`,
`DynamicInverter`, ...). The 0.2 schema has no dynamic models, so the updater skips them; the
link is dropped and the static device kept, rather than the device being skipped with its
model. Each dropped link is recorded on the report (`record_dropped_dynamic_model!`).
"""
const DYNAMIC_REFERENCE_FIELDS = Set(["dynamic_injector"])

struct SkippedReferenceSignal <: Exception
    msg::String
end

Base.showerror(io::IO, e::SkippedReferenceSignal) =
    print(io, "SkippedReferenceSignal: ", e.msg)

"""
PSY5 type name -> (PSY6 discriminator property, discriminator value). PSY5 has no such
field; the value comes from `__metadata__.type`, not a formula on the name.
"""
const ONEOF_DISCRIMINATORS = Dict{String, Tuple{Symbol, String}}(
    "CostCurve" => (:variable_cost_type, "COST"),
    "FuelCurve" => (:variable_cost_type, "FUEL"),
    "InputOutputCurve" => (:curve_type, "INPUT_OUTPUT"),
    "IncrementalCurve" => (:curve_type, "INCREMENTAL"),
    "AverageRateCurve" => (:curve_type, "AVERAGE_RATE"),
    "LinearFunctionData" => (:function_type, "LINEAR"),
    "QuadraticFunctionData" => (:function_type, "QUADRATIC"),
    "PiecewiseLinearData" => (:function_type, "PIECEWISE_LINEAR"),
    "PiecewiseStepData" => (:function_type, "PIECEWISE_STEP"),
    "RenewableGenerationCost" => (:cost_type, "RENEWABLE"),
    "ThermalGenerationCost" => (:cost_type, "THERMAL"),
    "HydroGenerationCost" => (:cost_type, "HYDRO_GEN"),
    "StorageCost" => (:cost_type, "STORAGE"),
    "LoadCost" => (:cost_type, "LOAD"),
    "MarketBidCost" => (:cost_type, "MARKET_BID"),
    "HydroReservoirCost" => (:cost_type, "HYDRO_RES"),
    "ImportExportCost" => (:cost_type, "IMPORTEXPORT"),
)

function _psy5_type_name(dict::AbstractDict)
    metadata = get(dict, "__metadata__", nothing)
    if isnothing(metadata)
        return nothing
    end
    return get(metadata, "type", nothing)
end

"""
`StartUpStages` carries no `__metadata__` tag in PSY5, so it is detected by its unique
key set instead, the same way `is_reference` classifies by shape rather than by tag.
"""
_is_start_up_stages_shape(dict::AbstractDict) =
    Set(keys(dict)) == Set(("hot", "warm", "cold"))

"""
PSY5 sometimes embeds a time series key in a value field. Where PSY6 has a field that names
the series instead (`SERIES_REF_FIELDS`), the key is carried across as that series'
association id. Anywhere else, dropping it would yield a document that validates while having
lost data nothing downstream could recover, so this errors instead.
"""
const TIME_SERIES_POINTER_TYPES = Set(["ForecastKey", "StaticTimeSeriesKey"])

"""
PSY5 fields that may hold a time series key, by owner type, and the PSY6 field that names the
series by association id in its place.
"""
const SERIES_REF_FIELDS = Dict{Tuple{String, String}, String}(
    ("FuelCurve", "fuel_cost") => "fuel_cost_time_series",
)

"""
`value` with each embedded time series key that PSY6 can name (`SERIES_REF_FIELDS`) moved to
its PSY6 field as a placeholder association id, deferred on `ledger` until the catalog exists.
"""
function _defer_series_refs(
    value::AbstractDict,
    owner_type::Union{Nothing, AbstractString},
    ledger::Ledger,
)
    deferred = value
    for (key, v) in value
        target = get(SERIES_REF_FIELDS, (something(owner_type, ""), key), nothing)
        if isnothing(target) || isnothing(_time_series_pointer_type(v))
            continue
        end
        deferred = deferred === value ? Dict{String, Any}(value) : deferred
        delete!(deferred, key)
        deferred[target] = defer_series_ref!(ledger, v)
    end
    return deferred
end

_time_series_pointer_type(::Any) = nothing
function _time_series_pointer_type(value::AbstractDict)
    type_name = _psy5_type_name(value)
    if isnothing(type_name) || !(type_name in TIME_SERIES_POINTER_TYPES)
        return nothing
    end
    return type_name
end

function _owner_label(owner_type::Union{Nothing, AbstractString})
    if isnothing(owner_type)
        return "<unknown type>"
    end
    return owner_type
end

"""
Throws `Psy5FormatError` if any immediate child of `value` is a time-series pointer.
`owner_type` is `value`'s own PSY5 type name, so the message names the field as
`Owner.field`.
"""
function _check_no_time_series_pointers!(
    value::AbstractDict,
    owner_type::Union{Nothing, AbstractString},
)
    for (key, v) in value
        pointer_type = _time_series_pointer_type(v)
        if !isnothing(pointer_type)
            throw(
                Psy5FormatError(
                    "$(_owner_label(owner_type)).$key holds an embedded $pointer_type; " *
                    "the updater does not yet carry a time series reference in this field",
                ),
            )
        end
    end
    return nothing
end

"""
PSY5 permits `MarketBidCost.shut_down` to be a bare scalar; PSY6 types it as a concrete
`InputOutputCurve`. The schema sanctions this promotion: the field's `description`
documents the "legacy scalar promotion", and its `default` gives exactly the
`InputOutputCurve`/`LinearFunctionData` shape built here (`Core/common.json`). Promotes the
scalar `s` into a constant function (`proportional_term = 0.0`, i.e. the multiplier, so the
curve's value is just `s`) rather than dropping it — PSY5's use of 0.0 here is a real "no
extra cost" curve, not a missing value. Built as a raw PSY5-shaped nested dict so the
promoted curve goes through the ordinary `ONEOF_DISCRIMINATORS` injection on the recursive
pass right after, instead of a second, hand-rolled discriminator mechanism.

PSY5's `no_load_cost` is NOT included here: PSY6's counterpart field is
`minimum_energy_offer` (a \$/MWh curve, not the same physical quantity), and the schema
documents the conversion as `minimum_energy_offer = no_load_cost / P_min` — P_min lives on
the owning generator, not on this cost object, so the division cannot be done from here.
Promoting the bare scalar into a curve without that division would silently mislabel a \$/h
value as \$/MWh. Left unmapped and recorded on the report instead of forced.

`minimum_energy_offer` is separately defaulted below (`MARKET_BID_COST_DEFAULTED_FIELDS`)
whenever PSY5 supplies no value at all: the field is required on the PSY6 struct, and
`Core/common.json` documents this exact zero-cost shape as its schema `default` — the same
default a codegen consumer without vendor extensions would fall back to.
"""
const MARKET_BID_COST_SCALAR_FIELDS = Set(["shut_down"])

_is_scalar_cost(::Real) = true
_is_scalar_cost(::Any) = false

function _zero_cost_curve()
    return Dict{String, Any}(
        "__metadata__" => Dict("type" => "InputOutputCurve"),
        "input_at_zero" => nothing,
        "function_data" => Dict{String, Any}(
            "__metadata__" => Dict("type" => "LinearFunctionData"),
            "constant_term" => 0.0,
            "proportional_term" => 0.0,
        ),
    )
end

"""
The empty offer curve, mirroring PSY6's own `ZERO_OFFER_CURVE`
(`PowerSystems/src/models/cost_functions/MarketBidCost.jl`): a `CostCurve` over a
`PiecewiseIncrementalCurve(0.0, [0.0, 0.0], [0.0])` in natural units with zero VOM. Unlike
the fields above, `Core/common.json` documents no `default` here, so the sanction is PSY's
constructor default rather than the schema's — the same value any PSY6 caller that omits the
field already gets.
"""
function _zero_offer_curve()
    return Dict{String, Any}(
        "__metadata__" => Dict("type" => "CostCurve"),
        "power_units" => "NATURAL_UNITS",
        "vom_cost" => _zero_cost_curve(),
        "value_curve" => Dict{String, Any}(
            "__metadata__" => Dict("type" => "IncrementalCurve"),
            "input_at_zero" => nothing,
            "initial_input" => 0.0,
            "function_data" => Dict{String, Any}(
                "__metadata__" => Dict("type" => "PiecewiseStepData"),
                "x_coords" => [0.0, 0.0],
                "y_coords" => [0.0],
            ),
        ),
    )
end

"""
PSY6 required fields with no PSY5 counterpart, mapped to the builder for the zero-cost value
that stands in. Unlike `MARKET_BID_COST_SCALAR_FIELDS` this is not a promotion of PSY5 data —
PSY5 either has no field here at all or writes an explicit `null` — so it only applies when
the value is missing, never overwriting one PSY5 did supply.
"""
const MARKET_BID_COST_DEFAULTED_FIELDS = Dict{String, Function}(
    "minimum_energy_offer" => _zero_cost_curve,
    "incremental_offer_curves" => _zero_offer_curve,
    "decremental_offer_curves" => _zero_offer_curve,
)

function _promote_market_bid_cost_scalar(scalar::Real)
    return Dict{String, Any}(
        "__metadata__" => Dict("type" => "InputOutputCurve"),
        "input_at_zero" => nothing,
        "function_data" => Dict{String, Any}(
            "__metadata__" => Dict("type" => "LinearFunctionData"),
            "constant_term" => scalar,
            "proportional_term" => 0.0,
        ),
    )
end

function _promote_market_bid_cost_scalars(
    value::AbstractDict,
    owner_type::Union{Nothing, AbstractString},
)
    if owner_type != "MarketBidCost"
        return value
    end
    promoted = value
    for field in MARKET_BID_COST_SCALAR_FIELDS
        scalar = get(value, field, nothing)
        if _is_scalar_cost(scalar)
            if promoted === value
                promoted = copy(value)
            end
            promoted[field] = _promote_market_bid_cost_scalar(scalar)
        end
    end
    for (field, zero_value) in MARKET_BID_COST_DEFAULTED_FIELDS
        if !haskey(promoted, field) || isnothing(promoted[field])
            if promoted === value
                promoted = copy(value)
            end
            promoted[field] = zero_value()
        end
    end
    return promoted
end

"""
PSY5 spells the variable cost field `variable` on these four cost types; PSY6 spells it
`variable_operation_cost`. Renamed before the generic recursive copy so it routes through
the ordinary field-copy path instead of recording an unmapped field and leaving the
required `variable_operation_cost` absent.
"""
const VARIABLE_OPERATION_COST_TYPES = Set([
    "ThermalGenerationCost", "HydroGenerationCost", "RenewableGenerationCost",
    "LoadCost",
])

function _rename_variable_operation_cost(
    value::AbstractDict,
    owner_type::Union{Nothing, AbstractString},
)
    if isnothing(owner_type) || !(owner_type in VARIABLE_OPERATION_COST_TYPES) ||
       !haskey(value, "variable")
        return value
    end
    renamed = copy(value)
    renamed["variable_operation_cost"] = pop!(renamed, "variable")
    return renamed
end

translate_value(value, ::Ledger, ::ConversionReport) = value

"""
Record every key on a resolved nested composite (`type_name` from `__metadata__.type`, or
`"StartUpStages"` for the untagged shape) that is not one of `ICOM.model_type(type_name)`'s
fieldnames — the nested analogue of `build_kwargs`'s unmapped-field guard. The value is kept
for the owning component's `ext` as `Type.field` (`keep_unmapped!`).

Only fires when `type_name` resolves to a registered PSY6 model; an unresolved nested dict
(no `__metadata__.type`, or a PSY5 type with no PSY6 counterpart) is forwarded unchanged, as
before, with nothing to check its keys against. `__metadata__` itself is never flagged: the
schemas allow the extra key.
"""
function _record_unmapped_nested_fields!(
    translated::AbstractDict,
    type_name::Union{Nothing, AbstractString},
    ledger::Ledger,
    report::ConversionReport,
)
    if isnothing(type_name) || !ICOM.has_model_type(type_name)
        return nothing
    end
    targets = Set(fieldnames(ICOM.model_type(type_name)))
    for key in keys(translated)
        if key == "__metadata__"
            continue
        end
        if !(Symbol(key) in targets)
            record_unmapped_field!(report, type_name, key)
            keep_unmapped!(ledger, "$type_name.$key", translated[key])
        end
    end
    return nothing
end

"""
PSY5 spells the per-unit basis `DEVICE_BASE`; PSY6's `UnitSystem` enum only has
`COMPONENT_BASE`/`NATURAL_UNITS`. Normalizes a nested `power_units` key (`CostCurve`,
`LossCurve`, …) wherever one is found on a translated dict — the top-level component
`power_units` bypasses this entirely, since `direct_translate` always sets it directly to
`"COMPONENT_BASE"`.
"""
function _normalize_power_units(value::AbstractString)
    if value == "DEVICE_BASE"
        return "COMPONENT_BASE"
    end
    return value
end

_normalize_power_units(value) = value

"""
Non-reference dicts are forwarded recursively rather than verbatim, so a nested `oneOf`
(a `CostCurve` containing a `ValueCurve` containing `FunctionData`) gets its discriminator
at every level in one pass. `__metadata__` is left in place: the schemas allow the extra key.

A key whose PSY5 value is `nothing` is dropped rather than forwarded as JSON `null`, matching
`build_kwargs`'s top-level behavior: PSY6 optional fields (`input_at_zero`, and similar) are
typed without `null`, so a present-but-null key fails schema validation where an absent key
decodes to `ABSENT`.

Every resolved nested composite is also checked against its PSY6 fieldnames
(`_record_unmapped_nested_fields!`), the same guard `build_kwargs` applies at the top level —
otherwise a PSY5 field with no PSY6 counterpart inside a nested object (for example
`FuelCurve.startup_fuel_offtake`) would be forwarded into the output silently instead of
being recorded as a finding.
"""
function translate_value(value::AbstractDict, ledger::Ledger, report::ConversionReport)
    if is_reference(value)
        return lookup_id(ledger, reference_uuid(value))
    end
    owner_type = _psy5_type_name(value)
    value = _defer_series_refs(value, owner_type, ledger)
    _check_no_time_series_pointers!(value, owner_type)
    promoted = _promote_market_bid_cost_scalars(value, owner_type)
    promoted = _rename_variable_operation_cost(promoted, owner_type)
    translated = Dict{String, Any}(
        key => translate_value(v, ledger, report) for
        (key, v) in promoted if !isnothing(v)
    )
    if haskey(translated, "power_units")
        translated["power_units"] = _normalize_power_units(translated["power_units"])
    end
    type_name = _psy5_type_name(translated)
    if !isnothing(type_name) && haskey(ONEOF_DISCRIMINATORS, type_name)
        property, discriminator_value = ONEOF_DISCRIMINATORS[type_name]
        translated[string(property)] = discriminator_value
    elseif isnothing(type_name) && _is_start_up_stages_shape(translated)
        type_name = "StartUpStages"
        translated["startup_stages_type"] = "STAGES"
    end
    _record_unmapped_nested_fields!(translated, type_name, ledger, report)
    return translated
end

function translate_value(value::AbstractVector, ledger::Ledger, report::ConversionReport)
    return [translate_value(v, ledger, report) for v in value]
end

"""
True when any reference on `raw` points at a component that was skipped. Such a component
must itself be skipped: `validate_document` does not check ordinary component references,
so a dangling integer would otherwise reach the output. A link to a dynamic model
(`DYNAMIC_REFERENCE_FIELDS`) is not such a reference: it is never written, so the device
does not depend on its model.
"""
function references_skipped(raw::AbstractDict, ledger::Ledger)
    for (key, value) in raw
        if key in PSY5_INTERNAL_FIELDS || key in DYNAMIC_REFERENCE_FIELDS
            continue
        end
        if _points_at_skipped(value, ledger)
            return true
        end
    end
    return false
end

_points_at_skipped(::Any, ::Ledger) = false

function _points_at_skipped(value::AbstractDict, ledger::Ledger)
    if is_reference(value)
        return is_skipped(ledger, reference_uuid(value))
    end
    return false
end

function _points_at_skipped(value::AbstractVector, ledger::Ledger)
    return any(v -> _points_at_skipped(v, ledger), value)
end

"""
Decode every value in `kwargs` against `T`'s own declared field type.

The PSY5->PSY6 translation pipeline stages plain Julia values — JSON-shaped nested `Dict`s
built by [`translate_value`](@ref), bare enum spellings as `String` (`"COMPONENT_BASE"`,
`"UP"`, ...), resolved reference ids as `Int` — that the OpenAPI 1.1 generator's strictly
typed, immutable structs do not accept as-is: the old 0.2 generator's untyped fields
tolerated them, but a field like `power_units::UnitSystem` or `shut_down::InputOutputCurve`
now rejects a bare `String`/`Dict` with a `MethodError`. `ICOM.decode` is the generated
packages' public entry point for this (the runtime's `_decode`, under the name every consumer
is meant to call), so this routes every hand-built kwarg through the one path that already
knows how to turn a raw value into `T`'s declared type, whatever shape that type is.
"""
function _decode_kwargs(::Type{T}, kwargs::AbstractDict{Symbol}) where {T <: ICOM.APIModel}
    return Dict{Symbol, Any}(
        key => ICOM.decode(fieldtype(T, key), value) for (key, value) in kwargs
    )
end

"""
PSY5 spells the initial commitment state as a plain `Bool` on the device types that carry a
`status` field of PSY6's `OperationalStates` enum (`ThermalStandard`, `ThermalMultiStart`,
`HybridSystem`, `HydroDispatch`, `HydroTurbine`; `HydroPumpTurbine`'s `status` key means
something else — see its own `translate` method). PSY5 has no STARTUP/SHUTDOWN concept, so
`true`/`false` map onto the two states it can express.
"""
function _operational_state(status::Bool)
    if status
        return "ONLINE"
    end
    return "OFFLINE"
end

"""
Whether `value` is a base voltage no physical device has: a transformer winding's
(`base_voltage_primary`, `_secondary`, ...) or a VSC line's `rated_dc_voltage`. PSY5 accepted
`0.0` (a source that records none, e.g. some MATPOWER cases and `c_sys14_hvdc_vsc`); PSY6
requires a positive base. The fields are optional in the schema, so the value is left unset
(`build_kwargs`) and recorded on the report; a field PSY5 stored relative to it is left unset
the same way (`NonPhysicalBase`).

A bus's `base_voltage` is not included: PowerSystems 6's `Line` endpoint check subtracts the
two buses' base voltages without allowing for an unset one, so a bus base of 0 is written as
stored, which PSY6 accepts.
"""
_non_physical_base(key::AbstractString, value::Real) =
    (startswith(key, "base_voltage_") || key == "rated_dc_voltage") && value <= 0
_non_physical_base(::AbstractString, ::Any) = false

_is_bool(::Bool) = true
_is_bool(::Any) = false

"""
Build the keyword arguments for `T` from a PSY5 component dict.

Copies by name for every field `T` declares, resolving UUID references to integer ids. PSY5
keys with no counterpart on `T` are recorded on `report` rather than dropped silently — an
unmapped field is a finding about the schemas.

With `units`, each value is first converted from how PSY5 stored it into the unit the schema
declares for it (`convert_units` in translate/units.jl), and any unit-basis field the
conversion chose is written (`admittance_units = COMPONENT_MVAR`, ...). Without it, values are
copied as stored.
"""
function build_kwargs(
    ::Type{T},
    raw::AbstractDict,
    ledger::Ledger,
    report::ConversionReport;
    extra::AbstractDict = Dict{Symbol, Any}(),
    units::Union{Nothing, ComponentUnits} = nothing,
) where {T <: ICOM.APIModel}
    targets = Set(fieldnames(T))
    kwargs = Dict{Symbol, Any}()
    type_name = component_type(raw)
    for (key, value) in raw
        if key in PSY5_INTERNAL_FIELDS
            continue
        end
        if key in DYNAMIC_REFERENCE_FIELDS
            # The dynamic model is skipped (no 0.2 schema home); never write a link to it.
            if !isnothing(value)
                record_dropped_dynamic_model!(report, type_name)
            end
            continue
        end
        symbol = Symbol(key)
        if !(symbol in targets)
            record_unmapped_field!(report, type_name, key)
            keep_unmapped!(ledger, key, value)
            continue
        end
        if isnothing(value)
            continue
        end
        if _non_physical_base(key, value)
            record_dropped_invalid_value!(report, type_name, key)
            keep_unmapped!(ledger, key, value)
            continue
        end
        if symbol === :status && _is_bool(value)
            kwargs[symbol] = _operational_state(value)
            continue
        end
        value, write =
            _in_declared_units(T, symbol, key, value, units, kwargs, ledger, report)
        if write
            kwargs[symbol] = translate_value(value, ledger, report)
        end
    end
    for (key, value) in extra
        kwargs[key] = value
    end
    return _decode_kwargs(T, kwargs)
end

_in_declared_units(::Type, ::Symbol, ::AbstractString, value, ::Nothing, args...) =
    (value, true)

"""
`value` converted into the unit `T` declares for `field`, and whether to write it. A unit
basis the conversion chose is written into `kwargs`. A value that could not be converted is
reported; an optional field is then left unset with the PSY5 value kept in `ext`, while a
required one is written as PSY5 stored it.
"""
function _in_declared_units(
    ::Type{T},
    field::Symbol,
    key::AbstractString,
    value,
    units::ComponentUnits,
    kwargs::AbstractDict,
    ledger::Ledger,
    report::ConversionReport,
) where {T}
    unit, basis = target_unit(T, field, units.raw)
    if !isnothing(basis) && !haskey(kwargs, first(basis))
        kwargs[first(basis)] = last(basis)
    end
    converted = convert_units(psy5_storage(units.psy5_type, key), unit, value, units)
    return _settle(converted, T, field, key, value, units, ledger, report)
end

_settle(converted, ::Type, ::Symbol, ::AbstractString, _, ::ComponentUnits, args...) =
    (converted, true)

function _settle(
    ::UnverifiedUnit,
    ::Type{T},
    field::Symbol,
    key::AbstractString,
    value,
    units::ComponentUnits,
    ledger::Ledger,
    report::ConversionReport,
) where {T}
    record_unverified_unit!(report, units.psy5_type, key)
    if _may_leave_unset(T, field, key)
        keep_unmapped!(ledger, key, value)
        return (nothing, false)
    end
    return (value, true)
end

"""
A value whose PSY5 base is non-physical (`NonPhysicalBase`): a data problem in the source,
reported under INVALID VALUES DROPPED. An optional field is left unset with the PSY5 value kept
in `ext`; a required one is written as PSY5 stored it, so the document stays valid and PSY6
reports the same data problem on import.
"""
function _settle(
    ::NonPhysicalBase,
    ::Type{T},
    field::Symbol,
    key::AbstractString,
    value,
    units::ComponentUnits,
    ledger::Ledger,
    report::ConversionReport,
) where {T}
    record_dropped_invalid_value!(report, units.psy5_type, key)
    if _may_leave_unset(T, field, key)
        keep_unmapped!(ledger, key, value)
        return (nothing, false)
    end
    return (value, true)
end

"""
Fields the schema requires only in some states, which their declared type cannot show: a VSC
converter's setpoint is optional, but required for the quantity its control mode selects, and
`_vsc_setpoints` writes only that one (`VSC_SETPOINT_FIELDS`).
"""
const CONDITIONALLY_REQUIRED_FIELDS = Set([
    "dc_power_setpoint_from", "dc_power_setpoint_to",
    "dc_voltage_setpoint_from", "dc_voltage_setpoint_to",
    "ac_voltage_setpoint_from", "ac_voltage_setpoint_to",
    "power_factor_setpoint_from", "power_factor_setpoint_to",
])

"""Whether a value that could not be converted may be left unset rather than written."""
_may_leave_unset(::Type{T}, field::Symbol, key::AbstractString) where {T} =
    _accepts_absent(fieldtype(T, field)) && !(key in CONDITIONALLY_REQUIRED_FIELDS)

"""
Whether a model field may be left unset: the generator types optional fields as a union with
`Absent`. A query on the field's declared type, not on a value.
"""
_accepts_absent(field_type::Type) =
    typeintersect(field_type, OpenAPI.Runtime.Absent) !== Union{}
