// Timing is data; every interpolation, easing and trajectory is compiled Julia.
function createMotionPlayer(description, kernels, bridge, codec) {
    const channels = description.channels.map(channel => ({...channel,
        initialValue: bridge.build(channel.argument_descriptor, channel.initial),
        segments: channel.segments.map(segment => ({...segment,
            initialValue: bridge.build(channel.argument_descriptor, segment.initial),
            targetValue: bridge.build(channel.argument_descriptor, segment.target)}))}));
    function sample(seconds) {
        if (!Number.isFinite(seconds)) throw new Error('Time must be finite');
        const time = Math.max(0, Math.min(description.duration, seconds));
        const values = {};
        for (const channel of channels) {
            let current = channel.initialValue;
            for (const segment of channel.segments) {
                if (time < segment.start) break;
                if (time < segment.stop) {
                    const progress = (time - segment.start) / (segment.stop - segment.start);
                    current = segment.curve === null ?
                        kernels[channel.mix](segment.initialValue, segment.targetValue, kernels[segment.ease](progress)) :
                        kernels[segment.curve](segment.initialValue, progress);
                    break;
                }
                current = segment.targetValue;
            }
            values[channel.name] = codec.decode(channel.descriptor, bridge.walk(channel.descriptor, current));
        }
        if (description.time_name !== null) values[description.time_name] = time;
        return values;
    }
    return {sample, duration: description.duration};
}
