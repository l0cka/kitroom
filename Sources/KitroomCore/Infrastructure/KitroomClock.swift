import Foundation

public protocol KitroomClock: Sendable {
    var now: Date { get }
}

public struct SystemKitroomClock: KitroomClock {
    public init() {}

    public var now: Date {
        Date()
    }
}

public struct FixedKitroomClock: KitroomClock {
    public let now: Date

    public init(now: Date) {
        self.now = now
    }
}
