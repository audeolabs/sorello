import Foundation

/// The shared JSON vectors in `Tests/Vectors`. Sorello and the Linux port run the same files, so a rule cannot
/// drift on one platform without a test failing on the other.
public enum Vectors {
    public static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Vectors", isDirectory: true)

    public static func data(_ name: String) throws -> Data {
        try Data(contentsOf: directory.appendingPathComponent(name))
    }

    public static func decode<Value: Decodable>(_ type: Value.Type = Value.self, from name: String) throws -> Value {
        try JSONDecoder().decode(type, from: data(name))
    }
}
