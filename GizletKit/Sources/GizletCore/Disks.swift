import DiskArbitration
import Foundation
import IOKit

/// A volume on a disk, as Disk Arbitration describes it.
public struct VolumeInfo: Equatable, Hashable, Sendable {
    public var bsdName: String
    public var name: String?
    public var kind: String?
    public var mountPoint: URL?
}

/// What tells one inserted medium from another: the same card put back in, or
/// another one, appears again with a new appearance time.
public struct DiskIdentity: Equatable, Hashable, Sendable {
    public var bsdName: String
    public var appearanceTime: Double
    public var size: UInt64
    public var mediaName: String?
}

/// A whole disk and its volumes.
public struct DiskInfo: Identifiable, Equatable, Hashable, Sendable {
    public var id: String { bsdName }
    public var bsdName: String
    public var mediaName: String?
    public var vendor: String?
    public var model: String?
    public var size: UInt64
    public var blockSize: Int
    public var isRemovable: Bool
    public var isEjectable: Bool
    public var isInternal: Bool
    public var isWritable: Bool
    public var protocolName: String?
    public var isVirtual: Bool
    public var isSynthesized: Bool
    public var appearanceTime: Double
    public var volumes: [VolumeInfo]

    public var identity: DiskIdentity {
        DiskIdentity(bsdName: bsdName, appearanceTime: appearanceTime, size: size, mediaName: mediaName)
    }

