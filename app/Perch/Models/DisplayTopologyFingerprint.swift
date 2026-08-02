import CoreGraphics
import Foundation

/// Persistable description of the displays that make up a layout.
///
/// Bounds are retained for diagnostics, but layout matching deliberately uses
/// only display UUIDs and the main-display marker. macOS can slightly adjust
/// display bounds while renegotiating a resolution without changing the actual
/// display arrangement.
struct DisplayTopologyFingerprint: Codable, Equatable, Hashable, Sendable {
    struct Entry: Codable, Equatable, Hashable, Sendable {
        var uuid: String
        var bounds: CGRect
        var isMain: Bool

        init(uuid: String, bounds: CGRect, isMain: Bool) {
            self.uuid = uuid
            self.bounds = bounds
            self.isMain = isMain
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            uuid = try container.decode(String.self, forKey: .uuid)
            bounds = try container.decode(CodableRect.self, forKey: .bounds).cgRect
            isMain = try container.decode(Bool.self, forKey: .isMain)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(uuid, forKey: .uuid)
            try container.encode(CodableRect(bounds), forKey: .bounds)
            try container.encode(isMain, forKey: .isMain)
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(uuid)
            hasher.combine(Double(bounds.origin.x))
            hasher.combine(Double(bounds.origin.y))
            hasher.combine(Double(bounds.size.width))
            hasher.combine(Double(bounds.size.height))
            hasher.combine(isMain)
        }

        private enum CodingKeys: String, CodingKey {
            case uuid
            case bounds
            case isMain
        }
    }

    var entries: [Entry]

    init(displays: [DisplayInfo]) {
        self.init(entries: displays.map {
            Entry(uuid: $0.uuid, bounds: $0.bounds, isMain: $0.isMain)
        })
    }

    init(entries: [Entry]) {
        self.entries = entries.sorted { $0.uuid < $1.uuid }
    }

    /// Stable, order-independent identity of a display arrangement.
    /// The main display is marked with a trailing asterisk.
    var identity: String {
        entries
            .map { $0.uuid + ($0.isMain ? "*" : "") }
            .joined(separator: "|")
    }

    /// Matches a display arrangement without depending on its exact bounds.
    func matchesIdentity(of other: DisplayTopologyFingerprint) -> Bool {
        identity == other.identity
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(entries: try container.decode([Entry].self, forKey: .entries))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(entries, forKey: .entries)
    }

    private enum CodingKeys: String, CodingKey {
        case entries
    }
}
