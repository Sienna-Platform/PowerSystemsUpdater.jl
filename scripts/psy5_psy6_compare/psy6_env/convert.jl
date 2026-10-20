# Step 2 of the PSY5 -> PSY6 comparison: run PowerSystemsUpdater on each PSY5 case, writing
# the PSY6 bundle to `<work_dir>/<case>/psy6_bundle/` and the conversion report beside it.
#
#   julia --project=scripts/psy5_psy6_compare/psy6_env \
#       scripts/psy5_psy6_compare/psy6_env/convert.jl <work_dir> <case.json>...
#
# Deliberately loads only the updater, not PowerSystems: conversion must not depend on PSY6.

import JSON
using PowerSystemsUpdater

include(joinpath(@__DIR__, "..", "case_layout.jl"))

"""
The report's counts in a form the comparison step can read without loading the updater.
"""
function report_counts(report::ConversionReport)
    return Dict(
        "unmapped_types" => report.unmapped_types,
        "cascaded_skips" => report.cascaded_skips,
        "unmapped_fields" =>
            Dict("$type.$field" => n for ((type, field), n) in report.unmapped_fields),
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
