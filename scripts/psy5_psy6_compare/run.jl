# Upgrade PSY5 cases with PowerSystemsUpdater and check that PSY6 reads back the same system.
#
#   julia scripts/psy5_psy6_compare/run.jl [options] <case.json | directory>...
#
# For every case (a PSY5 `System` JSON, with its `_time_series_storage.h5` beside it):
#
#   1. psy5_snapshot  load it with PowerSystems 5 and snapshot it          (psy5_env)
#   2. convert        upgrade it to a PSY6 bundle with PowerSystemsUpdater  (psy6_env)
#   3. psy6_snapshot  load the bundle with PowerSystems 6 and snapshot it  (psy6_env)
#   4. compare        diff the snapshots against known_differences.jl      (psy6_env)
#
# PSY5 and PSY6 are the same package to Julia, so each step is its own process in its own
# environment, and steps hand off through files under the work directory (see case_layout.jl).
# Each step processes every case in one process, so package load time is paid once per step.
#
# A directory argument expands to every `*.json` under it, searched recursively, that is
# not a `_metadata.json` — so `data/` covers every generated category.
#
# Options:
#   --work DIR        where results go (default: scripts/psy5_psy6_compare/work)
#   --steps a,b,...   run only these steps, e.g. `--steps compare` after editing
#                     known_differences.jl, or `--steps convert,psy6_snapshot,compare` after
#                     changing the updater
#   --instantiate     instantiate both environments first
#
# Everything the steps print is shown and also appended to `<work>/run.log`, under a header
# naming the run, so a failure seen scrolling past can be found again.
#
# Exits non-zero if any case fails a step or has an unexpected difference.

import Dates

const HERE = @__DIR__

include(joinpath(HERE, "case_layout.jl"))

const PSY5_ENV = joinpath(HERE, "psy5_env")
const PSY6_ENV = joinpath(HERE, "psy6_env")

const STEP_COMMANDS = [
    "psy5_snapshot" => (PSY5_ENV, joinpath(PSY5_ENV, "snapshot_psy5.jl")),
    "convert" => (PSY6_ENV, joinpath(PSY6_ENV, "convert.jl")),
    "psy6_snapshot" => (PSY6_ENV, joinpath(PSY6_ENV, "snapshot_psy6.jl")),
    "compare" => (PSY6_ENV, joinpath(HERE, "compare.jl")),
]

is_case_file(f::AbstractString) = endswith(f, ".json") && !endswith(f, "_metadata.json")

function expand_cases(paths)
    cases = String[]
    for path in paths
        if isdir(path)
            for (root, _, files) in walkdir(path), f in sort(files)
                if is_case_file(f)
                    push!(cases, abspath(joinpath(root, f)))
                end
            end
        elseif isfile(path)
            push!(cases, abspath(path))
        else
            error("no such case or directory: $path")
        end
    end
    if isempty(cases)
        error("no PSY5 cases found in $(paths)")
    end
    unique!(cases)
    # Results are kept per case name, so two cases with one name would overwrite each other.
    by_name = Dict{String, Vector{String}}()
    for case in cases
        push!(get!(Vector{String}, by_name, case_name(case)), case)
    end
    clashes = [paths for paths in values(by_name) if length(paths) > 1]
    if !isempty(clashes)
        error("cases share a name and would overwrite each other's results: $(clashes)")
    end
    return cases
end

function parse_args(args)
    work_dir = joinpath(HERE, "work")
    steps = first.(STEP_COMMANDS)
    instantiate = false
    paths = String[]
    i = 1
    while i <= length(args)
        arg = args[i]
        if arg == "--work"
            work_dir = args[i += 1]
        elseif arg == "--steps"
            steps = String.(split(args[i += 1], ','))
            unknown = setdiff(steps, first.(STEP_COMMANDS))
            if !isempty(unknown)
                error("unknown step(s) $(unknown); choose from $(first.(STEP_COMMANDS))")
            end
        elseif arg == "--instantiate"
            instantiate = true
        else
            push!(paths, arg)
        end
        i += 1
    end
    if isempty(paths)
        error(
            "usage: julia $(relpath(@__FILE__)) [--work DIR] [--steps a,b] " *
            "[--instantiate] <case.json | directory>...",
        )
    end
    return abspath(work_dir), steps, instantiate, expand_cases(paths)
end

julia_in(env) = `$(Base.julia_cmd()) --project=$env`

"""
Print a line from the driver itself, to the terminal and the log.
"""
function note(log::IO, message::AbstractString)
    line = "[run.jl] $message\n"
    print(stdout, line)
    print(log, line)
    flush(log)
end

"""
Run `cmd`, copying its stdout and stderr line by line to the terminal and to `log`. Returns
its exit code.
"""
function run_logged(cmd::Cmd, log::IO)
    output = Pipe()
    proc = run(pipeline(ignorestatus(cmd); stdout = output, stderr = output); wait = false)
    close(output.in)
    for line in eachline(output; keep = true)
        print(stdout, line)
        print(log, line)
        flush(log)
    end
    wait(proc)
    return proc.exitcode
end

function main(args)
    work_dir, steps, instantiate, cases = parse_args(args)
    mkpath(work_dir)
    open(joinpath(work_dir, RUN_LOG), "a") do log
        println(log, "\n", "="^80)
        note(log, "$(Dates.now()) julia run.jl $(join(args, ' '))")
        if instantiate
            for env in (PSY5_ENV, PSY6_ENV)
                note(log, "instantiating $env")
                code = run_logged(`$(julia_in(env)) -e 'using Pkg; Pkg.instantiate()'`, log)
                if code != 0
                    note(log, "instantiating $env failed")
                    return code
                end
            end
        end
        note(
            log,
            "comparing $(length(cases)) case(s) in $work_dir; steps: $(join(steps, ", "))",
        )
        status = 0
        for (step, (env, script)) in STEP_COMMANDS
            if step ∉ steps
                continue
            end
            note(log, "step: $step")
            status =
                max(status, run_logged(`$(julia_in(env)) $script $work_dir $cases`, log))
        end
        note(log, "done, exit status $status")
        return status
    end
end

exit(main(ARGS))
