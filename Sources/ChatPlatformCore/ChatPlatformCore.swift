/// Models, HTTP and socket clients and the local message store. No UIKit, so
/// it builds and tests on Linux too, and the agent app can reuse it.
public enum ChatPlatformCore {
    /// The SDK's version, sent as part of the `User-Agent`.
    public static let version = "0.2.0"
}
