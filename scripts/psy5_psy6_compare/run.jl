# Upgrade PSY5 cases with PowerSystemsUpdater and check that PSY6 reads back the same system.
#
#   julia scripts/psy5_psy6_compare/run.jl [options] <case.json | directory>...
#
# A directory expands to every `*.json` under it that is not a `_metadata.json`. Per case, four
# steps, each its own process (PSY5 and PSY6 cannot share one) handing off through files under
# the work directory (see case_layout.jl):
#
#   psy5_snapshot  load with PowerSystems 5 and snapshot    (psy5_env)
#   convert        upgrade with PowerSystemsUpdater         (psy6_env)
#   psy6_snapshot  load the bundle with PSY6 and snapshot   (psy6_env)
#   compare        diff the snapshots, write the reports    (psy6_env)
#
# Options:
#   --work DIR        results directory (default: scripts/psy5_psy6_compare/work)
#   --steps a,b,...   run only these steps, e.g. `--steps compare` after editing
#                     known_differences.jl
#   --instantiate     instantiate both environments first
#
# The terminal shows one line per step; the full output, with per-case progress, is appended to
# `<work>/run.log`. Exits non-zero if any case failed a step or has an unexpected difference.

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
    # Results are kept per case name.
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

function note(log::IO, message::AbstractString)
    println(stdout, message)
    println(log, message)
    flush(log)
end

# Per-case progress lines from the step scripts (`[ Info:`) go to the log only.
shown_on_terminal(line::AbstractString) = !startswith(line, "[ Info:")

"""
Run `cmd`, copying its output to `log` and the terminal-worthy lines to the terminal. Returns
its exit code.
"""
function run_logged(cmd::Cmd, log::IO)
    output = Pipe()
    proc = run(pipeline(ignorestatus(cmd); stdout = output, stderr = output); wait = false)
    close(output.in)
    for line in eachline(output; keep = true)
        if shown_on_terminal(line)
            print(stdout, line)
        end
        print(log, line)
        flush(log)
    end
    wait(proc)
    return proc.exitcode
end

failed_cases(work_dir, cases, step) =
    count(c -> isfile(joinpath(case_dir(work_dir, c), error_file(step))), cases)

function main(args)
    work_dir, steps, instantiate, cases = parse_args(args)
    mkpath(work_dir)
    open(joinpath(work_dir, RUN_LOG), "a") do log
        println(log, "\n", "="^80)
        println(log, "$(Dates.now()) julia run.jl $(join(args, ' '))")
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
        note(log, "$(length(cases)) case(s) -> $work_dir")
        status = 0
        for (step, (env, script)) in STEP_COMMANDS
            if step ∉ steps
                continue
            end
            started = time()
            code = run_logged(`$(julia_in(env)) $script $work_dir $cases`, log)
            seconds = round(Int, time() - started)
            failed = failed_cases(work_dir, cases, step)
            note(log, "$step: $(length(cases) - failed) ok, $failed failed ($(seconds)s)")
            status = max(status, code)
        end
        note(log, "log: $(joinpath(work_dir, RUN_LOG))")
        return status
    end
end

exit(main(ARGS))
