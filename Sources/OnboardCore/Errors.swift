import Foundation

public struct OnboardError: Error, LocalizedError, CustomStringConvertible {
    public let message: String
    public init(_ m: String) { message = m }
    public var errorDescription: String? { message }
    public var description: String { message }
}
