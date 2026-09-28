import AVFoundation
import Foundation

/// Real-time 15-band parametric EQ for AVPlayer. It runs inside an
/// MTAudioProcessingTap, so the same DSP applies to local files and streams.
enum AudioTapEqualizer {
    private static let frequencies: [Float] = [25,40,63,100,160,250,400,630,1000,1600,2500,4000,6300,10000,16000]

    static func makeMix(gains: [Float]) -> AVAudioMix? {
        guard gains.count == frequencies.count else { return nil }
        let context = EQTapContext(gains: gains)
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: Unmanaged.passRetained(context).toOpaque(),
            init: eqTapInit,
            finalize: eqTapFinalize,
            prepare: eqTapPrepare,
            unprepare: eqTapUnprepare,
            process: eqTapProcess
        )
        var unmanagedTap: Unmanaged<MTAudioProcessingTap>?
        let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks,
                                                kMTAudioProcessingTapCreationFlag_PostEffects, &unmanagedTap)
        guard status == noErr, let tap = unmanagedTap?.takeRetainedValue() else {
            Unmanaged.passUnretained(context).release(); return nil
        }
        let parameters = AVMutableAudioMixInputParameters()
        parameters.audioTapProcessor = tap
        let mix = AVMutableAudioMix(); mix.inputParameters = [parameters]
        return mix
    }
}

private final class EQTapContext {
    private static let frequencies: [Float] = [25,40,63,100,160,250,400,630,1000,1600,2500,4000,6300,10000,16000]
    let gains: [Float]
    var sampleRate: Float = 44_100
    var channelStates: [[[Float]]] = [] // channel → band → [x1,x2,y1,y2]
    init(gains: [Float]) { self.gains = gains }
    func prepare(channels: Int, sampleRate: Float) {
        self.sampleRate = sampleRate
        channelStates = Array(repeating: Array(repeating: [0,0,0,0], count: gains.count), count: max(1, channels))
    }
    func process(_ samples: UnsafeMutablePointer<Float>, count: Int, channel: Int) {
        guard channelStates.indices.contains(channel) else { return }
        for band in gains.indices where abs(gains[band]) > 0.01 {
            let frequency = min(Self.frequencies[band], sampleRate * 0.45)
            let a = powf(10, gains[band] / 40)
            let omega = 2 * Float.pi * frequency / sampleRate
            let alpha = sinf(omega) / (2 * 1.15)
            let cosine = cosf(omega)
            let a0 = 1 + alpha / a
            let b0 = (1 + alpha * a) / a0, b1 = (-2 * cosine) / a0, b2 = (1 - alpha * a) / a0
            let a1 = (-2 * cosine) / a0, a2 = (1 - alpha / a) / a0
            var state = channelStates[channel][band]
            for index in 0..<count {
                let x = samples[index]
                let y = b0*x + b1*state[0] + b2*state[1] - a1*state[2] - a2*state[3]
                state = [x, state[0], y, state[2]]
                samples[index] = max(-1, min(1, y))
            }
            channelStates[channel][band] = state
        }
    }
}

private let eqTapInit: MTAudioProcessingTapInitCallback = { _, clientInfo, storageOut in storageOut.pointee = clientInfo }
private let eqTapFinalize: MTAudioProcessingTapFinalizeCallback = { tap in
    let storage = MTAudioProcessingTapGetStorage(tap)
    Unmanaged<EQTapContext>.fromOpaque(storage).release()
}
private let eqTapPrepare: MTAudioProcessingTapPrepareCallback = { tap, _, format in
    let storage = MTAudioProcessingTapGetStorage(tap)
    let context = Unmanaged<EQTapContext>.fromOpaque(storage).takeUnretainedValue()
    context.prepare(channels: Int(format.pointee.mChannelsPerFrame), sampleRate: Float(format.pointee.mSampleRate))
}
private let eqTapUnprepare: MTAudioProcessingTapUnprepareCallback = { _ in }
private let eqTapProcess: MTAudioProcessingTapProcessCallback = { tap, frameCount, _, bufferList, framesOut, flagsOut in
    let status = MTAudioProcessingTapGetSourceAudio(tap, frameCount, bufferList, flagsOut, nil, framesOut)
    guard status == noErr else { return }
    let storage = MTAudioProcessingTapGetStorage(tap)
    let context = Unmanaged<EQTapContext>.fromOpaque(storage).takeUnretainedValue()
    let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
    for (channel, buffer) in buffers.enumerated() {
        guard let data = buffer.mData else { continue }
        let samples = data.assumingMemoryBound(to: Float.self)
        context.process(samples, count: Int(framesOut.pointee), channel: min(channel, context.channelStates.count - 1))
    }
}
