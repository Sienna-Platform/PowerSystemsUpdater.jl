# Where each step of the comparison reads and writes, shared by every step script and the
# driver. Every case gets its own directory under the work directory:
#
#   <work_dir>/
#       run.log                  everything each run.jl printed, appended per run
#       summary.md               step 4, one row per case
#       <case>/
#           psy5_snapshot.json     step 1, PSY5 env
#           psy5_values.h5         step 1, every time series' values, one dataset per series
#           psy6_bundle/           step 2, the updater's output (system.json + time_series.h5)
#           conversion_report.txt  step 2, the updater's ConversionReport, as it prints
#           conversion_report.json step 2, the same counts, for the comparison report
#           psy6_snapshot.json     step 3, PSY6 env
#           psy6_values.h5         step 3, as psy5_values.h5
#           comparison.md          step 4, human-readable diff
#           diffs.json             step 4, every difference, machine-readable
#           <step>_error.txt       written instead when a step throws for this case

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

"""
What each step writes into a case directory.
"""
const STEP_OUTPUTS = Dict(
    "psy5_snapshot" => [PSY5_SNAPSHOT, PSY5_VALUES],
    "convert" => [PSY6_BUNDLE, CONVERSION_REPORT, CONVERSION_REPORT_JSON],
    "psy6_snapshot" => [PSY6_SNAPSHOT, PSY6_VALUES],
    "compare" => [COMPARISON_REPORT, COMPARISON_DIFFS],
)

"""
The steps whose outputs are built from each step's, and so go stale when it re-runs.
"""
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
Remove what `step` and every step downstream of it left in `dir` on an earlier run, outputs
and error files alike. Without this, a step that fails this run leaves the last run's outputs
in place, and the steps after it would read them as current.
"""
function clear_step!(dir::AbstractString, step::AbstractString)
    for s in (step, STEP_DEPENDENTS[step]...)
        for output in (STEP_OUTPUTS[s]..., error_file(s))
            rm(joinpath(dir, output); force = true, recursive = true)
        end
    end
end

"""
Run one step for one case in that case's directory. A failure is written to
`<step>_error.txt` and logged, and the batch moves on to the next case.
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
        @error "$step failed" case = case_name(case) details = err
        return false
    end
end
