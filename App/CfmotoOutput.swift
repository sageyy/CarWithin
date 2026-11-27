import CoreImage
import Foundation
import VideoToolbox

/// 春风仪表（HUName 形如 CFMOTO-xxxxxx）的输出规格。
/// 仪表原生像素：5 寸 800×386，6.2 寸 1024×515；H.264 4:2:0 要求偶数，
/// 1024×515 按 1024×516 编码，协议里回给仪表的就是实际编码尺寸。
struct CfmotoProfile: Equatable {
    let width: Int
    let height: Int
    let fps: Int
    let bitrate: Int
    let label: String
    /// 协商尺寸的持久化前缀；春风与张雪各自记住自己的仪表尺寸。
    let storageKey: String

    static let fiveInch = CfmotoProfile(width: 800, height: 386, fps: 30, bitrate: 3_500_000, label: "春风 5 寸", storageKey: "cfmoto")
    static let sixInch = CfmotoProfile(width: 1024, height: 515, fps: 30, bitrate: 4_500_000, label: "春风 6.2 寸", storageKey: "cfmoto")

    /// 张雪（ZXMOTO）仪表与春风共用 PXC 协议。公开资料确认：500RR 为 5 寸 TFT，
    /// 820RR / 820R 为 6.2 寸 TFT，均支持手机连接与导航投屏；这里保留实测像素
    /// 500RR 800×386、820RR / 820R 1024×515，实际编码尺寸仍以仪表媒体协商上报为准。
    static let zhangxue500RR = CfmotoProfile(width: 800, height: 386, fps: 30, bitrate: 3_500_000, label: "张雪 500RR", storageKey: "zhangxue")
    static let zhangxue820RR = CfmotoProfile(width: 1024, height: 515, fps: 30, bitrate: 4_500_000, label: "张雪 820RR", storageKey: "zhangxue")
    static let zhangxue820R = CfmotoProfile(width: 1024, height: 515, fps: 30, bitrate: 4_500_000, label: "张雪 820R", storageKey: "zhangxue")

    /// 自适应入口：初始按 1024×515 规划画面，连上仪表后改用握手上报的尺寸。
    static let adaptiveCfmoto = CfmotoProfile(width: 1024, height: 515, fps: 30, bitrate: 4_500_000, label: "春风仪表", storageKey: "cfmoto")
    static let adaptiveZhangxue = CfmotoProfile(width: 1024, height: 515, fps: 30, bitrate: 4_500_000, label: "张雪仪表", storageKey: "zhangxue")

    /// 按实际编码像素数推导码率：以 1024×515 @ 4.5Mbps 为基准，限制在 3–12Mbps。
    static func bitrate(for width: Int, height: Int) -> Int {
        let pixels = Double(max(1, width * height))
        let scaled = 4_500_000.0 * pixels / (1024.0 * 515.0)
        return min(12_000_000, max(3_000_000, Int(scaled)))
    }

    /// 上次握手成功记录的仪表尺寸，供下次启动 CarPlay 前规划原生分辨率。
    func negotiatedDisplaySize() -> (width: Int, height: Int)? {
        let defaults = UserDefaults.standard
        var width = defaults.integer(forKey: storageKey + "MediaWidth")
        var height = defaults.integer(forKey: storageKey + "MediaHeight")
        // 旧版统一用 cfmotoMedia*；春风沿用该值，张雪首次连接会写入自己的 key。
        if width == 0 || height == 0 {
            width = defaults.integer(forKey: "cfmotoMediaWidth")
            height = defaults.integer(forKey: "cfmotoMediaHeight")
        }
        guard (320...3840).contains(width), (320...3840).contains(height),
              width % 2 == 0, height % 2 == 0, width * height <= 3840 * 2160 else { return nil }
        return (width, height)
    }

    func saveNegotiatedDisplaySize(width: Int, height: Int) {
        let safeWidth = min(3840, max(320, width - width % 2))
        let safeHeight = min(3840, max(320, height - height % 2))
        guard safeWidth * safeHeight <= 3840 * 2160 else { return }
        let defaults = UserDefaults.standard
        defaults.set(safeWidth, forKey: storageKey + "MediaWidth")
        defaults.set(safeHeight, forKey: storageKey + "MediaHeight")
    }

    var encodeWidth: Int { width - width % 2 }
    var encodeHeight: Int { height % 2 == 0 ? height : height + 1 }
    var title: String { "\(width)×\(height)" }

