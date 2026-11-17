using PowerOperationsOpenAPIModels: TransformerCircuit, SwitchedAdmittance

_rb_bus(uuid, number) = Dict{String, Any}(
    "__metadata__" => Dict("type" => "ACBus"),
    "internal" => Dict("uuid" => Dict("value" => uuid)),
    "name" => "bus$number", "number" => number, "available" => true,
    "bustype" => "PQ", "angle" => 0.0, "magnitude" => 1.0,
    "voltage_limits" => Dict("min" => 0.9, "max" => 1.1), "base_voltage" => 230.0,
)

_rb_arc(uuid, from, to) = Dict{String, Any}(
    "__metadata__" => Dict("type" => "Arc"),
    "internal" => Dict("uuid" => Dict("value" => uuid)),
    "from" => Dict("value" => from), "to" => Dict("value" => to),
)

"""Buses 1-3 and an arc 1 → 2, indexed, with ids assigned to them and to `extra` UUIDs."""
function _rb_ctx(extra = String[])
    components = Any[
        _rb_bus("uuid-rb1", 1), _rb_bus("uuid-rb2", 2), _rb_bus("uuid-rb3", 3),
        _rb_arc("uuid-rb-arc", "uuid-rb1", "uuid-rb2"),
    ]
    led = PSU.Ledger()
    for uuid in vcat(["uuid-rb1", "uuid-rb2", "uuid-rb3", "uuid-rb-arc"], extra)
        PSU.assign_id!(led, uuid)
    end
    rep = PSU.ConversionReport()
    return PSU.TranslationContext(led, rep, 100.0, PSU.BusIndex(components)), components
end

function _rb_tap(number; objective = "VOLTAGE")
    ctx, _ = _rb_ctx(["uuid-rb-tap"])
    raw = Dict{String, Any}(
        "__metadata__" => Dict("type" => "TapTransformer"),
        "internal" => Dict("uuid" => Dict("value" => "uuid-rb-tap")),
        "name" => "tap", "available" => true,
        "arc" => Dict("value" => "uuid-rb-arc"),
        "r" => 0.01, "x" => 0.1, "tap" => 1.0, "rating" => 4.0, "base_power" => 100.0,
        "active_power_flow" => 0.0, "reactive_power_flow" => 0.0,
        "control_objective" => objective, "voltage_setpoint" => 1.02,
        "regulated_bus_number" => number,
    )
    circuit = only(filter(m -> m isa TransformerCircuit, PSU.translate_component(raw, ctx)))
    return circuit, ctx
end

@testset "transformer regulated_bus_number → regulated_bus + orientation" begin
    # An end of the arc: the connections give the direction.
    circuit, ctx = _rb_tap(2)
    @test circuit.regulated_bus == PSU.lookup_id(ctx.ledger, "uuid-rb2")
    @test string(circuit.regulated_bus_orientation) == "UNDEFINED"
    # A remote bus: PSS/E CONT's sign is the direction, positive the winding-two side.
    circuit, ctx = _rb_tap(3)
    @test circuit.regulated_bus == PSU.lookup_id(ctx.ledger, "uuid-rb3")
    @test string(circuit.regulated_bus_orientation) == "TO"
    circuit, _ = _rb_tap(-3)
    @test string(circuit.regulated_bus_orientation) == "FROM"
    # No regulated bus.
    circuit, _ = _rb_tap(0)
    @test circuit.regulated_bus isa PSU.ICOM.Absent
    # An objective that regulates no bus: kept in ext and reported, not written.
    circuit, ctx = _rb_tap(2; objective = "FIXED")
    @test circuit.regulated_bus isa PSU.ICOM.Absent
    @test ctx.report.unmapped_fields[("TapTransformer", "regulated_bus_number")] == 1
    @test PSU.unmapped_values(ctx.ledger, "uuid-rb-tap")["regulated_bus_number"] == 2
    # A number no bus has.
    @test_throws PSU.Psy5FormatError _rb_tap(99)
end

function _rb_shunt(number)
    ctx, _ = _rb_ctx(["uuid-rb-shunt"])
    raw = Dict{String, Any}(
        "__metadata__" => Dict("type" => "SwitchedAdmittance"),
        "internal" => Dict("uuid" => Dict("value" => "uuid-rb-shunt")),
        "name" => "shunt", "available" => true, "bus" => Dict("value" => "uuid-rb1"),
        "Y" => Dict("real" => 0.0, "imag" => 0.5), "initial_status" => [0],
        "number_of_steps" => [1], "Y_increase" => [Dict("real" => 0.0, "imag" => 0.1)],
        "admittance_limits" => Dict("min" => 0.95, "max" => 1.05),
        "control_mode" => "CONTINUOUS_VOLTAGE", "regulated_bus_number" => number,
        "dynamic_injector" => nothing, "services" => Any[], "ext" =>
            Dict{String, Any}(),
    )
    return only(PSU.translate_component(raw, ctx)), ctx
