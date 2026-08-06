using PowerSystems
using PowerSystemCaseBuilder

const DATA_DIR = normpath(joinpath(@__DIR__, "..", "..", "data"))

for cat in [PSISystems, PSITestSystems]
    outdir = joinpath(DATA_DIR, string(nameof(cat)))
    mkpath(outdir)
    for n in list_systems(cat)
        sys = build_system(cat, n; force_build = true)
        to_json(sys, joinpath(outdir, n); force = true)
    end
end
