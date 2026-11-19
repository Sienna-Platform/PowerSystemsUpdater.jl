# Step 2 of the PSY5 -> PSY6 comparison: convert each PSY5 case with PowerSystemsUpdater into
# `<work_dir>/<case>/psy6_bundle/`, with the conversion report beside it.
#
#   julia --project=scripts/psy5_psy6_compare/psy6_env \
#       scripts/psy5_psy6_compare/psy6_env/convert.jl <work_dir> <case.json>...
#
# Deliberately loads only the updater, not PowerSystems: conversion must not depend on PSY6.

import JSON
using PowerSystemsUpdater

include(joinpath(@__DIR__, "..", "case_layout.jl"))

by_field(counts) = Dict("$type.$field" => n for ((type, field), n) in counts)

"""
The report's counts as plain dictionaries, for a step that does not load the updater.
"""
function report_counts(report::ConversionReport)
    return Dict(
        "unmapped_types" => report.unmapped_types,
        "cascaded_skips" => report.cascaded_skips,
        "unmapped_fields" => by_field(report.unmapped_fields),
        "unverified_units" => by_field(report.unverified_units),
        "dropped_dynamic_models" => report.dropped_dynamic_models,
        "dropped_invalid_values" => by_field(report.dropped_invalid_values),
        "approximate_mappings" => by_field(report.approximate_mappings),
        "schema_defaults" => by_field(report.schema_defaults),
        "psy5_defaults" => by_field(report.psy5_defaults),
    )
end

function main(args)
    work_dir, cases = parse_step_args(args)
    for case in cases
        run_case_step(work_dir, case, "convert") do dir
            result = convert_system(case, joinpath(dir, PSY6_BUNDLE); force = true)
            open(joinpath(dir, CONVERSION_REPORT), "w") do io
                show(io, MIME("text/plain"), result.report)
            end
            open(joinpath(dir, CONVERSION_REPORT_JSON), "w") do io
                JSON.json(io, report_counts(result.report); pretty = true)
            end
        end
    end
end

main(ARGS)
