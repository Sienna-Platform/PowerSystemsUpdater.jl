module PowerSystemsUpdater

import JSON
import SQLite
import Tables
import TimeZones
import InfrastructureSystems
import PowerOpenAPIModels
import PowerOpenAPIModels.PowerCoreOpenAPIModels
import PowerOpenAPIModels.OpenAPI

const IS = InfrastructureSystems
const POM = PowerOpenAPIModels
const PCOM = PowerOpenAPIModels.PowerCoreOpenAPIModels

using DocStringExtensions

@template (FUNCTIONS, METHODS) = """
                                 $(TYPEDSIGNATURES)
                                 $(DOCSTRING)
                                 """

include("read_psy5.jl")

end
