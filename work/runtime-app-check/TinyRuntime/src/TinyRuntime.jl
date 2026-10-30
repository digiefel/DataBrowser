# Stand-in for the DataBrowser runtime app: runs a project script given on the command line,
# the way the runtime would load a project's own Julia code.
module TinyRuntime

function julia_main()::Cint
    script = ARGS[1]
    Base.include(Main, script)
    return 0
end

end
