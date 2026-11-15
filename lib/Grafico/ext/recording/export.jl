function export_html(path, recording; runtime = joinpath(@__DIR__, "runtime.js"))
    app = Bonito.App(; title = "Grafico animation") do session
        root = Bonito.DOM.main(Bonito.DOM.div(; class = "figure"), Bonito.DOM.div(; class = "controls"))
        packed = Bonito.BinaryAsset(session, recording.description)
        scene_templates = Bonito.BinaryAsset(session, recording.scene_templates)
        actor_templates = Bonito.BinaryAsset(session, recording.actor_templates)
        implementation = Bonito.JSCode(read(runtime, String))
        setup = Bonito.js"""
        (async () => {
            const WGL = await $(WGLMakie.WGL);
            const decode = async asset => Bonito.decode_binary(await asset, $(session.compression_enabled));
            const initialize = $(implementation);
            await initialize($(root), WGL, await decode($(packed)),
                await decode($(scene_templates)), await decode($(actor_templates)));
        })().catch(error => { window.graficoRecordingError = String(error); console.error(String(error)); });
        """
        Bonito.DOM.div(Bonito.DOM.style("body{margin:0;font:16px system-ui}.figure{width:100%}.figure canvas{display:block;max-width:100%;height:auto!important}.controls{padding:1rem;display:flex;gap:.8rem}.controls input{flex:1}"), root, setup)
    end
    session = Bonito.Session(Bonito.NoConnection(); asset_server = Bonito.NoServer(), compression_enabled = true)
    try
        Bonito.export_static(path, app; session)
        isready(session)
    finally
        close(session)
    end
    path
end
