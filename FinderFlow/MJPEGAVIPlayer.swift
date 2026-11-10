import SwiftUI
import AVFoundation
import ImageIO

// MARK: - MJPEG-in-AVI support
// Some AVI files (3D-printer timelapses, IP cameras) hold plain JPEG frames. macOS says
// it can play them but then fails to decode, so Quick Look shows nothing. The frames are
// normal JPEGs, so we read them from the AVI ourselves and decode them with ImageIO.
// Only MJPEG video is supported. There is no sound.

final class MJPEGAVIReader {
    let url: URL
    let width: Int
    let height: Int
    let framesPerSecond: Double
    /// File position and size of the JPEG data of each video frame.
    let frames: [(offset: UInt64, size: Int)]

    var frameCount: Int { frames.count }
    var duration: Double { Double(frames.count) / framesPerSecond }

    private let handle: FileHandle
    private let lock = NSLock()

    /// Reads the AVI structure. Returns nil if the file is not an AVI with MJPEG video
    /// or has no readable frames. Blocking: call it off the main thread.
    init?(url: URL) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        self.handle = handle
        self.url = url
        guard let parsed = Self.parse(handle) else { return nil }
        width = parsed.width
        height = parsed.height
        framesPerSecond = parsed.fps
        frames = parsed.frames
    }

    deinit { try? handle.close() }

    /// One frame as an image no larger than `maxPixel` on its long side.
    func frame(at index: Int, maxPixel: Int = 1280) -> CGImage? {
        guard frames.indices.contains(index) else { return nil }
        let f = frames[index]
        lock.lock()
        defer { lock.unlock() }
        guard (try? handle.seek(toOffset: f.offset)) != nil,
              let data = try? handle.read(upToCount: f.size), data.count == f.size,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    // MARK: Parsing

    private struct Parsed { var width = 0, height = 0, fps = 0.0; var frames: [(offset: UInt64, size: Int)] = [] }

    private struct VideoStream { var index = 0, scale = 1, rate = 0, width = 0, height = 0; var isMJPEG = false }

    private static func fourCC(_ d: Data, _ at: Int) -> String {
        String(decoding: d[(d.startIndex + at)..<(d.startIndex + at + 4)], as: UTF8.self)
    }
    private static func u32(_ d: Data, _ at: Int) -> Int {
        let i = d.startIndex + at
        return Int(d[i]) | Int(d[i+1]) << 8 | Int(d[i+2]) << 16 | Int(d[i+3]) << 24
    }

    private static func read(_ h: FileHandle, _ offset: UInt64, _ count: Int) -> Data? {
        guard (try? h.seek(toOffset: offset)) != nil,
              let d = try? h.read(upToCount: count), d.count == count else { return nil }
        return d
    }

    private static func parse(_ h: FileHandle) -> Parsed? {
        guard let fileSize = try? h.seekToEnd() else { return nil }
        var stream: VideoStream?
        var frames: [(offset: UInt64, size: Int)] = []
        var pos: UInt64 = 0

        // The first RIFF holds the header; big files continue in further "AVIX" RIFFs.
        while pos + 12 <= fileSize {
            guard let head = read(h, pos, 12), fourCC(head, 0) == "RIFF" else { break }
            let declared = UInt64(u32(head, 4))
            let riffEnd = declared == 0 ? fileSize : min(fileSize, pos + 8 + declared)
            var p = pos + 12
            while p + 8 <= riffEnd {
                guard let ch = read(h, p, 8) else { break }
                let id = fourCC(ch, 0), size = UInt64(u32(ch, 4))
                if id == "LIST", size >= 4, let type = read(h, p + 8, 4) {
                    let kind = fourCC(type, 0)
                    if kind == "hdrl", stream == nil, p + 8 + size <= fileSize,
                       let body = read(h, p + 12, Int(size) - 4) {
                        stream = parseHeader(body)
                    } else if kind == "movi", let s = stream {
                        walkMovi(h, from: p + 12, to: min(riffEnd, p + 8 + size), stream: s, into: &frames, fileSize: fileSize)
                    }
                }
                p += 8 + size + (size & 1)
            }
            pos = max(riffEnd, pos + 12)
        }

        guard let s = stream, s.isMJPEG, s.rate > 0, s.scale > 0, !frames.isEmpty else { return nil }
        return Parsed(width: s.width, height: s.height, fps: Double(s.rate) / Double(s.scale), frames: frames)
    }

    /// Finds the first video stream in the "hdrl" list.
    private static func parseHeader(_ d: Data) -> VideoStream? {
        var found: VideoStream?
        var streamNumber = 0
        func walk(_ start: Int, _ end: Int) {
            var p = start
            var current: VideoStream?
            while p + 8 <= end {
                let id = fourCC(d, p), size = u32(d, p + 4)
                let body = p + 8
                if id == "LIST", size >= 4, body + size <= end {
                    if fourCC(d, body) == "strl" {
                        walk(body + 4, body + size)
                        streamNumber += 1
                    }
                } else if id == "strh", size >= 36, body + size <= end {
                    if fourCC(d, body) == "vids", found == nil {
                        var v = VideoStream()
                        v.index = streamNumber
                        let handler = fourCC(d, body + 4).lowercased()
                        v.isMJPEG = ["mjpg", "avi1", "mjpa"].contains(handler)
                        v.scale = u32(d, body + 20)
                        v.rate = u32(d, body + 24)
                        current = v
                    }
                } else if id == "strf", size >= 20, body + size <= end, var v = current {
                    v.width = u32(d, body + 4)
                    v.height = abs(Int(Int32(truncatingIfNeeded: u32(d, body + 8))))
                    if ["mjpg", "avi1", "mjpa"].contains(fourCC(d, body + 16).lowercased()) { v.isMJPEG = true }
                    found = v
                    current = nil
                }
                if size < 0 || body + size > end { break }
                p = body + size + (size & 1)
            }
        }
        walk(0, d.count)
        // The "hdrl" body starts with the "avih" chunk, which `walk` skips like any other.
        return found
    }

    /// Collects the video chunks of a "movi" list. A cut-off file keeps the frames before the cut.
    private static func walkMovi(_ h: FileHandle, from start: UInt64, to end: UInt64,
                                 stream: VideoStream, into frames: inout [(offset: UInt64, size: Int)],
                                 fileSize: UInt64) {
        let prefix = String(format: "%02d", stream.index)
        var p = start
        while p + 8 <= end {
            guard let ch = read(h, p, 8) else { return }
            let id = fourCC(ch, 0), size = UInt64(u32(ch, 4))
            if id == "LIST" { p += 12; continue }                       // "rec " list: look inside
            if p + 8 + size > fileSize { return }                      // cut-off chunk
            if id.hasPrefix(prefix), id.hasSuffix("dc") || id.hasSuffix("db"), size > 0 {
                frames.append((p + 8, Int(size)))
            }
            p += 8 + size + (size & 1)
        }
    }

    // MARK: Decision

    /// A reader only when the file is MJPEG AVI that macOS cannot decode (the case where
    /// Quick Look shows nothing). Files macOS can play stay with Quick Look.
    static func readerIfSystemCannotPlay(_ url: URL) async -> MJPEGAVIReader? {
        let reader = await Task.detached(priority: .userInitiated) { MJPEGAVIReader(url: url) }.value
        guard let reader else { return nil }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        do {
            _ = try await generator.image(at: .zero)
            return nil
        } catch {
            return reader
        }
    }
}

