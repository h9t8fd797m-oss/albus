import SwiftUI
import UserNotifications
import AlbusCore

/// Puts Albus on the lock screen, bristling in proportion to the real week.
///
/// This is the distinctive part of the whole feature and it costs almost
/// nothing: `AlbusCactus` is already a view whose spike geometry is a function
/// of mood, so three renders cover every state the app can be in. No
/// entitlement, no Team ID, no network.
///
/// **`UNNotificationAttachment` moves the file it is given into its own store**,
/// deleting the original — so the cached master can never be handed over
/// directly. Each attachment gets a fresh copy, which is a few kilobytes and the
/// only correct way to reuse one image across many notifications.
@MainActor
final class CactusAttachment {

    static let shared = CactusAttachment()

    /// Roughly 3x the thumbnail iOS shows beside a notification.
    private static let pixelSize: CGFloat = 192

    private var masters: [WorkloadState: URL] = [:]

    private init() {}

    /// An attachment for this mood, or nil.
    ///
    /// Nil is a perfectly good outcome — the notification is still delivered,
    /// just without artwork. Nothing about rendering an image is worth losing a
    /// deadline warning over.
    func attachment(for mood: WorkloadState) -> UNNotificationAttachment? {
        guard let master = master(for: mood) else { return nil }

        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("albus-cactus-\(mood.rawValue)-\(UUID().uuidString).png")
        do {
            try FileManager.default.copyItem(at: master, to: copy)
            return try UNNotificationAttachment(identifier: "", url: copy, options: nil)
        } catch {
            try? FileManager.default.removeItem(at: copy)
            return nil
        }
    }

    /// Renders once per mood per launch and keeps the file.
    private func master(for mood: WorkloadState) -> URL? {
        if let cached = masters[mood], FileManager.default.fileExists(atPath: cached.path) {
            return cached
        }

        let renderer = ImageRenderer(content: cactus(for: mood))
        renderer.scale = 1
        guard let image = renderer.uiImage, let data = image.pngData() else { return nil }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("albus-cactus-master-\(mood.rawValue).png")
        do {
            try data.write(to: url, options: .atomic)
            masters[mood] = url
            return url
        } catch {
            return nil
        }
    }

    /// Opaque rather than transparent: a notification thumbnail is composited
    /// on whatever the lock screen wallpaper happens to be, and a cactus drawn
    /// straight onto a photograph is unreadable.
    private func cactus(for mood: WorkloadState) -> some View {
        ZStack {
            Tokens.Palette.cardSurface
            AlbusCactus(size: Self.pixelSize * 0.68, mood: .init(mood))
        }
        .frame(width: Self.pixelSize, height: Self.pixelSize)
    }
}
