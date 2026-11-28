import Foundation

/// Keys that Gizlet releases are signed with; their private halves live only
/// in the release workflows' encrypted credentials.
public enum TrustedKeys {
    /// Signs this Launcher's update manifests (`devops/allowed_signers`).
    public static let launcherUpdate = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPBkwQHKP1LHLhywB0ZxKK1I+tF5Njg5bOO/hFteuv/F"
    public static let launcherUpdateNamespace = "gizlet-macos-update"

    /// Signs Gizlet OS release manifests, as `rootfs/usr/lib/gizlet/launcher/allowed_signers` in gizlet/os.
    public static let osRelease = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIC6BHYSIBbKjF/rNLby8IwmqBpqpQDST9maXBVfmBVzf"
    public static let osReleaseNamespace = "gizlet-launcher"

    /// The Apple Developer ID team whose signature an update must carry.
    public static let developerTeam = "D82Y886BX5"
    public static let bundleIdentifier = "io.gizlet.macos"
}
