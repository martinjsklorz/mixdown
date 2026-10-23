import Synchronization

/// One IO cycle as the IO thread saw it, stored in front of its samples in a `CaptureRing`.
/// Only raw values, so recording it needs no Core Audio or AVFoundation calls.
struct CapturedCycle: Equatable {
    /// The interleaved channels of the buffer, which the reader checks against the format.
    var channelCount: UInt32
    /// Which of the device's formats the cycle came in, see `FormatHistory`.
    var formatGeneration: Int
    /// The cycle's `AudioTimeStamp.mHostTime`, `nil` if it wasn't valid.
    var hostTime: UInt64?
    /// `mach_absolute_time()` when the cycle reached the IO block, the fallback if `hostTime`
    /// is missing or off.
    var arrivalHostTime: UInt64
}

/// A single-producer, single-consumer ring of IO cycles: the IO thread copies each cycle's
/// samples in, and a queue reads them out to convert and deliver.
///
/// Writing only copies bytes into memory allocated up front and updates atomics, so the IO
/// thread never allocates, takes a lock or waits. When the ring is full, the cycle is dropped
/// and counted. The timestamps of the cycles after it still put their samples in the right place.
///
/// `@unchecked Sendable`: `write` is only called from one thread at a time and `read` from one
/// other; the atomics order their access to `storage`.
final class CaptureRing: @unchecked Sendable {
    /// Room for about five seconds of 48 kHz stereo, plenty for the reader falling behind for a moment.
    static let defaultCapacity = 2 << 20

    // Computed rather than stored: a static `let` is initialized lazily behind a lock, which the
    // IO thread mustn't wait on.
    /// Records start on this alignment, so headers can be loaded in place.
    private static var alignment: Int { 16 }
    private static var headerSize: Int { align(MemoryLayout<Header>.size) }

    private struct Header {
        /// Payload bytes, or `wrapMarker` for a header that only says "continue at the start".
        var byteCount: Int
        var cycle: CapturedCycle
    }

    private static var wrapMarker: Int { -1 }

    let capacity: Int
    private let storage: UnsafeMutableRawPointer
    /// Bytes written and read since the start, wrapping skips included. Positions in `storage`
    /// are these modulo `capacity`.
    private let writeIndex = Atomic<Int>(0)
    private let readIndex = Atomic<Int>(0)
    private let dropped = Atomic<Int>(0)

    init(capacity: Int = CaptureRing.defaultCapacity) {
        precondition(capacity % Self.alignment == 0 && capacity > Self.headerSize)
        self.capacity = capacity
        storage = .allocate(byteCount: capacity, alignment: Self.alignment)
        // Touches every page now, so the IO thread doesn't page-fault on its first pass.
        storage.initializeMemory(as: UInt8.self, repeating: 0, count: capacity)
    }

    deinit { storage.deallocate() }

    /// IO cycles that didn't fit since the ring was created.
    var droppedCycles: Int { dropped.load(ordering: .relaxed) }

    // MARK: - Producer (IO thread)

    /// Copies one cycle in. Returns `false`, and counts it as dropped, if there's no room. A
    /// cycle up to half the capacity always fits an empty ring; a bigger one only at some offsets.
    @discardableResult
    func write(_ cycle: CapturedCycle, bytes: UnsafeRawBufferPointer) -> Bool {
        let size = Self.headerSize + Self.align(bytes.count)
        let start = writeIndex.load(ordering: .relaxed)
        let free = capacity - (start - readIndex.load(ordering: .acquiring))
        var position = start % capacity
        let tail = capacity - position
        // A record never wraps around the end, so the reader gets its samples in one piece.
        let skip = size > tail ? tail : 0
        guard size <= capacity, skip + size <= free else {
            dropped.add(1, ordering: .relaxed)
            return false
        }

        if skip > 0 {
            if tail >= Self.headerSize {
                storeHeader(Header(byteCount: Self.wrapMarker, cycle: cycle), at: position)
            }
            position = 0
        }
        storeHeader(Header(byteCount: bytes.count, cycle: cycle), at: position)
        if let base = bytes.baseAddress {
            (storage + position + Self.headerSize).copyMemory(from: base, byteCount: bytes.count)
        }
        writeIndex.store(start + skip + size, ordering: .releasing)
        return true
    }

    // MARK: - Consumer

    /// Calls `body` with the oldest cycle and its samples, then frees its room. The bytes are
    /// only valid inside `body`. Returns `false` if the ring is empty.
    @discardableResult
    func read(_ body: (CapturedCycle, UnsafeRawBufferPointer) -> Void) -> Bool {
        var start = readIndex.load(ordering: .relaxed)
        let end = writeIndex.load(ordering: .acquiring)
        while start < end {
            let position = start % capacity
            let tail = capacity - position
            // Too little room at the end for a header: the writer skipped it without a marker.
            guard tail >= Self.headerSize else {
                start += tail
                continue
            }
            let header = storage.load(fromByteOffset: position, as: Header.self)
            guard header.byteCount != Self.wrapMarker else {
                start += tail
                continue
            }
            body(
                header.cycle,
                UnsafeRawBufferPointer(start: storage + position + Self.headerSize, count: header.byteCount)
            )
            readIndex.store(start + Self.headerSize + Self.align(header.byteCount), ordering: .releasing)
            return true
        }
        // Only skips were left; free their room too.
        readIndex.store(start, ordering: .releasing)
        return false
    }

    /// Reads cycles until the ring is empty and returns how many there were.
    @discardableResult
    func readAll(_ body: (CapturedCycle, UnsafeRawBufferPointer) -> Void) -> Int {
        var count = 0
        while read(body) { count += 1 }
        return count
    }

    // MARK: - Helpers

    private func storeHeader(_ header: Header, at position: Int) {
        storage.storeBytes(of: header, toByteOffset: position, as: Header.self)
    }

    private static func align(_ byteCount: Int) -> Int {
        (byteCount + alignment - 1) / alignment * alignment
    }
}
