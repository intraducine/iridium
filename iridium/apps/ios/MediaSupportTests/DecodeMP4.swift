import AVFoundation
let asset = AVURLAsset(url: URL(fileURLWithPath: CommandLine.arguments[1]))
let reader = try AVAssetReader(asset: asset)
for track in asset.tracks {
 print("track", track.mediaType.rawValue, "size", track.naturalSize, "seconds", CMTimeGetSeconds(track.timeRange.duration))
 if track.mediaType == .video {
  let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
  reader.add(output)
 }
}
assert(reader.startReading())
var frames = 0
while let sample = reader.outputs[0].copyNextSampleBuffer() { assert(CMSampleBufferGetImageBuffer(sample) != nil); frames += 1 }
print("decoded frames", frames, "status",reader.status.rawValue, "error",String(describing: reader.error))
assert(reader.status == .completed && frames > 0)
