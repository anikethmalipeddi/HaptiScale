//
//  MotionCapture.swift
//  HaptiScale
//
//  Core Motion at the 100 Hz hardware cap on a dedicated high-priority queue.
//  Delivers gravity-separated userAcceleration + rotationRate + gravity, timestamped
//  against the same host clock as audio for cross-modal alignment. Treated as a
//  low-rate corroborating channel (it aliases the Taptic band). See §3.
//

import Foundation
import CoreMotion

final class MotionCapture {

    private let manager = CMMotionManager()
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "com.haptiscale.motion"
        q.qualityOfService = .userInteractive
        q.maxConcurrentOperationCount = 1
        return q
    }()

    private var samples = [IMUSample]()
    private let lock = NSLock()
    private var collecting = false

    var isAvailable: Bool { manager.isDeviceMotionAvailable }

    /// Begins delivering device-motion updates. Samples accumulate only while
    /// `collecting` is true (toggled per burst).
    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 0.01   // 100 Hz — documented cap
        manager.showsDeviceMovementDisplay = false
        manager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: queue) { [weak self] motion, _ in
            guard let self, let m = motion, self.collecting else { return }
            let sample = IMUSample(
                t: m.timestamp,
                ax: m.userAcceleration.x, ay: m.userAcceleration.y, az: m.userAcceleration.z,
                gx: m.rotationRate.x, gy: m.rotationRate.y, gz: m.rotationRate.z,
                gravityX: m.gravity.x, gravityY: m.gravity.y, gravityZ: m.gravity.z)
            self.lock.lock()
            self.samples.append(sample)
            self.lock.unlock()
        }
    }

    func stop() {
        if manager.isDeviceMotionActive { manager.stopDeviceMotionUpdates() }
    }

    /// Clears buffered samples and begins accumulating.
    func armCollection() {
        lock.lock(); samples.removeAll(keepingCapacity: true); collecting = true; lock.unlock()
    }

    /// Stops accumulating and returns everything collected.
    func drain() -> [IMUSample] {
        lock.lock()
        collecting = false
        let out = samples
        samples.removeAll(keepingCapacity: true)
        lock.unlock()
        return out
    }

    /// Instantaneous tilt from horizontal (degrees), for pre-measurement checks.
    func currentTiltDegrees() -> Double? {
        guard let g = manager.deviceMotion?.gravity else { return nil }
        return acos(min(1, max(-1, abs(g.z)))) * 180.0 / Double.pi
    }
}
