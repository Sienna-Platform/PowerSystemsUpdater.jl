using PowerSystems
using PowerSystemCaseBuilder

if !isdir("data/PSITestSystems")
    mkpath("data/PSITestSystems")
end

for n in list_systems(PSITestSystems)
    sys = build_system(PSITestSystems, n)
    to_json(sys, "data/PSITestSystems/$n")
end
