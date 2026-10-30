# Builds TinyRuntime as a PackageCompiler app in ./TinyRuntimeApp.
using PackageCompiler
create_app(joinpath(@__DIR__, "TinyRuntime"), joinpath(@__DIR__, "TinyRuntimeApp"); force=true)
