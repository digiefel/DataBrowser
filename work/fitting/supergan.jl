# Scratch: the real SuperGaN measurements as one table, for the fitting corpus.
# Each CSV has `# Key: value` header lines, then a table. Device names such as `C2_20um` give the
# structure and the gap.
using CSV, DataFrames, CairoMakie

const SUPERGAN = "/Users/davide/Library/CloudStorage/OneDrive-LundUniversity/projects/Lind/SuperGaN/data/exp_raw"

function read_measurement(path)
    lines = readlines(path)
    header = Dict{String, String}()
    for line in lines
        m = match(r"^# (\w+): (.*?)\s*$", line)
        m === nothing || (header[m[1]] = m[2])
    end
    start = findfirst(line -> !startswith(line, "#"), lines)
    table = CSV.read(IOBuffer(join(lines[start:end], "\n")), DataFrame)
    return (; path, procedure=header["Procedure"], chip=header["Chip"], site=header["Site"],
        subsite=header["Subsite"], device=header["Device"], table)
end

measurements = [read_measurement(path) for (root, _, files) in walkdir(SUPERGAN)
    for path in joinpath.(root, files) if endswith(path, ".csv")]

# The voltage across and the current through the device, whichever instrument procedure measured it.
function voltage_current(m)
    t = m.table
    m.procedure == "IVSweep" && return t.Voltage_V, t.Current_High_A
    m.procedure == "Isweep" && return t.VoltageHigh_V .- t.VoltageLow_V, t.CurrentHigh_A
    m.procedure == "FourTerminalIV" && return t.VoltageHigh_V .- t.VoltageLow_V, t.Current_A
    error("unknown procedure $(m.procedure)")
end

# TLM: resistance of each bigTLM sweep from a straight line through I(V), then R against gap.
tlm = DataFrame(map(filter(m -> m.subsite == "bigTLM" && m.procedure != "FourTerminalIV", measurements)) do m
    structure, gap = match(r"^(C\d)_(\d+)um$", m.device).captures
    V, I = voltage_current(m)
    slope = hcat(ones(length(V)), V) \ I
    (; m.chip, m.site, structure, gap_um=parse(Float64, gap), R_ohm=1 / slope[2],
        flagged_rows=count(!=(0), m.table.Status), m.procedure, m.path)
end)
show(sort(tlm, [:chip, :site, :structure, :gap_um])[:, Not(:path)]; allrows=true)
println()

figure = Figure(size=(1100, 400))
axis = Axis(figure[1, 1]; xlabel="gap (µm)", ylabel="R (Ω)", title="SuperGaN bigTLM, one point per sweep")
for (key, group) in pairs(groupby(tlm, [:chip, :site, :structure]))
    scatter!(axis, group.gap_um, group.R_ohm; label="$(key.chip) $(key.site) $(key.structure)")
end
axislegend(axis; position=:lt)
axis = Axis(figure[1, 2]; xlabel="V (V)", ylabel="I (A)", title="the IV sweeps behind them")
for m in filter(m -> m.subsite == "bigTLM" && m.procedure != "FourTerminalIV", measurements)
    lines!(axis, voltage_current(m)...)
end
save(joinpath(@__DIR__, "supergan-tlm.png"), figure)
