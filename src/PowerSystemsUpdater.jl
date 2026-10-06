module PowerSystemsUpdater

import Dates
import HDF5
import InfraStore
import InfrastructureSystems
import JSON
import OpenAPI
import InfrastructureCoreOpenAPIModels
import InfrastructureTimeSeriesOpenAPIModels
import PowerCoreOpenAPIModels
import PowerOperationsOpenAPIModels
import SQLite
import Tables
import TimeZones

const IS = InfrastructureSystems
const ICOM = InfrastructureCoreOpenAPIModels
const ITSOM = InfrastructureTimeSeriesOpenAPIModels
const PCOM = PowerCoreOpenAPIModels
const POOM = PowerOperationsOpenAPIModels

using DocStringExtensions

@template (FUNCTIONS, METHODS) = """
                                 $(TYPEDSIGNATURES)
                                 $(DOCSTRING)
                                 """

include("read_psy5.jl")
include("ledger.jl")
include("report.jl")
include("translate/fields.jl")
include("base_power.jl")
include("translate/dispatch.jl")
include("translate/reserves.jl")
include("translate/transformers.jl")
include("translate/hydro_reservoir.jl")
include("time_series.jl")
include("time_series_store.jl")
include("convert.jl")

export convert_system
export ConversionResult
export ConversionReport
export has_findings

end
