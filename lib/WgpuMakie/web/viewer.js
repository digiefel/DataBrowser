// Browser glue connecting `wgpu_makie_web` WASM to a WebSocket MessagePack stream.

export async function startWgpuMakieWeb({
  wasmModuleUrl = "./pkg/wgpu_makie_web.js",
  wsUrl = null,
} = {}) {
  const canvas = document.getElementById("wgpu-canvas");
  const statusEl = document.getElementById("status");
  const tooltipEl = document.getElementById("tooltip");
  const copyBtn = document.getElementById("copy-code");

  const wasm = await import(wasmModuleUrl);
  await wasm.default();
  const viewer = await wasm.WebViewer.create(canvas);
  statusEl.textContent = "Ready";

  function syncSize() {
    const rect = canvas.getBoundingClientRect();
    const dpr = window.devicePixelRatio || 1;
    canvas.width = Math.max(1, Math.round(rect.width * dpr));
    canvas.height = Math.max(1, Math.round(rect.height * dpr));
    viewer.resize(Math.max(1, Math.round(rect.width)), Math.max(1, Math.round(rect.height)), dpr);
  }
  syncSize();
  window.addEventListener("resize", syncSize);

  let ws = null;
  if (wsUrl) {
    ws = new WebSocket(wsUrl);
    ws.binaryType = "arraybuffer";
    ws.onmessage = (ev) => {
      viewer.apply_message_bytes(new Uint8Array(ev.data));
    };
    ws.onopen = () => {
      statusEl.textContent = "Connected";
    };
    ws.onclose = () => {
      statusEl.textContent = "Disconnected";
    };
  }

  function flushOutbound() {
    if (!ws || ws.readyState !== WebSocket.OPEN) return;
    const frames = viewer.drain_outbound_bytes();
    for (const f of frames) {
      ws.send(f);
    }
  }

  function modifiersOf(ev) {
    return (ev.shiftKey ? 1 : 0) | ((ev.ctrlKey || ev.metaKey) ? 2 : 0) | (ev.altKey ? 4 : 0);
  }

  function pointerCoords(ev) {
    const rect = canvas.getBoundingClientRect();
    return [ev.clientX - rect.left, rect.height - (ev.clientY - rect.top)];
  }

  canvas.addEventListener("pointermove", (ev) => {
    const [x, y] = pointerCoords(ev);
    viewer.on_pointer_move(x, y);
    const tip = viewer.hover_tooltip();
    if (tip) {
      tooltipEl.style.display = "block";
      tooltipEl.style.left = `${ev.clientX + 12}px`;
      tooltipEl.style.top = `${ev.clientY - 12}px`;
      tooltipEl.textContent = tip;
    } else {
      tooltipEl.style.display = "none";
    }
    flushOutbound();
  });

  canvas.addEventListener("pointerdown", (ev) => {
    const [x, y] = pointerCoords(ev);
    viewer.on_pointer_move(x, y);
    viewer.on_pointer_down(ev.button, modifiersOf(ev));
    flushOutbound();
  });

  canvas.addEventListener("pointerup", (ev) => {
    viewer.on_pointer_up(ev.button);
    flushOutbound();
  });

  canvas.addEventListener("wheel", (ev) => {
    ev.preventDefault();
    viewer.on_wheel(ev.deltaX / 40, -ev.deltaY / 40, modifiersOf(ev));
    flushOutbound();
  }, { passive: false });

  copyBtn.addEventListener("click", async () => {
    const code = viewer.exported_code();
    if (code && navigator.clipboard) {
      await navigator.clipboard.writeText(code);
      statusEl.textContent = "Copied Grafico Code";
    }
  });

  function frameLoop() {
    viewer.render_frame();
    requestAnimationFrame(frameLoop);
  }
  requestAnimationFrame(frameLoop);

  return viewer;
}