    public var displayName: String {
        let parts = [vendor, model].compactMap { $0?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return parts.isEmpty ? (mediaName ?? bsdName) : parts.joined(separator: " ")
    }

    public var volumeNames: [String] { volumes.compactMap(\.name).filter { !$0.isEmpty } }

    /// Disks over 256 GB are rarely TF cards; confirming one takes typing its name.
    public var isUnusuallyLarge: Bool { size > 256_000_000_000 }

    public var rawDevicePath: String { "/dev/r\(bsdName)" }
}

/// Why a disk may not be written; nil when it may.
public func diskProblem(_ disk: DiskInfo, protected: Set<String>, allowDiskImages: Bool = false) -> String? {
    guard disk.bsdName.range(of: #"^disk[0-9]+$"#, options: .regularExpression) != nil else { return "not a whole disk" }
    if protected.contains(disk.bsdName) { return "the system disk or the disk Gizlet runs from" }
    if disk.isSynthesized { return "an APFS container" }
    if disk.isVirtual && !allowDiskImages { return "a disk image" }
    if disk.isInternal && !disk.isRemovable { return "an internal disk" }
    if !disk.isRemovable && !disk.isEjectable { return "not removable" }
    if !disk.isWritable { return "write-protected" }
    if disk.size < 512 << 20 { return "smaller than the image" }
    return nil
}

/// The whole disks behind the volumes that must never be written: the startup
/// volume and its data volume, every physical store of their APFS container,
/// and the disks that hold the running app and the launcher's data.
public func protectedDisks(extraPaths: [URL] = []) -> Set<String> {
    var result = Set<String>()
    guard let session = DASessionCreate(kCFAllocatorDefault) else { return result }
    let paths = ["/", "/System/Volumes/Data", NSHomeDirectory()] + extraPaths.map(\.path)
    for path in paths {
        var stats = statfs()
        guard statfs(path, &stats) == 0 else { continue }
        let device = withUnsafePointer(to: &stats.f_mntfromname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        guard device.hasPrefix("/dev/"), let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, String(device.dropFirst(5))),
              let whole = DADiskCopyWholeDisk(disk), let name = DADiskGetBSDName(whole).map({ String(cString: $0) }) else { continue }
        result.insert(name)
        result.formUnion(physicalStores(of: whole))
    }
    return result
}

/// The whole physical disks an APFS (or other synthesized) disk is built on,
/// found by walking the I/O Registry up from its media.
func physicalStores(of disk: DADisk) -> Set<String> {
    var result = Set<String>()
    let media = DADiskCopyIOMedia(disk)
    guard media != IO_OBJECT_NULL else { return result }
    defer { IOObjectRelease(media) }
    var queue: [io_registry_entry_t] = [media]
    IOObjectRetain(media)
    var visited = 0
    while let entry = queue.popLast(), visited < 64 {
        visited += 1
        defer { IOObjectRelease(entry) }
        if IOObjectConformsTo(entry, "IOMedia") != 0,
           let whole = IORegistryEntryCreateCFProperty(entry, "Whole" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool, whole,
           let name = IORegistryEntryCreateCFProperty(entry, "BSD Name" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String {
            result.insert(name)
        }
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetParentIterator(entry, kIOServicePlane, &iterator) == KERN_SUCCESS else { continue }
        while case let parent = IOIteratorNext(iterator), parent != IO_OBJECT_NULL {
            queue.append(parent)
        }
        IOObjectRelease(iterator)
    }
    return result
}

/// Whether a disk's media sits on an APFS container, which makes it synthesized.
func isSynthesized(_ disk: DADisk) -> Bool {
    let media = DADiskCopyIOMedia(disk)
    guard media != IO_OBJECT_NULL else { return false }
    defer { IOObjectRelease(media) }
    var parent: io_registry_entry_t = 0
    guard IORegistryEntryGetParentEntry(media, kIOServicePlane, &parent) == KERN_SUCCESS else { return false }
    defer { IOObjectRelease(parent) }
    return IOObjectConformsTo(parent, "AppleAPFSContainer") != 0
}

/// Watches disks as they appear, change and disappear, through Disk Arbitration
/// on the main queue, and keeps the whole disks with their volumes.
public final class DiskMonitor: @unchecked Sendable {
    public private(set) var disks: [String: DiskInfo] = [:]
    public var onChange: (([DiskInfo]) -> Void)?
    public var onDisappear: ((String) -> Void)?

    private let session: DASession
    private var known: [String: DADisk] = [:]
    private var blockedMounts = Set<String>()
    private var started = false

    public init() {
        session = DASessionCreate(kCFAllocatorDefault)!
    }

    deinit {
        DASessionUnscheduleFromRunLoop(session, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
    }

    public func start() {
        guard !started else { return }
        started = true
        let context = Unmanaged.passUnretained(self).toOpaque()
        DARegisterDiskAppearedCallback(session, nil, { disk, context in
            Unmanaged<DiskMonitor>.fromOpaque(context!).takeUnretainedValue().appeared(disk)
        }, context)
        DARegisterDiskDisappearedCallback(session, nil, { disk, context in
            Unmanaged<DiskMonitor>.fromOpaque(context!).takeUnretainedValue().disappeared(disk)
        }, context)
        DARegisterDiskDescriptionChangedCallback(session, nil, nil, { disk, _, context in
            Unmanaged<DiskMonitor>.fromOpaque(context!).takeUnretainedValue().appeared(disk)
        }, context)
        DARegisterDiskMountApprovalCallback(session, nil, { disk, context in
            let monitor = Unmanaged<DiskMonitor>.fromOpaque(context!).takeUnretainedValue()
            guard let whole = DADiskCopyWholeDisk(disk), let name = DADiskGetBSDName(whole).map({ String(cString: $0) }),
                  monitor.blockedMounts.contains(name) else { return nil }
            return Unmanaged.passRetained(DADissenterCreate(kCFAllocatorDefault, DAReturn(kDAReturnExclusiveAccess), "Gizlet is writing this card" as CFString))
        }, context)
        DASessionScheduleWithRunLoop(session, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
    }

    /// The current description of a whole disk, read afresh.
    public func describe(_ bsdName: String) -> DiskInfo? {
        guard let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsdName) else { return nil }
        return info(for: disk)
    }

    /// While blocked, macOS is refused when it tries to mount the disk's volumes.
    public func setMountsBlocked(_ blocked: Bool, for bsdName: String) {
        if blocked { blockedMounts.insert(bsdName) } else { blockedMounts.remove(bsdName) }
    }

    public func unmount(_ bsdName: String) async throws {
        guard let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsdName) else { throw FlashError.cardChanged }
        try await callback { context, done in
            DADiskUnmount(disk, DADiskUnmountOptions(kDADiskUnmountOptionWhole), done, context)
        }
    }

    public func mount(_ bsdName: String) async throws {
        guard let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsdName) else { throw FlashError.cardChanged }
        try await callback { context, done in
            DADiskMount(disk, nil, DADiskMountOptions(kDADiskMountOptionDefault), done, context)
        }
    }

    public func eject(_ bsdName: String) async throws {
        guard let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsdName) else { throw FlashError.cardChanged }
        try? await unmount(bsdName)
        try await callback { context, done in
            DADiskEject(disk, DADiskEjectOptions(kDADiskEjectOptionDefault), done, context)
        }
    }

    private final class Completion {
        var continuation: CheckedContinuation<Void, Error>?
    }

    private func callback(_ start: (UnsafeMutableRawPointer, @escaping DADiskUnmountCallback) -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let completion = Completion()
            completion.continuation = continuation
            let context = Unmanaged.passRetained(completion).toOpaque()
            start(context) { _, dissenter, context in
                let completion = Unmanaged<Completion>.fromOpaque(context!).takeRetainedValue()
                if let dissenter {
                    let reason = DADissenterGetStatusString(dissenter) as String? ?? String(format: "0x%x", DADissenterGetStatus(dissenter))
                    completion.continuation?.resume(throwing: FlashError.disk("The card is in use (\(reason)); close any window or app using it"))
                } else {
                    completion.continuation?.resume()
                }
            }
        }
    }

    private func name(of disk: DADisk) -> String? {
        DADiskGetBSDName(disk).map { String(cString: $0) }
    }

    private func appeared(_ disk: DADisk) {
        guard let name = name(of: disk) else { return }
        known[name] = disk
        refresh(wholeName(of: disk) ?? name)
    }

    private func disappeared(_ disk: DADisk) {
        guard let name = name(of: disk) else { return }
        known.removeValue(forKey: name)
        if disks.removeValue(forKey: name) != nil {
            onDisappear?(name)
            onChange?(sortedDisks)
        } else if let whole = wholeName(of: disk) {
            refresh(whole)
        }
    }

    private func wholeName(of disk: DADisk) -> String? {
        DADiskCopyWholeDisk(disk).flatMap { name(of: $0) }
    }

    public var sortedDisks: [DiskInfo] { disks.values.sorted { ($0.size, $0.bsdName) < ($1.size, $1.bsdName) } }

    private func refresh(_ wholeName: String) {
        guard let disk = known[wholeName] ?? DADiskCreateFromBSDName(kCFAllocatorDefault, session, wholeName), let info = info(for: disk) else { return }
        disks[wholeName] = info
        onChange?(sortedDisks)
    }

    func info(for disk: DADisk) -> DiskInfo? {
        guard let description = DADiskCopyDescription(disk) as? [CFString: Any],
              description[kDADiskDescriptionMediaWholeKey] as? Bool == true, let bsdName = name(of: disk) else { return nil }
        let protocolName = description[kDADiskDescriptionDeviceProtocolKey] as? String
        let model = description[kDADiskDescriptionDeviceModelKey] as? String
        let volumes = known.keys.filter { $0.hasPrefix(bsdName + "s") }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.compactMap { part -> VolumeInfo? in
            guard let partition = known[part], let details = DADiskCopyDescription(partition) as? [CFString: Any] else { return nil }
            return VolumeInfo(bsdName: part, name: details[kDADiskDescriptionVolumeNameKey] as? String,
                              kind: details[kDADiskDescriptionVolumeKindKey] as? String,
                              mountPoint: details[kDADiskDescriptionVolumePathKey] as? URL)
        }
        return DiskInfo(
            bsdName: bsdName,
            mediaName: description[kDADiskDescriptionMediaNameKey] as? String,
            vendor: description[kDADiskDescriptionDeviceVendorKey] as? String,
            model: model,
            size: (description[kDADiskDescriptionMediaSizeKey] as? NSNumber)?.uint64Value ?? 0,
            blockSize: (description[kDADiskDescriptionMediaBlockSizeKey] as? NSNumber)?.intValue ?? 512,
            isRemovable: description[kDADiskDescriptionMediaRemovableKey] as? Bool ?? false,
            isEjectable: description[kDADiskDescriptionMediaEjectableKey] as? Bool ?? false,
            isInternal: description[kDADiskDescriptionDeviceInternalKey] as? Bool ?? true,
            isWritable: description[kDADiskDescriptionMediaWritableKey] as? Bool ?? false,
            protocolName: protocolName,
            isVirtual: protocolName == "Virtual Interface" || model == "Disk Image",
            isSynthesized: isSynthesized(disk),
            appearanceTime: (description["DAAppearanceTime" as CFString] as? NSNumber)?.doubleValue ?? 0,
            volumes: volumes
        )
    }
}
