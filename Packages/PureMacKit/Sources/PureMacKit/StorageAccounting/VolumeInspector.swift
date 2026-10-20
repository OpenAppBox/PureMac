import Darwin
import Foundation

/// Reads volume capacity and properties via documented `URLResourceKey` values.
public enum VolumeInspector {
    private static let keys: [URLResourceKey] = [
        .volumeNameKey, .volumeLocalizedNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
        .volumeAvailableCapacityForImportantUsageKey, .volumeIsInternalKey, .volumeIsRemovableKey,
        .volumeIsEjectableKey, .volumeIsLocalKey, .volumeIsReadOnlyKey, .volumeIsRootFileSystemKey,
        .volumeLocalizedFormatDescriptionKey,
    ]

    /// Information about the volume containing `url`.
    public static func volume(containing url: URL) -> VolumeInfo? {
        var volumeURL = url
        if let resolved = try? url.resourceValues(forKeys: [.volumeURLKey]).volume {
            volumeURL = resolved
        }
        return info(for: volumeURL)
    }

    /// Mounted, user-visible volumes. Network volumes are included but flagged non-local so the UI
    /// can keep them opt-in.
    public static func mountedVolumes() -> [VolumeInfo] {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap(info(for:))
    }

    public static func info(for url: URL) -> VolumeInfo? {
        guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
        let device: Int32? = try? FileStat.lstat(url.path).get().identity.device
        return VolumeInfo(
            url: url,
            name: values.volumeLocalizedName ?? values.volumeName ?? url.lastPathComponent,
            totalCapacity: values.volumeTotalCapacity.map(Int64.init),
            availableCapacity: values.volumeAvailableCapacity.map(Int64.init),
            availableForImportantUsage: values.volumeAvailableCapacityForImportantUsage,
            fileSystemType: values.volumeLocalizedFormatDescription,
            isInternal: values.volumeIsInternal ?? false,
            isRemovable: values.volumeIsRemovable ?? false,
            isEjectable: values.volumeIsEjectable ?? false,
            isLocal: values.volumeIsLocal ?? true,
            isReadOnly: values.volumeIsReadOnly ?? false,
            isRootFileSystem: values.volumeIsRootFileSystem ?? false,
            deviceID: device
        )
    }

    /// Plain free bytes of the volume containing `path` (`statfs`), used for before/after
    /// measurements. Uses `f_bavail` (space available to unprivileged users).
    public static func freeBytes(atPath path: String) -> Int64? {
        var fs = statfs()
        guard path.withCString({ statfs($0, &fs) }) == 0 else { return nil }
        return Int64(fs.f_bavail) * Int64(fs.f_bsize)
    }
}
