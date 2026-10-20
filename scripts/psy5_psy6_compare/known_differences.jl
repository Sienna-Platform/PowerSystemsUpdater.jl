# The PSY5 -> PSY6 breaking changes the comparison accepts. Everything here is an intended
# difference between the data models; anything the comparison finds that is not covered here
# is reported as unexpected and fails the case.
#
# Written from the release's documented changes
# (docs/src/explanation/psy5_to_psy6_component_changes.md), deliberately NOT derived from
# PowerSystemsUpdater's own translation tables: an oracle built from the code under test would
# agree with every bug in it.
#
# Two kinds of entry:
#   - `TYPE_MAPPINGS` say where a PSY5 component lives in PSY6 and how to line its PSY6 record
#     up with the PSY5 one, so the rest of the comparison is field-for-field.
#   - `EXPECTED` marks individual differences as intended, matched by kind, PSY5 type and
#     field path. `*` in any pattern matches any run of characters.

"""
Where a PSY5 type lives in PSY6.

  - `psy6_type`: the PSY6 type label.
  - `flatten`: PSY6 fields holding a nested struct whose fields are lifted to the top level
    before comparing (e.g. a transformer's `circuit`).
  - `renames`: PSY6 field name => the PSY5 field name it is compared against.
"""
struct TypeMapping
    psy6_type::String
    flatten::Vector{String}
    renames::Dict{String, String}
end

function TypeMapping(
    psy6_type::String;
    flatten = String[],
    renames = Dict{String, String}(),
)
    return TypeMapping(psy6_type, flatten, renames)
end

const TWO_WINDING = TypeMapping(
    "TwoWindingTransformer";
    flatten = ["circuit"],
    renames = Dict("magnetizing_shunt" => "primary_shunt"),
)

const TYPE_MAPPINGS = Dict{String, TypeMapping}(
    "Transformer2W" => TWO_WINDING,
    "TapTransformer" => TWO_WINDING,
    "PhaseShiftingTransformer" => TWO_WINDING,
    # Three circuits rather than one, so no single flatten lines it up; its per-winding
    # fields are compared as missing/extra until a dedicated mapping is written.
    "Transformer3W" => TypeMapping("ThreeWindingTransformer"),
    "ConstantReserve{ReserveUp}" => TypeMapping("OnlineReserve"),
    "ConstantReserve{ReserveDown}" => TypeMapping("OnlineReserve"),
    "ConstantReserve{ReserveSymmetric}" => TypeMapping("OnlineReserve"),
    "VariableReserve{ReserveUp}" => TypeMapping("OnlineReserve"),
    "VariableReserve{ReserveDown}" => TypeMapping("OnlineReserve"),
    "VariableReserve{ReserveSymmetric}" => TypeMapping("OnlineReserve"),
    "ConstantReserveNonSpinning" => TypeMapping("OfflineReserve"),
    "VariableReserveNonSpinning" => TypeMapping("OfflineReserve"),
    "ConstantReserveGroup{ReserveUp}" => TypeMapping("GroupReserve"),
    "ConstantReserveGroup{ReserveDown}" => TypeMapping("GroupReserve"),
    "ConstantReserveGroup{ReserveSymmetric}" => TypeMapping("GroupReserve"),
)

type_mapping(psy5_type::AbstractString) =
    get(() -> TypeMapping(String(psy5_type)), TYPE_MAPPINGS, psy5_type)

"""
An intended difference. `kind` is one of the `Difference` kinds in `compare.jl`; `psy5_type`
and `path` are glob patterns; `reason` is shown in the report.
"""
struct Expected
    kind::String
    psy5_type::String
    path::String
    reason::String
end

const EXPECTED = Expected[
    # Transformers
    Expected(
        "missing_field",
        "Transformer2W",
        "winding_group_number",
        "PSY6 drops WindingGroupNumber; the angle survives as circuit α",
    ),
    Expected(
        "missing_field",
        "TapTransformer",
        "winding_group_number",
        "PSY6 drops WindingGroupNumber; the angle survives as circuit α",
    ),
    Expected(
        "missing_field",
        "TapTransformer",
        "tap_limits",
        "dropped in PSY6 without a replacement",
    ),
    Expected(
        "missing_field",
        "TapTransformer",
        "voltage_setpoint",
        "dropped in PSY6 without a replacement",
    ),
    Expected(
        "missing_field",
        "Transformer3W",
        "available",
        "Transformer3W availability is per-circuit in PSY6",
    ),
    Expected(
        "missing_field",
        "Transformer3W",
        "rating",
        "Transformer3W rating is per-circuit in PSY6",
    ),
]

"""
Differences that are recorded and reported but never fail a case:

  - `extra_field`: a field PSY6 added with a default is new information, not a change to
    anything PSY5 held. A field that was *renamed* still fails, because its PSY5 side shows up
    as `missing_field`.
  - `unreadable_both`: the snapshot could read the value on neither side (e.g. `horizon` of a
    `SingleTimeSeries`), so there is nothing to compare.
"""
const INFORMATIONAL_KINDS = Set(["extra_field", "unreadable_both"])

"""
Relative and absolute tolerance for numeric values. Loose enough for per-unit conversions done
in a different order on each side, tight enough to catch a wrong base.
"""
const RTOL = 1e-8
const ATOL = 1e-10
