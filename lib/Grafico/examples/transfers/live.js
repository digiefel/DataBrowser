(root, input, button, command, state, seconds) => {
  input.setAttribute('aria-label', 'Animation time');
  let sequence = 0, pending = null, inflight = false, sentAt = 0;
  let playing = false, origin = 0, initial = 0;
  root.experiment = {latencies: [], acknowledgements: 0};

  const send = fraction => {
    pending = fraction;
    if (inflight) return;
    const value = pending;
    pending = null;
    inflight = true;
    sentAt = performance.now();
    command.notify({sequence: ++sequence, fraction: value});
  };

  const accept = value => {
    root.dataset.fraction = value.fraction;
    root.dataset.progress = value.progress;
    root.dataset.arrived = value.arrived;
    root.dataset.ready = 'true';
    input.value = value.fraction;
    if (value.sequence === sequence && inflight) {
      root.experiment.latencies.push(performance.now() - sentAt);
      root.experiment.acknowledgements++;
      inflight = false;
      if (pending !== null) send(pending);
    }
  };
  state.on(accept);
  accept(state.value);

  const pause = () => {playing = false; button.textContent = 'Play'};
  input.addEventListener('input', () => {pause(); send(Number(input.value))});
  button.addEventListener('click', () => {
    if (playing) return pause();
    initial = Number(input.value);
    if (initial >= 1) initial = 0;
    origin = performance.now();
    playing = true;
    button.textContent = 'Pause';
  });
  const tick = now => {
    if (!root.isConnected) return;
    if (playing) {
      const fraction = Math.min(1, initial + (now - origin) / (1000 * seconds));
      send(fraction);
      if (fraction === 1) pause();
    }
    requestAnimationFrame(tick);
  };
  requestAnimationFrame(tick);
}
