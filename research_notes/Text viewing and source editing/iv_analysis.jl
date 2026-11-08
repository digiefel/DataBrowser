analyze_iv(table, _) = Dict(:points => length(table.Voltage_V), :maximum_current_uA => maximum(table.Current_High_A) * 1e6)