// MARK: - Player

final class MJPEGAVIPlayerModel: ObservableObject {
    @Published private(set) var image: CGImage?
    @Published private(set) var index = 0
    @Published private(set) var isPlaying = false

    let reader: MJPEGAVIReader
    private let queue = DispatchQueue(label: "FinderFlow.mjpeg-avi", qos: .userInitiated)
    private var busy = false
    private var wanted: Int?
    private var timer: Timer?
    private var playStart = Date()
    private var playBase = 0

    init(reader: MJPEGAVIReader) {
        self.reader = reader
        seek(to: 0)
    }

    deinit { timer?.invalidate() }

    /// Show a frame. While one is being decoded only the newest request is kept.
    func seek(to i: Int) {
        wanted = min(max(i, 0), reader.frameCount - 1)
        pump()
    }

    private func pump() {
        guard !busy, let i = wanted else { return }
        wanted = nil
        busy = true
        queue.async { [reader] in
            let img = reader.frame(at: i)
            DispatchQueue.main.async {
                self.busy = false
                if let img { self.image = img; self.index = i }
                self.pump()
            }
        }
    }

    func togglePlay() { isPlaying ? stop() : play() }

    func play() {
        guard !isPlaying else { return }
        if index >= reader.frameCount - 1 { seek(to: 0); index = 0 }
        playBase = index
        playStart = Date()
        isPlaying = true
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let target = self.playBase + Int(Date().timeIntervalSince(self.playStart) * self.reader.framesPerSecond)
            if target >= self.reader.frameCount - 1 {
                self.seek(to: self.reader.frameCount - 1)
                self.stop()
            } else if target != self.index {
                self.seek(to: target)
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isPlaying = false
    }

    /// The slider moved: pause and show that frame.
    func scrub(to i: Int) {
        if isPlaying { stop() }
        seek(to: i)
    }
}

struct MJPEGAVIPlayerView: View {
    @StateObject private var model: MJPEGAVIPlayerModel

    init(reader: MJPEGAVIReader) {
        _model = StateObject(wrappedValue: MJPEGAVIPlayerModel(reader: reader))
    }

    private func time(_ frame: Int) -> String {
        let s = Int(Double(frame) / model.reader.framesPerSecond)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                if let image = model.image {
                    Image(decorative: image, scale: 1)
                        .resizable().aspectRatio(contentMode: .fit)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { model.togglePlay() }

            HStack(spacing: 8) {
                Button { model.togglePlay() } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").frame(width: 14)
                }
                .buttonStyle(.plain)
                Slider(value: Binding(get: { Double(model.index) },
                                      set: { model.scrub(to: Int($0)) }),
                       in: 0...Double(max(model.reader.frameCount - 1, 1)))
                    .controlSize(.small)
                Text("\(time(model.index)) / \(time(model.reader.frameCount))")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.bar)
        }
        .onDisappear { model.stop() }
    }
}
