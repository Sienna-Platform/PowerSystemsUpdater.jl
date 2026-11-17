# Where each step reads and writes, shared by the step scripts and the driver:
#
#   <work_dir>/
#       run.log                   full output of each run.jl run
#       summary.md                step 4, totals and one row per case
#       <case>/
#           psy5_snapshot.json    step 1
#           psy5_values.h5        step 1, time series values, one dataset per series
#           psy6_bundle/          step 2, the updater's output
#           conversion_report.txt step 2, the updater's ConversionReport as it prints
#           conversion_report.json step 2, its counts, for comparison.md
#           psy6_snapshot.json    step 3
#           psy6_values.h5        step 3
#           comparison.md         step 4, human-readable diff
#           diffs.json            step 4, every classified difference
#           <step>_error.txt      written instead when a step throws for this case

const PSY5_SNAPSHOT = "psy5_snapshot.json"
const PSY5_VALUES = "psy5_values.h5"
const PSY6_BUNDLE = "psy6_bundle"
const CONVERSION_REPORT = "conversion_report.txt"
const CONVERSION_REPORT_JSON = "conversion_report.json"
const PSY6_SNAPSHOT = "psy6_snapshot.json"
const PSY6_VALUES = "psy6_values.h5"
const COMPARISON_REPORT = "comparison.md"
const COMPARISON_DIFFS = "diffs.json"
const RUN_LOG = "run.log"
const SUMMARY = "summary.md"

const STEP_OUTPUTS = Dict(
    "psy5_snapshot" => [PSY5_SNAPSHOT, PSY5_VALUES],
    "convert" => [PSY6_BUNDLE, CONVERSION_REPORT, CONVERSION_REPORT_JSON],
    "psy6_snapshot" => [PSY6_SNAPSHOT, PSY6_VALUES],
    "compare" => [COMPARISON_REPORT, COMPARISON_DIFFS],
)

# The steps whose outputs go stale when a step re-runs.
const STEP_DEPENDENTS = Dict(
    "psy5_snapshot" => ["compare"],
    "convert" => ["psy6_snapshot", "compare"],
    "psy6_snapshot" => ["compare"],
    "compare" => String[],
)

case_name(case::AbstractString) = splitext(basename(case))[1]
case_dir(work_dir::AbstractString, case::AbstractString) =
    joinpath(work_dir, case_name(case))
error_file(step::AbstractString) = "$(step)_error.txt"

function parse_step_args(args)
    if length(args) < 2
        error("usage: <work_dir> <case>...")
    end
    return abspath(args[1]), abspath.(args[2:end])
end

"""
Remove the outputs and error files `step` and its dependents left in `dir` on an earlier run,
so a step that fails now cannot leave stale outputs for the next step to read.
"""
function clear_step!(dir::AbstractString, step::AbstractString)
    for s in (step, STEP_DEPENDENTS[step]...)
        for output in (STEP_OUTPUTS[s]..., error_file(s))
            rm(joinpath(dir, output); force = true, recursive = true)
        end
    end
end

"""
Run one step for one case in its directory. A failure goes to `<step>_error.txt` and the batch
moves on.
"""
function run_case_step(
    f,
    work_dir::AbstractString,
    case::AbstractString,
    step::AbstractString,
)
    dir = case_dir(work_dir, case)
    mkpath(dir)
    clear_step!(dir, step)
    err = joinpath(dir, error_file(step))
    @info step case = case_name(case)
    try
        f(dir)
        return true
    catch e
        open(err, "w") do io
            showerror(io, e, catch_backtrace())
        end
        println(stderr, "ERROR $step $(case_name(case)): ", first_error_line(err))
        return false
    end
end

function first_error_line(path::AbstractString)
    for line in eachline(path)
        if !isempty(strip(line))
            return first(strip(line), 200)
        end
    end
    return "(empty error file)"
end
