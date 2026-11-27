import Foundation

/// What this Mac runs: its own CPU's `-apple-darwin` packages, and on Apple
/// silicon with Rosetta installed, Intel ones after them. Every Mac is `full` tier.
public struct Platform: Sendable, Equatable {
    public var targets: [String]
    public var tier: String

    public init(targets: [String], tier: String = "full") {
        self.targets = targets
        self.tier = tier
    }

    public static let current: Platform = {
        #if arch(arm64)
        var targets = ["aarch64-apple-darwin"]
        if FileManager.default.fileExists(atPath: "/Library/Apple/usr/libexec/oah/libRosettaRuntime") {
            targets.append("x86_64-apple-darwin")
        }
        return Platform(targets: targets)
        #else
        return Platform(targets: ["x86_64-apple-darwin"])
        #endif
    }()

    /// The preferred target, as the Store is asked for.
    public var primaryTarget: String { targets[0] }

    public func runs(target: String, tier: String) -> Bool {
        targets.contains(target) && (tier == "lite" || tier == self.tier)
    }

    /// The Mach-O CPU type a target's executables carry.
    static func cpuType(of target: String) -> Int32? {
        switch target.split(separator: "-").first {
        case "aarch64"?, "arm64"?: 0x0100_000C
        case "x86_64"?: 0x0100_0007
        default: nil
        }
    }
}

/// What an entry file is, read from its first bytes.
public enum ExecutableFormat: Equatable, Sendable {
    /// A Mach-O executable with these CPU types (several for a universal binary).
    case machO(cpuTypes: [Int32])
    /// A script run by the interpreter its `#!` line names.
    case script
    case other

    public static func of(_ url: URL) -> ExecutableFormat {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .other }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 4096), head.count >= 4 else { return .other }
        if head[0] == 0x23, head[1] == 0x21 { return .script }
        let magic = head.u32(0)
        if magic == 0xFEED_FACF || magic == 0xFEED_FACE {
            guard head.count >= 16, head.u32(12) == 2 else { return .other }  // MH_EXECUTE
            return .machO(cpuTypes: [Int32(bitPattern: head.u32(4))])
        }
        let fat = head.u32BE(0)
        if fat == 0xCAFE_BABE || fat == 0xCAFE_BABF {
            guard head.count >= 8 else { return .other }
            let count = Int(head.u32BE(4))
            let stride = fat == 0xCAFE_BABE ? 20 : 32
            guard count > 0, count < 32, head.count >= 8 + count * stride else { return .other }
            return .machO(cpuTypes: (0..<count).map { Int32(bitPattern: head.u32BE(8 + $0 * stride)) })
        }
        return .other
    }
}