    /// 仪表在 PXC 媒体配置里报的尺寸按 16 对齐（800×386 → 800×384，1024×515 → 1024×512）。
    var pxcWidth: Int { width & ~0xF }
    var pxcHeight: Int { height & ~0xF }
}

/// 春风仪表投屏输出：把 CarPlay 的 H.264 解回像素，缩放成仪表尺寸重新编码，
/// 再按仪表逐帧请求（PXC 协议，10920/10921/10922）送过去。
/// 握手、身份、SN 校验、媒体配置全部由 PxcConnection 负责。
final class CfmotoOutput {
    private let queue: DispatchQueue
    private let sessionLock = NSLock()
    private var session: Session?

    init(name: String = "cfmoto") {
        queue = DispatchQueue(label: "CarWithin.\(name)", qos: .userInitiated)
    }

    deinit { stop() }

    func start(localAddress: String, targetAddress: String, phone: TailingPhoneInfo, profile: CfmotoProfile,
               onState: @escaping (String) -> Void, onLog: @escaping (String) -> Void,
               requestKeyframe: @escaping () -> Void,
               onMediaSize: @escaping (Int, Int) -> Void,
               onConnectionFailed: @escaping () -> Void) {
        stop()
        let next = Session(queue: queue, localAddress: localAddress, targetAddress: targetAddress,
                           phone: phone, profile: profile,
                           onState: onState, onLog: onLog, requestKeyframe: requestKeyframe,
                           onMediaSize: onMediaSize, onConnectionFailed: onConnectionFailed)
        sessionLock.lock()
        session = next
        sessionLock.unlock()
        next.start()
    }

    func append(_ data: Data, codec: VideoCodec, keyframe: Bool) {
        guard codec == .h264 else { return }
        sessionLock.lock()
        let current = session
        sessionLock.unlock()
        current?.append(data, keyframe: keyframe)
    }

    func stop() {
        sessionLock.lock()
        guard let previous = session else { sessionLock.unlock(); return }
        session = nil
        sessionLock.unlock()
        previous.cancel()
        queue.async { previous.close() }
    }

    private final class Session: @unchecked Sendable {
        let queue: DispatchQueue
        let profile: CfmotoProfile
        let onState: (String) -> Void
        let onLog: (String) -> Void
        let requestKeyframe: () -> Void
        let onMediaSize: (Int, Int) -> Void
        let onConnectionFailed: () -> Void
        private let lock = NSLock()
        private var cancelled = false
        private var acceptingFrames = true
        private var queued = 0
        private var queuedBytes = 0
        /// ~300ms of input at the negotiated bitrate, clamped to 1–6MB. Recomputed on handshake.
        private var maximumQueuedBytes = 4 * 1024 * 1024
        /// ~250ms of frames at the profile FPS; avoids early skipping on high-resolution software decode.
        private var maximumQueuedFrames = 6
        private var skipping = false
        private var decoded: CVPixelBuffer?
        private var decodeError: Error?
        private var encoded: Result<H264EncodedFrame, Error>?

        private var encodeWidth: Int
        private var encodeHeight: Int
        private var bitrate: Int
        private let connection: PxcConnection
        private var decoder: TailingH264Decoder?
        private var encoder: H264Encoder?
        private var parameters = VideoParameterSets(codec: .h264)
        private var waitingForIDR = true
        private var latest: CVPixelBuffer?
        private lazy var compositor = AdaptiveCompositor()
        private var lastKeyframe = -Double.infinity
        private var lastCodecFailure = -Double.infinity
        private var status = ""

        init(queue: DispatchQueue, localAddress: String, targetAddress: String, phone: TailingPhoneInfo,
             profile: CfmotoProfile, onState: @escaping (String) -> Void, onLog: @escaping (String) -> Void,
             requestKeyframe: @escaping () -> Void, onMediaSize: @escaping (Int, Int) -> Void,
             onConnectionFailed: @escaping () -> Void) {
            self.queue = queue
            self.profile = profile
            self.encodeWidth = profile.pxcWidth
            self.encodeHeight = profile.pxcHeight
            self.bitrate = profile.bitrate
            self.connection = PxcConnection(localIP: localAddress, targetIP: targetAddress,
                                            phone: phone, dashboard: profile.label, log: onLog)
            self.onState = onState
            self.onLog = onLog
            self.requestKeyframe = requestKeyframe
            self.onMediaSize = onMediaSize
            self.onConnectionFailed = onConnectionFailed
        }

