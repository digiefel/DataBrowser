// Timing is data; interpolation, easing and authored trajectories are compiled Julia.
function createMotionPlayer(description, kernels) {
    const mix = kernels[description.mix];
    function sample(seconds) {
        if (!Number.isFinite(seconds)) throw new Error('Time must be finite');
        const time = Math.max(0, Math.min(description.duration, seconds));
        const values = {};
        for (const channel of description.channels) {
            let current = channel.initial;
            for (const segment of channel.segments) {
                if (time < segment.start) break;
                if (time < segment.stop) {
                    const progress = (time - segment.start) / (segment.stop - segment.start);
                    current = segment.curve === null ?
                        mix(segment.initial, segment.target, kernels[segment.ease](progress)) :
                        kernels[segment.curve](segment.initial, progress);
                    break;
                }
                current = segment.target;
            }
            values[channel.name] = current;
        }
        return values;
    }
    return {sample, duration: description.duration};
}
