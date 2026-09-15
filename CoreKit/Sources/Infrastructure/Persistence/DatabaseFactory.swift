import Foundation
import Protocols

public enum DatabaseFactory {
    public static func makeFile(path: String) throws -> any DatabaseProtocol {
        let engine = GRDBEngine()
        try engine.setup(path: path)
        return engine
    }

    public static func makeInMemory() throws -> any DatabaseProtocol {
        let engine = GRDBEngine()
        try engine.setupInMemory()
        return engine
    }
}
