@preconcurrency import ApplicationServices
import Foundation

/// Shared decoding for batched AX reads. Call only on the AX worker actors.
enum AccessibilityValues {
    enum AXAttributeReadResult {
        case values([Any])
        case cannotComplete
        case failed
    }

    static func copyAttributes(
        _ attributes: [String],
        from element: AXUIElement
    ) -> AXAttributeReadResult {
        var rawValues: CFArray?
        let error = AXUIElementCopyMultipleAttributeValues(
            element,
            attributes as CFArray,
            [],
            &rawValues
        )

        if error == .cannotComplete {
            return .cannotComplete
        }

        guard error == .success, let values = rawValues as? [Any] else {
            return .failed
        }

        if values.contains(where: { embeddedAXError(in: $0) == .cannotComplete }) {
            return .cannotComplete
        }

        return .values(values)
    }

    static func embeddedAXError(in value: Any) -> AXError? {
        let cfValue = value as CFTypeRef
        guard CFGetTypeID(cfValue) == AXValueGetTypeID() else {
            return nil
        }

        let axValue = unsafeDowncast(cfValue, to: AXValue.self)
        guard AXValueGetType(axValue) == .axError else {
            return nil
        }

        var error = AXError.success
        return AXValueGetValue(axValue, .axError, &error) ? error : nil
    }

    static func value<T>(at index: Int, in values: [Any], as type: T.Type) -> T? {
        guard values.indices.contains(index) else {
            return nil
        }

        return values[index] as? T
    }

    static func frame(positionValue: Any?, sizeValue: Any?) -> CGRect? {
        guard
            let position = point(from: positionValue),
            let size = size(from: sizeValue)
        else {
            return nil
        }

        return CGRect(origin: position, size: size)
    }

    static func point(from value: Any?) -> CGPoint? {
        guard let value else {
            return nil
        }

        let cfValue = value as CFTypeRef
        guard CFGetTypeID(cfValue) == AXValueGetTypeID() else {
            return nil
        }

        let axValue = unsafeDowncast(cfValue, to: AXValue.self)
        guard AXValueGetType(axValue) == .cgPoint else {
            return nil
        }

        var point = CGPoint.zero
        return AXValueGetValue(axValue, .cgPoint, &point) ? point : nil
    }

    static func size(from value: Any?) -> CGSize? {
        guard let value else {
            return nil
        }

        let cfValue = value as CFTypeRef
        guard CFGetTypeID(cfValue) == AXValueGetTypeID() else {
            return nil
        }

        let axValue = unsafeDowncast(cfValue, to: AXValue.self)
        guard AXValueGetType(axValue) == .cgSize else {
            return nil
        }

        var size = CGSize.zero
        return AXValueGetValue(axValue, .cgSize, &size) ? size : nil
    }

}