        func start() {
            report("正在连接\(profile.label)仪表…")
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                do {
                    try connection.start()
                    guard active else { return }
                    let size = connection.mediaSize
                    queue.sync {
                        self.encodeWidth = size.width
                        self.encodeHeight = size.height
                        let rate = CfmotoProfile.bitrate(for: size.width, height: size.height)
                        self.bitrate = rate
                        // 300ms of input bytes; 1–6MB keeps memory bounded even at 12Mbps.
                        let windowBytes = rate / 8 * 3 / 10
                        self.maximumQueuedBytes = max(1024 * 1024, min(6 * 1024 * 1024, windowBytes))
                        // ~250ms of frames; higher-resolution software decode needs a little more slack.
                        self.maximumQueuedFrames = max(6, min(12, profile.fps / 4))
                    }
                    profile.saveNegotiatedDisplaySize(width: size.width, height: size.height)
                    onMediaSize(size.width, size.height)
                    report("仪表已连接，等待 CarPlay 画面…")
                    var first = true
                    var nextFrame = ProcessInfo.processInfo.systemUptime
                    while active {
                        try connection.checkHealth()
                        let ready = queue.sync { latest != nil }
                        if !ready { Thread.sleep(forTimeInterval: 0.05); continue }
                        let remaining = nextFrame - ProcessInfo.processInfo.systemUptime
                        if remaining > 0 { Thread.sleep(forTimeInterval: min(remaining, 0.04)); continue }
                        guard connection.waitForH264Request() else {
                            report("等待仪表拉帧 · 链路保持中")
                            continue
                        }
                        nextFrame = ProcessInfo.processInfo.systemUptime + 1.0 / Double(profile.fps)
                        guard active else { break }
                        let result = queue.sync { () -> H264EncodedFrame? in
                            guard active, let image = latest else { return nil }
                            return encode(image, at: ProcessInfo.processInfo.systemUptime, forceKeyframe: first)
                        }
                        guard let result else {
                            // 仪表已经拉帧，这里保留请求，等一帧可编码画面用关键帧补上。
                            var recovered: H264EncodedFrame?
                            for _ in 0..<20 where active && recovered == nil {
                                Thread.sleep(forTimeInterval: 0.05)
                                recovered = queue.sync {
                                    guard let image = latest else { return nil }
                                    return encode(image, at: ProcessInfo.processInfo.systemUptime, forceKeyframe: true)
                                }
                            }
                            guard let recovered else { throw TailingError.timeout("等待 H.264 编码画面") }
                            guard connection.sendH264(recovered.data) else { continue }
                            first = false
                            report("正在投屏 · \(profile.title) · H.264")
                            continue
                        }
                        guard connection.sendH264(result.data) else { continue }
                        first = false
                        report("正在投屏 · \(profile.title) · H.264")
                    }
                } catch {
                    if active {
                        onLog("\(profile.label)输出失败：\(error.localizedDescription)")
                        report("\(profile.label)连接失败：\(error.localizedDescription)")
                        onConnectionFailed()
                    }
                }
                connection.close()
                queue.async { [self] in close() }
            }
        }

        private var active: Bool { lock.withLock { !cancelled } }

        func cancel() { lock.withLock { cancelled = true }; connection.close() }

        func append(_ data: Data, keyframe: Bool) {
            let (accepted, needsKeyframe) = lock.withLock {
                guard !cancelled, acceptingFrames else { return (false, false) }
                if queued >= maximumQueuedFrames || queuedBytes + data.count > maximumQueuedBytes {
                    let request = !skipping || queuedBytes > maximumQueuedBytes / 2
                    skipping = true
                    return (false, request)
                }
                guard !skipping || keyframe else { return (false, false) }
                skipping = false
                queued += 1
                queuedBytes += data.count
                return (true, false)
            }
            if needsKeyframe { requestKeyframe() }
            guard accepted else { return }
            queue.async { [self] in
                defer { lock.withLock { queued -= 1; queuedBytes = max(0, queuedBytes - data.count) } }
                guard lock.withLock({ !cancelled && acceptingFrames }) else { return }
                autoreleasepool { decode(data, keyframe: keyframe) }
            }
        }

