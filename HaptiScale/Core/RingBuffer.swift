//
//  RingBuffer.swift
//  HaptiScale
//
//  Single-producer / single-consumer float ring buffer. The audio render thread
//  (producer) only does a bounded memcpy under an `os_unfair_lock`; the DSP consumer
//  snapshots on a utility queue. No allocation happens on the producer path, so the
//  critical section is a few microseconds. See §9 threading notes.
//

import Foundation
import os

/// A fixed-capacity SPSC ring buffer of Float samples.
///
/// Capacity is rounded up to a power of two for cheap index masking. A full buffer
/// means the consumer fell behind; the overflow count is exposed as a dropout signal.
final class RingBuffer {

    private var storage: [Float]
    private let mask: Int
    private let capacity: Int

    private var writeIndex = 0
    private var readIndex = 0
    private(set) var overflowCount = 0

    private var lock = os_unfair_lock_s()

    init(capacity requested: Int) {
        var cap = 1
        while cap < requested { cap <<= 1 }
        self.capacity = cap
        self.mask = cap - 1
        self.storage = [Float](repeating: 0, count: cap)
    }

    /// Producer side. Writes as many samples as fit; counts the remainder as an
    /// overflow. Bounded work, no allocation.
    func write(_ src: UnsafePointer<Float>, count: Int) {
        os_unfair_lock_lock(&lock)
        let free = capacity - (writeIndex - readIndex)
        let toWrite = min(count, free)
        for i in 0..<toWrite {
            storage[(writeIndex + i) & mask] = src[i]
        }
        writeIndex += toWrite
        if toWrite < count { overflowCount += count - toWrite }
        os_unfair_lock_unlock(&lock)
    }

    /// Number of samples currently available to read.
    var availableToRead: Int {
        os_unfair_lock_lock(&lock)
        let n = writeIndex - readIndex
        os_unfair_lock_unlock(&lock)
        return n
    }

    /// Consumer side. Copies up to `max` samples out and advances the read index.
    func read(max: Int) -> [Float] {
        os_unfair_lock_lock(&lock)
        let toRead = Swift.min(max, writeIndex - readIndex)
        guard toRead > 0 else {
            os_unfair_lock_unlock(&lock)
            return []
        }
        var out = [Float](repeating: 0, count: toRead)
        for i in 0..<toRead {
            out[i] = storage[(readIndex + i) & mask]
        }
        readIndex += toRead
        os_unfair_lock_unlock(&lock)
        return out
    }

    /// Non-destructive snapshot of the most recent `count` samples (for live UI).
    func snapshotLatest(count: Int) -> [Float] {
        os_unfair_lock_lock(&lock)
        let available = writeIndex - readIndex
        let toRead = Swift.min(count, available)
        let start = writeIndex - toRead
        var out = [Float](repeating: 0, count: toRead)
        for i in 0..<toRead {
            out[i] = storage[(start + i) & mask]
        }
        os_unfair_lock_unlock(&lock)
        return out
    }

    /// Discards everything currently buffered (used when re-arming a capture).
    func reset() {
        os_unfair_lock_lock(&lock)
        readIndex = writeIndex
        overflowCount = 0
        os_unfair_lock_unlock(&lock)
    }
}
