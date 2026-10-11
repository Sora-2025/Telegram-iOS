import Foundation
import Postbox

import SGLogging

/// Точка входа для хуков.
///
/// В ядре это единственное место, о котором нужно знать: четыре проверки —
/// шлюзы для TelegramCore — и две функции захвата. Всё остальное живёт в
/// `SGPrivacySettings` и `SGMessageArchive`.
public enum SGPrivacy {
    public static var settings: SGPrivacySettings {
        return SGPrivacySettings.shared
    }

    // MARK: - Режим призрака

    /// Не отправлять `account.updateStatus`.
    public static var suppressPresence: Bool {
        return self.settings.ghostMode && self.settings.ghostHideOnline
    }

    /// Не отправлять `messages.readHistory` / `channels.readHistory`.
    public static var suppressReadReceipts: Bool {
        return self.settings.ghostMode && self.settings.ghostHideReadReceipts
    }

    /// Не отправлять `messages.setTyping` и прочие активности.
    public static var suppressActivity: Bool {
        return self.settings.ghostMode && self.settings.ghostHideActivity
    }

    // MARK: - Удалённые сообщения

    public static var captureDeleted: Bool {
        return self.settings.antiDelete
    }

    public static var captureDeletedMedia: Bool {
        return self.settings.antiDelete && self.settings.antiDeleteSaveMedia
    }

    // MARK: - Одноразовые сообщения

    public static var keepViewOnce: Bool {
        return self.settings.keepViewOnce
    }

    public static var keepViewOnceMedia: Bool {
        return self.settings.keepViewOnce && self.settings.keepViewOnceSaveMedia
    }

    // MARK: - Хуки

    /// Сообщение, снятое перед удалением, вместе со списком ресурсов медиа.
    ///
    /// Ресурсы приходит сюда готовыми, потому что их умеет разбирать только
    /// ядро: `addMessageMediaResourceIdsToRemove` живёт в `TelegramCore`.
    public struct SGDeletedMessageCapture {
        public let message: Message
        public let resourceIds: [MediaResourceId]

        public init(message: Message, resourceIds: [MediaResourceId]) {
            self.message = message
            self.resourceIds = resourceIds
        }
    }

    /// Вызывается перед тем, как сообщения исчезнут из Postbox.
    ///
    /// Важно вызвать до `mediaBox.removeCachedResources` — дальше файлы уже
    /// стёрты и `completedResourcePath` вернёт nil.
    public static func willDeleteMessages(_ captures: [SGDeletedMessageCapture], mediaBox: MediaBox?) {
        guard self.captureDeleted, !captures.isEmpty else {
            return
        }
        for capture in captures {
            let message = capture.message
            guard !message.text.isEmpty || !message.media.isEmpty else {
                // Пустое сервисное сообщение архивировать незачем.
                continue
            }
            var files: [(name: String, url: URL)] = []
            if self.captureDeletedMedia, let mediaBox = mediaBox {
                for resourceId in capture.resourceIds {
                    // nil, если файл не был скачан — восстановить его нельзя.
                    guard let path = mediaBox.completedResourcePath(id: resourceId) else {
                        continue
                    }
                    files.append((name: URL(fileURLWithPath: path).lastPathComponent, url: URL(fileURLWithPath: path)))
                }
            }
            SGMessageArchive.shared.capture(message: message, kind: .deleted, mediaFiles: files)
        }
    }

    /// Вызывается из галереи перед `markMessageContentAsConsumedInteractively`,
    /// пока файл одноразового медиа ещё не стёрт.
    public static func willOpenViewOnceMedia(_ message: Message, fileURL: URL?, fileName: String) {
        guard self.keepViewOnce else {
            return
        }
        var files: [(name: String, url: URL)] = []
        if self.keepViewOnceMedia, let url = fileURL {
            files = [(name: fileName, url: url)]
        }
        SGMessageArchive.shared.capture(message: message, kind: .viewOnce, mediaFiles: files)
    }
}