        private func decode(_ data: Data, keyframe: Bool) {
            do {
                var picture: [Data] = []
                for unit in try AnnexB.units(in: data) {
                    if VideoCodec.h264.parameterSet(unit) != nil {
                        if parameters.absorb(unit) { waitingForIDR = true }
                    } else { picture.append(unit) }
                }
                if waitingForIDR {
                    guard parameters.isComplete, keyframe, !picture.isEmpty else { return }
                    guard ProcessInfo.processInfo.systemUptime - lastCodecFailure >= 0.5 else {
                        requestKeyframe()
                        return
                    }
                    decoder?.invalidate()
                    decoder = try TailingH264Decoder(configuration: parameters.decoderConfigurationRecord(),
                        output: { [weak self] image in
                            guard let self else { return }
                            self.lock.withLock { self.decoded = image }
                        }, failure: { [weak self] error in
                            guard let self else { return }
                            self.lock.withLock { self.decodeError = error }
                        })
                    waitingForIDR = false
                }
                guard let decoder, !picture.isEmpty else { return }
                try decoder.decode(AnnexB.lengthPrefixed(picture),
                    presentationTimeMicroseconds: Int64(ProcessInfo.processInfo.systemUptime * 1_000_000), isKeyframe: keyframe)
                decoder.waitForFrames()
                let (image, error) = lock.withLock {
                    defer { decoded = nil; decodeError = nil }
                    return (decoded, decodeError)
                }
                if let error { throw error }
                if let image { latest = image }
            } catch {
                decoder?.invalidate()
                decoder = nil
                lock.withLock { decoded = nil; decodeError = nil }
                waitingForIDR = true
                logCodecFailure("解码", error)
                requestKeyframe()
            }
        }

        private func encode(_ image: CVPixelBuffer, at now: Double, forceKeyframe: Bool) -> H264EncodedFrame? {
            autoreleasepool {
                do {
                    if encoder == nil {
                        guard now - lastCodecFailure >= 0.5 else { return nil }
                        encoder = try H264Encoder(width: encodeWidth, height: encodeHeight,
                                                  fps: profile.fps, bitrate: bitrate) { [weak self] result in
                            guard let self else { return }
                            self.lock.withLock { self.encoded = result }
                        }
                        lastKeyframe = -.infinity
                    }
                    guard let encoder else { return nil }
                    let stamp = CMTime(seconds: now, preferredTimescale: 1_000_000)
                    try encoder.encode(try fittedImage(image), presentationTime: stamp,
                                       forceKeyframe: forceKeyframe || lastKeyframe == -.infinity)
                    encoder.complete()
                    let result = lock.withLock {
                        defer { encoded = nil }
                        return encoded
                    }
                    let frame = try result?.get()
                    if frame?.isKeyframe == true { lastKeyframe = now }
                    return frame
                } catch H264EncoderError.frameDropped {
                    return nil
                } catch {
                    encoder?.invalidate()
                    encoder = nil
                    lastKeyframe = -.infinity
                    lock.withLock { encoded = nil }
                    logCodecFailure("编码", error)
                    return nil
                }
            }
        }

        private func fittedImage(_ image: CVPixelBuffer) throws -> CVPixelBuffer {
            let width = encodeWidth, height = encodeHeight
            if CVPixelBufferGetWidth(image) == width, CVPixelBufferGetHeight(image) == height { return image }
            var buffer: CVPixelBuffer?
            let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                             [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
            guard status == kCVReturnSuccess, let buffer else {
                throw ConfigurationError("无法分配\(profile.label)缩放画面（\(status)）")
            }
            let source = CIImage(cvPixelBuffer: image)
            let scale = min(CGFloat(width) / source.extent.width, CGFloat(height) / source.extent.height)
            let scaled = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let positioned = scaled.transformed(by: CGAffineTransform(
                translationX: (CGFloat(width) - scaled.extent.width) / 2,
                y: (CGFloat(height) - scaled.extent.height) / 2))
            let bounds = CGRect(x: 0, y: 0, width: width, height: height)
            compositor.context.render(positioned.composited(over: CIImage(color: .black)).cropped(to: bounds),
                                      to: buffer, bounds: bounds, colorSpace: CGColorSpaceCreateDeviceRGB())
            return buffer
        }

        private func logCodecFailure(_ stage: String, _ error: Error) {
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastCodecFailure > 4 { onLog("\(profile.label)\(stage)恢复：\(error.localizedDescription)") }
            lastCodecFailure = now
        }

        private func report(_ message: String) {
            guard active, message != status else { return }
            status = message
            DispatchQueue.main.async { [weak self] in
                guard let self, self.active else { return }
                self.onState(message)
            }
        }

        func close() {
            lock.withLock { acceptingFrames = false }
            connection.close()
            decoder?.invalidate()
            decoder = nil
            encoder?.invalidate()
            encoder = nil
            latest = nil
        }
    }
}
