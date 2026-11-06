import Foundation

/// One mounted volume on a drive, for example the "Extra" partition.
public struct Volume: Sendable, Equatable {
    public let name: String
    public let mountPoint: URL
    public let total: Int64
    public let free: Int64

    public init(name: String, mountPoint: URL, total: Int64, free: Int64) {
        self.name = name
        self.mountPoint = mountPoint
        self.total = total
        self.free = free
    }
}

/// One physical device (a USB stick, an SD card, an external SSD or a disk image)
/// with every volume macOS mounted from it. Ejecting a Drive ejects all of them.
public struct Drive: Sendable, Equatable {
    /// BSD name of the whole physical disk, for example "disk4".
    public let id: String
    /// Model name reported by the device, may be empty.
    public let model: String
    /// "USB", "Thunderbolt", "Secure Digital", "Disk Image" and so on.
    public let bus: String
    public let size: Int64
    public var volumes: [Volume]

    public init(id: String, model: String, bus: String, size: Int64, volumes: [Volume]) {
        self.id = id
        self.model = model
        self.bus = bus
        self.size = size
        self.volumes = volumes
    }

    public var isDiskImage: Bool { bus == "Disk Image" }

    /// What the user sees: the volume name when there is one volume, else the model.
    public var displayName: String {
        if volumes.count == 1 { return volumes[0].name }
        if !model.isEmpty { return model }
        return volumes.map(\.name).joined(separator: ", ")
    }
}

public enum DiskUtil {
    public static let path = "/usr/sbin/diskutil"

    @discardableResult
    public static func run(_ args: [String]) -> (status: Int32, output: String) {
        Shell.run(path, args)
    }

    /// `diskutil info -plist <target>` as a dictionary.
    public static func info(_ target: String) -> [String: Any]? {
        let r = run(["info", "-plist", target])
        guard r.status == 0, let data = r.output.data(using: .utf8) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }
}

public enum Shell {
    public static func run(_ executable: String, _ args: [String]) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        // Never inherit a working directory on the drive we are about to eject.
        p.currentDirectoryURL = URL(fileURLWithPath: "/")
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

public enum DriveScanner {
    static let keys: [URLResourceKey] = [
        .volumeNameKey, .volumeIsInternalKey, .volumeIsEjectableKey, .volumeIsRemovableKey,
        .volumeIsLocalKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
    ]

    /// Volumes the user could unplug: local, mounted under /Volumes, and external,
    /// removable or ejectable. The startup disk and system volumes never show up.
    public static func candidateVolumes() -> [Volume] {
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            guard url.path.hasPrefix("/Volumes/"),
                  let v = try? url.resourceValues(forKeys: Set(keys)),
                  v.volumeIsLocal ?? false
            else { return nil }
            let external = !(v.volumeIsInternal ?? true)
            guard external || (v.volumeIsEjectable ?? false) || (v.volumeIsRemovable ?? false) else { return nil }
            return Volume(
                name: v.volumeName ?? url.lastPathComponent,
                mountPoint: url,
                total: Int64(v.volumeTotalCapacity ?? 0),
                free: Int64(v.volumeAvailableCapacity ?? 0))
        }
    }

    /// Fresh free space for volumes we already know, without asking diskutil again.
    public static func refreshSpace(_ drives: [Drive]) -> [Drive] {
        drives.map { d in
            var d = d
            d.volumes = d.volumes.map { v in
                guard let r = try? v.mountPoint.resourceValues(forKeys: [.volumeAvailableCapacityKey, .volumeTotalCapacityKey])
                else { return v }
                return Volume(name: v.name, mountPoint: v.mountPoint,
                              total: Int64(r.volumeTotalCapacity ?? Int(v.total)),
                              free: Int64(r.volumeAvailableCapacity ?? Int(v.free)))
            }
            return d
        }
    }

    /// Groups the candidate volumes by the physical disk they live on.
    /// Slow (one diskutil call per volume), so call it off the main thread.
    public static func scan() -> [Drive] {
        var order: [String] = []
        var drives: [String: Drive] = [:]
        for vol in candidateVolumes() {
            guard let info = DiskUtil.info(vol.mountPoint.path),
                  let whole = physicalWholeDisk(info: info, lookup: DiskUtil.info)
            else { continue }
            if drives[whole] == nil {
                let w = DiskUtil.info(whole) ?? [:]
                drives[whole] = Drive(
                    id: whole,
                    model: modelName(w),
                    bus: (w["BusProtocol"] as? String) ?? (info["BusProtocol"] as? String) ?? "",
                    size: (w["TotalSize"] as? NSNumber)?.int64Value ?? vol.total,
                    volumes: [])
                order.append(whole)
            }
            drives[whole]?.volumes.append(vol)
        }
        return order.compactMap { drives[$0] }
    }

    /// The whole physical disk behind a volume. APFS volumes sit in a synthesized
    /// container disk, so follow the container to its physical store first.
    public static func physicalWholeDisk(info: [String: Any], lookup: (String) -> [String: Any]?) -> String? {
        if let stores = info["APFSPhysicalStores"] as? [[String: Any]],
           let store = stores.first?["APFSPhysicalStore"] as? String {
            if let parent = lookup(store)?["ParentWholeDisk"] as? String { return parent }
            return wholeDiskName(store)
        }
        if let parent = info["ParentWholeDisk"] as? String { return parent }
        if let id = info["DeviceIdentifier"] as? String { return wholeDiskName(id) }
        return nil
    }

    /// "disk11s2" becomes "disk11".
    public static func wholeDiskName(_ bsd: String) -> String {
        guard let r = bsd.range(of: #"^disk\d+"#, options: .regularExpression) else { return bsd }
        return String(bsd[r])
    }

    static func modelName(_ info: [String: Any]) -> String {
        let media = (info["MediaName"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        if !media.isEmpty { return media }
        var reg = info["IORegistryEntryName"] as? String ?? ""
        if reg.hasSuffix(" Media") { reg.removeLast(6) }
        return reg.trimmingCharacters(in: .whitespaces)
    }
}
