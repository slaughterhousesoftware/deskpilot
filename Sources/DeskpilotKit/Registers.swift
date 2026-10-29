import Foundation

/// Register addresses of the Ergodriven Tempo. See docs/protocol.md.
public enum Register {
    public static let firmwareApplication: UInt32 = 4
    public static let firmwareBootloader: UInt32 = 8
    public static let firmwareSoftDevice: UInt32 = 12
    /// Writing this register's own value back reboots the desk into DFU. Never write it.
    public static let bootloaderMagic: UInt32 = 16
    public static let userCount: UInt32 = 20
    public static let cruiseSlotCount: UInt32 = 24
    public static let minutesSincePowerOn: UInt32 = 32
    public static let historySize: UInt32 = 36
    public static let historyWritePointer: UInt32 = 44
    public static let currentUser: UInt32 = 52
    public static let clock: UInt32 = 56
    public static let status: UInt32 = 60
    public static let historyBase: UInt32 = 0x10000
    public static let minuteWrap = 256

    public static func userBase(_ index: Int) -> UInt32 { index == 0 ? 4096 : 8192 }

    public enum UserOffset {
        public static let flags: UInt32 = 0
        public static let activeCruiseSlot: UInt32 = 4
        public static let countdownAndPulse: UInt32 = 8
        public static let middleOfNightHour: UInt32 = 12
        public static let standingHeight: UInt32 = 16
        public static let sittingHeight: UInt32 = 20
        public static let customHeightOne: UInt32 = 24
        public static let customHeightTwo: UInt32 = 28
        public static let moveCount: UInt32 = 40
        public static let userName: UInt32 = 256
        public static let presetNameOne: UInt32 = 320
        public static let presetNameTwo: UInt32 = 384
        public static let cruiseSlots: UInt32 = 512
        public static let cruiseSlotStride: UInt32 = 16
    }

    public static func cruiseSlotAddress(user: Int, slot: Int) -> UInt32 {
        userBase(user) + UserOffset.cruiseSlots + UInt32(slot) * UserOffset.cruiseSlotStride
    }
}

/// Register 60.
public struct StatusWord: Equatable, Sendable {
    public let heightTenths: Int
    public let isMoving: Bool

    public init(raw: UInt32) {
        heightTenths = Int(raw & 0xFFFF)
        isMoving = raw & 0x8000_0000 != 0
    }

    public var heightInches: Double { Double(heightTenths) / 10 }
}

/// User block offset 0. Bit order verified against the phone app's getUserInfo.
public struct UserFlags: OptionSet, Sendable, Equatable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let sitPresetSet = UserFlags(rawValue: 1 << 0)
    public static let standingPresetSet = UserFlags(rawValue: 1 << 1)
    public static let paused = UserFlags(rawValue: 1 << 2)
    public static let reserved = UserFlags(rawValue: 1 << 3)
    public static let pulseOnly = UserFlags(rawValue: 1 << 4)
    public static let userEnabled = UserFlags(rawValue: 1 << 5)
    public static let userSelected = UserFlags(rawValue: 1 << 6)
    public static let historyLogging = UserFlags(rawValue: 1 << 7)
}

public struct FirmwareVersion: Equatable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(raw: UInt32) {
        major = Int((raw >> 16) & 0xFF)
        minor = Int((raw >> 8) & 0xFF)
        patch = Int(raw & 0xFF)
    }

    public var description: String { "\(major).\(minor).\(patch)" }
}

/// Register 56: hour<<16 | minute<<8 | second.
public struct DeskClock: Equatable, Sendable {
    public let hour: Int
    public let minute: Int
    public let second: Int

    public init(raw: UInt32) {
        hour = Int((raw >> 16) & 0xFF)
        minute = Int((raw >> 8) & 0xFF)
        second = Int(raw & 0xFF)
    }

    public init(date: Date, calendar: Calendar = .current) {
        let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
        hour = parts.hour ?? 0
        minute = parts.minute ?? 0
        second = parts.second ?? 0
    }

    public var raw: UInt32 {
        UInt32(hour & 0xFF) << 16 | UInt32(minute & 0xFF) << 8 | UInt32(second & 0xFF)
    }
}
