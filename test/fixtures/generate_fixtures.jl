# Generates only the systems the test suite needs, unlike
# scripts/psy5_case_generator/psb_case_generator.jl which walks every category.
using PowerSystems
using PowerSystemCaseBuilder

const DATA_DIR = normpath(joinpath(@__DIR__, "..", "..", "data"))

const FIXTURES = [
    (PSISystems, "AC_TWO_RTO_RTS_1Hr_sys"),
    (PSISystems, "two_area_pjm_DA"),
    (PSISystems, "modified_RTS_GMLC_DA_sys"),
    (PSISystems, "sys10_pjm_ac_dc"),
    (PSITestSystems, "case10_radial_series_reductions"),
    (PSITestSystems, "c_sys14_hvdc_lcc"),
    (PSITestSystems, "c_sys14_hvdc_vsc"),
]

for (category, name) in FIXTURES
    outdir = joinpath(DATA_DIR, string(nameof(category)))
    mkpath(outdir)
    sys = build_system(category, name; force_build = true)
    to_json(sys, joinpath(outdir, name); force = true)
end
