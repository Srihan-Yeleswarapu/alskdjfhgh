// Path: Features/iOS26/LiveActivities/SpeedActivityAttributes.swift
import ActivityKit
import Foundation

public struct SpeedActivityAttributes: ActivityAttributes {
    // [WATCH-DISABLED] Apple Watch Smart Stack support paused while iOS
    // fixes land — commented out (restore per WATCH_CHANGES_DISABLING docs).
    // /// [WATCH-SMART-STACK] Declares support for the watchOS 11 Smart Stack
    // /// "small" activity family so the system offers a wrist-sized rendering
    // /// of this Live Activity on a paired Apple Watch. Pairs with the
    // /// `.supplementalActivityFamilies([.small])` modifier on
    // /// `SpeedLiveActivityView` (WidgetKit silently drops a family that the
    // /// attributes struct does not also declare).
    // public static var supplementalActivityFamilies: [ActivityFamily] {
    //     if #available(watchOS 11.0, iOS 18.0, *) {
    //         return [.small]
    //     }
    //     return []
    // }

    public struct ContentState: Codable, Hashable {
        public var speed: Double
        public var speedLimit: Int
        public var status: String          // "safe" | "warning" | "over"
        public var isRecording: Bool
        public var consecutiveOverSeconds: Int
        public var sessionDuration: TimeInterval
        
        // Navigation metadata
        public var nextManeuver: String?
        public var nextManeuverImageName: String?
        public var distanceToNextTurn: Double?
        public var eta: Date?
    }
    
    public var sessionStartDate: Date
    public init(sessionStartDate: Date) {
        self.sessionStartDate = sessionStartDate
    }
}