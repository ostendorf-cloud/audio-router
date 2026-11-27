// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

// Throwaway for issue 86. Never merge to main, delete it with the spike workflow.
// A process that plays a 1 kHz sine at half scale on the default output, with no Apple Event.
// Usage: tone <seconds>

import AVFoundation
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)

let seconds = CommandLine.arguments.count > 1 ? Double(CommandLine.arguments[1]) ?? 600 : 600
let engine = AVAudioEngine()
let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
let sampleRate = rate > 0 ? rate : 48000
let step = 2 * Double.pi * 1000 / sampleRate
var phase = 0.0

let node = AVAudioSourceNode { _, _, frames, bufferList in
    let list = UnsafeMutableAudioBufferListPointer(bufferList)
    for frame in 0..<Int(frames) {
        let value = Float(0.5 * sin(phase))
        phase += step
        if phase > 2 * Double.pi { phase -= 2 * Double.pi }
        for buffer in list {
            buffer.mData?.assumingMemoryBound(to: Float.self)[frame] = value
        }
    }
    return noErr
}

engine.attach(node)
let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)
engine.connect(node, to: engine.mainMixerNode, format: format)

do {
    try engine.start()
    print("tone: playing at \(sampleRate) Hz for \(seconds) s, pid \(getpid())")
} catch {
    print("tone: engine start failed: \(error)")
    exit(1)
}

RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
engine.stop()
print("tone: done")
