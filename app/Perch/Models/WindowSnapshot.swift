import CoreGraphics
import Foundation

struct CodableRect: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    init(_ rect: CGRect) {
        self.init(
            x: Double(rect.origin.x),
            y: Double(rect.origin.y),
            width: Double(rect.size.width),
            height: Double(rect.size.height)
        )
    }

    init(cgRect rect: CGRect) {
        self.init(rect)
    }

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }

    private enum CodingKeys: String, CodingKey {
        case x
        case y
        case width = "w"
        case height = "h"
    }
}

struct WindowSnapshot: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var bundleIdentifier: String
    var windowTitle: String
    var frame: CodableRect
    var displayUUID: String?
    var displayLocalFrame: CodableRect?
    var windowRole: String
    var processIdentifier: Int32
    var cgWindowID: UInt32?
    var accessibilityIdentifier: String?
    var capturedAt: Date

    init(
        id: String = UUID().uuidString,
        bundleIdentifier: String,
        windowTitle: String,
        frame: CodableRect,
        displayUUID: String?,
        displayLocalFrame: CodableRect?,
        windowRole: String,
        processIdentifier: Int32,
        capturedAt: Date,
        cgWindowID: UInt32? = nil,
        accessibilityIdentifier: String? = nil
    ) {
        self.id = id
        self.bundleIdentifier = bundleIdentifier
        self.windowTitle = windowTitle
        self.frame = frame
        self.displayUUID = displayUUID
        self.displayLocalFrame = displayLocalFrame
        self.windowRole = windowRole
        self.processIdentifier = processIdentifier
        self.cgWindowID = cgWindowID
        self.accessibilityIdentifier = accessibilityIdentifier
        self.capturedAt = capturedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case bundleIdentifier = "bundleId"
        case windowTitle = "title"
        case frame
        case displayUUID
        case displayLocalFrame
        case windowRole = "role"
        case processIdentifier
        case cgWindowID
        case accessibilityIdentifier = "axIdentifier"
        case capturedAt
    }
}
