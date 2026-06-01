import Foundation

public func diagnosticsDeviceName(_ name: String, verbose: Bool) -> String {
    verbose ? name : "<redacted>"
}

public func diagnosticsIdentifier(_ identifier: String, verbose: Bool) -> String {
    guard !verbose else {
        return identifier
    }
    guard !identifier.isEmpty else {
        return "<empty>"
    }
    guard identifier.count > 8 else {
        return "<redacted>"
    }
    return "\(identifier.prefix(4))...\(identifier.suffix(4))"
}
