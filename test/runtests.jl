using Test
using Logging
import InfrastructureSystems as IS
using PowerSystemsUpdater
const PSU = PowerSystemsUpdater

import Aqua
Aqua.test_unbound_args(PowerSystemsUpdater)
Aqua.test_undefined_exports(PowerSystemsUpdater)
Aqua.test_ambiguities(PowerSystemsUpdater)
Aqua.test_stale_deps(PowerSystemsUpdater)
Aqua.test_deps_compat(PowerSystemsUpdater)

"""
Whether the corpus tier is required to run.

Unset (the default, including every CI workflow today): a missing corpus file or directory
warns and the dependent testset quietly contributes no assertions, exactly as before this
tier split existed. Set `PSU_CORPUS` (to any non-empty value) to make that same absence a
hard test failure instead — for a developer who has `data/` checked out locally and wants to
know if a corpus-dependent test silently stopped running.

Building the corpus itself is slow and network-bound (`scripts/psy5_case_generator/` or
`test/fixtures/generate_fixtures.jl`), so no CI workflow sets this: CI proves the
corpus-free unit tier only, honestly, rather than proving nothing while claiming otherwise.
"""
const PSU_CORPUS_REQUIRED = !isempty(get(ENV, "PSU_CORPUS", ""))

"""
Corpus-tier file gate. Returns `true` when `path` exists, so the caller's testset body
should run. When `path` is missing: records a `@test false` (loud, specific) if
`PSU_CORPUS_REQUIRED`; otherwise warns and stays quiet, matching the tier's default of
contributing zero assertions rather than a false failure on a fresh checkout.
"""
function require_corpus_file(path::AbstractString)
    if isfile(path)
        return true
    end
    if PSU_CORPUS_REQUIRED
        @error "PSU_CORPUS is set but a required corpus file is missing" path
        @test false
    else
        @warn "corpus absent; skipping" path
    end
    return false
end

"""
Corpus-tier directory gate, for testsets that sweep every system under `data/` rather than
naming one file. Returns `true` when `systems` is non-empty.
"""
function require_corpus_systems(systems::AbstractVector, message::AbstractString)
    if !isempty(systems)
        return true
    end
    if PSU_CORPUS_REQUIRED
        @error "PSU_CORPUS is set but $message"
        @test false
    else
        @warn "corpus absent under data/; skipping — $message"
    end
    return false
end

LOG_FILE = "power-systems.log"
LOG_LEVELS = Dict(
    "Debug" => Logging.Debug,
    "Info" => Logging.Info,
    "Warn" => Logging.Warn,
    "Error" => Logging.Error,
)

"""
Copied @includetests from https://github.com/ssfrr/TestSetExtensions.jl.
Ideally, we could import and use TestSetExtensions.  Its functionality was broken by changes
in Julia v0.7.  Refer to https://github.com/ssfrr/TestSetExtensions.jl/pull/7.
"""

"""
Includes the given test files, given as a list without their ".jl" extensions.
If none are given it will scan the directory of the calling file and include all
the julia files.
"""
macro includetests(testarg...)
    if length(testarg) == 0
        tests = []
    elseif length(testarg) == 1
        tests = testarg[1]
    else
        error("@includetests takes zero or one argument")
    end

    quote
        tests = $tests
        rootfile = @__FILE__
        if length(tests) == 0
            tests = readdir(dirname(rootfile))
            tests = filter(
                f ->
                    startswith(f, "test_") && endswith(f, ".jl") && f != basename(rootfile),
                tests,
            )
        else
            tests = map(f -> string(f, ".jl"), tests)
        end
        println()
        for test in tests
            print(splitext(test)[1], ": ")
            include(test)
            println()
        end
    end
end

function run_tests()
    logging_config_filename = get(ENV, "SIENNA_LOGGING_CONFIG", nothing)
    if logging_config_filename !== nothing
        config = IS.LoggingConfiguration(logging_config_filename)
    else
        config = IS.LoggingConfiguration(;
            filename = LOG_FILE,
            file_level = Logging.Info,
            console_level = Logging.Error,
        )
    end
    console_logger = ConsoleLogger(config.console_stream, config.console_level)

    IS.open_file_logger(config.filename, config.file_level) do file_logger
        levels = (Logging.Info, Logging.Warn, Logging.Error)
        multi_logger =
            IS.MultiLogger([console_logger, file_logger], IS.LogEventTracker(levels))
        global_logger(multi_logger)

        if !isempty(config.group_levels)
            IS.set_group_levels!(multi_logger, config.group_levels)
        end

        # Testing Topological components of the schema
        @time @testset "Begin PowerSystemsUpdater tests" begin
            @includetests ARGS
        end

        @test length(IS.get_log_events(multi_logger.tracker, Logging.Error)) == 0
        @info IS.report_log_summary(multi_logger)
    end
end

logger = global_logger()

try
    run_tests()
finally
    # Guarantee that the global logger is reset.
    global_logger(logger)
    nothing
end
