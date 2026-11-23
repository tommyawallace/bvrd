// Plays raw float32 audio from stdin. Speed doesn't change the pitch.
// Quits when stdin closes and the last audio has played.
//
//     BVRDPlayer <sample-rate> [speed]
import AVFoundation
import Foundation

let args = CommandLine.arguments
guard args.count >= 2, let sampleRate = Double(args[1]), sampleRate > 0 else {
    FileHandle.standardError.write(Data("usage: BVRDPlayer <sample-rate> [speed]\n".utf8))
    exit(2)
}
let speed = Float(args.count >= 3 ? args[2] : "1") ?? 1

let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
let engine = AVAudioEngine()
let player = AVAudioPlayerNode()
engine.attach(player)

if abs(speed - 1) < 0.01 {
    engine.connect(player, to: engine.mainMixerNode, format: format)
} else {
    let timePitch = AVAudioUnitTimePitch()
    timePitch.rate = min(2, max(0.5, speed))
    timePitch.overlap = 16
    engine.attach(timePitch)
    engine.connect(player, to: timePitch, format: format)
    engine.connect(timePitch, to: engine.mainMixerNode, format: format)
}

do {
    try engine.start()
} catch {
    FileHandle.standardError.write(Data("Couldn't start audio output: \(error.localizedDescription)\n".utf8))
    exit(1)
}
player.play()

let bytesPerSample = MemoryLayout<Float>.size
let pending = DispatchGroup()
var leftover = Data()

func schedule(_ data: Data) {
    let frames = data.count / bytesPerSample
    guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return }
    buffer.frameLength = AVAudioFrameCount(frames)
    data.withUnsafeBytes { raw in
        buffer.floatChannelData![0].update(from: raw.bindMemory(to: Float.self).baseAddress!, count: frames)
    }
    pending.enter()
    player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in pending.leave() }
}

let input = FileHandle.standardInput
while true {
    let chunk = input.availableData
    if chunk.isEmpty { break }
    leftover.append(chunk)
    let usable = leftover.count - leftover.count % bytesPerSample
    if usable > 0 {
        schedule(leftover.prefix(usable))
        leftover = Data(leftover.dropFirst(usable))
    }
}

pending.wait()
// Wait for the last bit of audio to finish.
Thread.sleep(forTimeInterval: 0.15)
engine.stop()
exit(0)
