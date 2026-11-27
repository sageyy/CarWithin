import CoreImage
import Foundation

/// Thread-safe background flag so video queues can choose a renderer without touching UIKit.
enum RenderState {
    private static let lock = NSLock()
    private static var background = false

    static var isBackground: Bool {
        lock.lock(); defer { lock.unlock() }
        return background
    }

    static func setBackground(_ value: Bool) {
        lock.lock(); background = value; lock.unlock()
    }
}

/// Foreground uses GPU/Metal for cheap scaling; background forces software rendering because
/// a backgrounded iOS app cannot rely on a GPU CIContext. Both contexts are created lazily.
final class AdaptiveCompositor {
    private lazy var gpu = CIContext(options: [.cacheIntermediates: false])
    private lazy var software = CIContext(options: [.cacheIntermediates: false, .useSoftwareRenderer: true])

    var context: CIContext { RenderState.isBackground ? software : gpu }
}
