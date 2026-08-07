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
    # Every name below is hardcoded by a test (test_convert.jl, test_python_load.jl,
    # test_time_series.jl, test_translate_transformers.jl) or by test_corpus.jl's
    # REQUIRED_SYSTEMS manifest; the fixture set must produce all of them or the corpus
    # tier fails when run against it.
    (PSITestSystems, "c_sys5"),
    (PSITestSystems, "c_linear_fuel_test"),
    (PSITestSystems, "c_sys5_hy_uc"),
    (PSITestSystems, "c_sys5_hybrid"),
    (PSITestSystems, "c_sys5_hybrid_uc"),
    (PSITestSystems, "c_sys5_hybrid_ed"),
    (PSITestSystems, "test_RTS_GMLC_sys_with_hybrid"),
    (PSITestSystems, "c_duration_test"),
    (PSITestSystems, "c_sys5_uc"),
    (PSITestSystems, "c_sys5_hy_ed"),
    (PSITestSystems, "c_sys5_all_components"),
    (PSITestSystems, "c_sys14"),
]

for (category, name) in FIXTURES
    outdir = joinpath(DATA_DIR, string(nameof(category)))
    mkpath(outdir)
    sys = build_system(category, name; force_build = true)
    to_json(sys, joinpath(outdir, name); force = true)
end
