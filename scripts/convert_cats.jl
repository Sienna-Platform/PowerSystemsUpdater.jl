# Extended system test: runs the full convert_system pipeline (not just build_document)
# against the real CATS system, the largest system this package sees. Ad hoc rather than a
# runtests.jl tier because CATS is not part of the PSISystems/PSITestSystems corpus the
# PSU_CORPUS tier sweeps and its time-series sidecar is hundreds of MB.
#
# Run with: julia --project=test scripts/convert_cats.jl

using PowerSystemsUpdater
const PSU = PowerSystemsUpdater

const SOURCE = joinpath(@__DIR__, "..", "data", "CATS", "CATS_Sienna.json")

if !isfile(SOURCE)
    error("no such file: $SOURCE")
end

mktempdir() do tmp
    @time result = PSU.convert_system(SOURCE, tmp)
    doc = result.document

    println(sprint(show, MIME("text/plain"), result.report))
    println("components: ", sum(length, values(doc.components)))
    println("supplemental attributes: ", length(doc.supplemental_attributes))
    println("service associations: ", length(doc.service_associations))
    println("time series associations: ", length(doc.time_series_associations))

    if !isempty(result.report.cascaded_skips)
        error("CATS conversion produced cascaded skips: $(result.report.cascaded_skips)")
    end

    system_json = joinpath(tmp, "system.json")
    reloaded = PSU.PCOM.read_document(system_json)
    PSU.PCOM.validate_document(reloaded)
    println("re-read and validated ", system_json)
end