end

@testset "SwitchedAdmittance regulated_bus_number → remote_regulated_bus" begin
    shunt, ctx = _rb_shunt(3)
    @test shunt.remote_regulated_bus == PSU.lookup_id(ctx.ledger, "uuid-rb3")
    # Its own bus, or 0, is PSY6's unset remote bus (a value equal to `bus` is invalid).
    for number in (1, 0)
        shunt, _ = _rb_shunt(number)
        @test shunt.remote_regulated_bus isa PSU.ICOM.Absent
    end
end

@testset "VSC AC_VOLTAGE → remote_regulated_bus and the bus's voltage_setpoint" begin
    ctx, components = _rb_ctx()
    raw = Dict{String, Any}(
        "name" => "vsc", "arc" => Dict("value" => "uuid-rb-arc"),
        "ac_control_from" => "AC_VOLTAGE", "ac_setpoint_from" => 1.03,
        "remote_bus_control_from" => 3,
        "ac_control_to" => "AC_VOLTAGE", "ac_setpoint_to" => 1.01,
        "remote_bus_control_to" => 0,
    )
    derived = PSU._vsc_setpoints(raw, ctx)
    @test derived["remote_regulated_bus_from"] == PSU.lookup_id(ctx.ledger, "uuid-rb3")
    @test !haskey(derived, "remote_regulated_bus_to")
    @test !any(
        haskey(derived, k) for k in (
            "ac_setpoint_from", "ac_setpoint_to",
            "remote_bus_control_from", "remote_bus_control_to",
        )
    )
    # The remote bus takes the from setpoint, the to terminal bus its own.
    @test ctx.ledger.bus_voltage_setpoints["uuid-rb3"] == 1.03
    @test ctx.ledger.bus_voltage_setpoints["uuid-rb2"] == 1.01

    # A second, different setpoint for the same bus keeps the first and is reported.
    @test_logs (:warn, r"already set") PSU.record_bus_voltage_setpoint!(
        ctx, "uuid-rb3", 0.98, "test",
    )
    @test ctx.ledger.bus_voltage_setpoints["uuid-rb3"] == 1.03
    @test ctx.report.approximate_mappings[("ACBus", "voltage_setpoint")] == 1

    # The setpoints land on the buses once the document is assembled.
    doc = PSU.PCOM.SystemDocument()
    for bus in components[1:3]
        PSU.PCOM.add_component!(doc, only(PSU.translate_component(bus, ctx)))
    end
    doc = PSU._apply_bus_voltage_setpoints(doc, ctx.ledger)
    setpoints = Dict(b.number => b.voltage_setpoint for b in doc.components["ACBus"])
    @test setpoints[3] == 1.03
    @test setpoints[2] == 1.01
    @test setpoints[1] isa PSU.ICOM.Absent
end

@testset "VSC AC_VOLTAGE with a remote bus the case does not have" begin
    ctx, _ = _rb_ctx(["uuid-rb-vsc"])
    ctx.ledger.owner = "uuid-rb-vsc"
    raw = Dict{String, Any}(
        "name" => "vsc", "arc" => Dict("value" => "uuid-rb-arc"),
        "ac_control_from" => "AC_VOLTAGE", "ac_setpoint_from" => 1.03,
        "remote_bus_control_from" => 203,
        "ac_control_to" => "AC_REACTIVE_POWER", "ac_setpoint_to" => 0.95,
    )
    derived = PSU._vsc_setpoints(raw, ctx)
    # Dangling in the source: no remote bus, no setpoint moved anywhere, both kept and reported.
    @test !haskey(derived, "remote_regulated_bus_from")
    @test !haskey(derived, "ac_setpoint_from")
    @test isempty(ctx.ledger.bus_voltage_setpoints)
    for field in ("remote_bus_control_from", "ac_setpoint_from")
        @test ctx.report.dropped_invalid_values[("TwoTerminalVSCLine", field)] == 1
    end
    @test PSU.unmapped_values(ctx.ledger, "uuid-rb-vsc")["remote_bus_control_from"] == 203
end
