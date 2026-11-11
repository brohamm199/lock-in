import CoreMotion
import Foundation

/// Uses the motion sensors to tell when the phone gets picked up, and when it's been set back down.
/// Callbacks arrive on the main queue.
final class PickupDetector {
    var onPickup: (() -> Void)?
    var onSettled: (() -> Void)?

    private let manager = CMMotionManager()
    private var baseline: CMAcceleration?
    private var stillSince: Date?
    private(set) var pickedUp = false

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        baseline = nil
        stillSince = nil
        pickedUp = false
        manager.deviceMotionUpdateInterval = 0.1
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let motion else { return }
            self.process(motion)
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
    }

    private func process(_ motion: CMDeviceMotion) {
        let g = motion.gravity
        let a = motion.userAcceleration
        let r = motion.rotationRate
        let accel = (a.x * a.x + a.y * a.y + a.z * a.z).squareRoot()
        let spin = (r.x * r.x + r.y * r.y + r.z * r.z).squareRoot()

        guard let base = baseline else {
            baseline = g
            return
        }

        let angle = Self.angleBetween(g, base)
        let isStill = accel < 0.03 && spin < 0.05

        if pickedUp {
            if isStill {
                if let since = stillSince {
                    if Date().timeIntervalSince(since) >= 3 {
                        pickedUp = false
                        stillSince = nil
                        baseline = g
                        onSettled?()
                    }
                } else {
                    stillSince = Date()
                }
            } else {
                stillSince = nil
            }
        } else if angle > 18 || accel > 0.4 {
            pickedUp = true
            stillSince = nil
            onPickup?()
        } else if isStill {
            // Follow tiny drift (phone slowly sliding on a stand) without calling it a pickup.
            baseline = CMAcceleration(
                x: base.x * 0.98 + g.x * 0.02,
                y: base.y * 0.98 + g.y * 0.02,
                z: base.z * 0.98 + g.z * 0.02
            )
        }
    }

    private static func angleBetween(_ a: CMAcceleration, _ b: CMAcceleration) -> Double {
        let dot = a.x * b.x + a.y * b.y + a.z * b.z
        let mags = (a.x * a.x + a.y * a.y + a.z * a.z).squareRoot() * (b.x * b.x + b.y * b.y + b.z * b.z).squareRoot()
        guard mags > 0.0001 else { return 0 }
        return acos(max(-1, min(1, dot / mags))) * 180 / .pi
    }
}
