import Foundation
import Postbox

import SGAppGroupIdentifier
import SGLogging

/// Что именно попало в архив.
public enum SGArchiveKind: String, Codable, CaseIterable {
    /// Сообщение было удалено — нами или собеседником.
    case deleted
    /// Одноразовое (view-once) сообщение было открыто.
    case viewOnce

    public var directoryName: String {
        return self.rawValue
    }
}

/// Запись архива. Хранится как JSON рядом с копиями медиа.
public struct SGArchivedMessage: Codable, Hashable {
    public var peerId: PeerId
    public var messageNamespace: Int32
    public var messageId: Int32
    public var timestamp: Int32
    public var capturedAt: Int
    public var text: String
    public var kind: SGArchiveKind
    /// Имена файлов в `sg-privacy/media` относительно этого сообщения.
    public var mediaFileNames: [String]

    public init(
        peerId: PeerId,
        messageNamespace: Int32,
        messageId: Int32,
        timestamp: Int32,
        capturedAt: Int,
        text: String,
        kind: SGArchiveKind,
        mediaFileNames: [String]
    ) {
        self.peerId = peerId
        self.messageNamespace = messageNamespace
        self.messageId = messageId
        self.timestamp = timestamp
        self.capturedAt = capturedAt
        self.text = text
        self.kind = kind
        self.mediaFileNames = mediaFileNames
    }

    public init?(message: Message, kind: SGArchiveKind, mediaFileNames: [String]) {
        self.init(
            peerId: message.id.peerId,
            messageNamespace: message.id.namespace,
            messageId: message.id.id,
            timestamp: message.timestamp,
            capturedAt: Int(Date().timeIntervalSince1970),
            text: message.text,
            kind: kind,
            mediaFileNames: mediaFileNames
        )
    }

    public var messageIdFull: MessageId {
        return MessageId(peerId: self.peerId, namespace: self.messageNamespace, id: self.messageId)
    }

    public var isOutgoing: Bool {
        return self.messageId < 0
    }

    /// Стабильный ключ: уникален в пределах аккаунта и переживает рестарт.
    public var storageKey: String {
        return "\(self.peerId.toInt64())-\(self.messageNamespace)-\(self.messageId)"
    }

    public var sortedTimestamp: Int64 {
        return Int64(self.timestamp)
    }
}

/// Хранилище архива в контейнере app group.
///
/// Файлы лежат рядом с базой Telegram, поэтому переживают удаление аккаунта
/// только до пересоздания контейнера — это осознанный компромисс: писать в
/// Documents/Sandbox нельзя (расширения вроде ShareController туда не достанутся).
public final class SGMessageArchive {
    public static let shared = SGMessageArchive()

    /// Оповещает UI о том, что архив изменился.
    public static let didChangeNotification = Notification.Name("SGMessageArchive.didChange")

    private static let rootDirectoryName = "sg-privacy"
    private static let mediaDirectoryName = "media"

    private let queue = DispatchQueue(label: "app.swiftgram.ios.privacy.archive", qos: .utility)
    private let fileManager = FileManager.default

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private let decoder = JSONDecoder()

    private init() {
    }

    // MARK: - Пути

    /// nil, если контейнер app group недоступен (например, entitlement не выдан).
    public var rootURL: URL? {
        guard let container = self.fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: sgAppGroupIdentifier()
        ) else {
            return nil
        }
        return container.appendingPathComponent(SGMessageArchive.rootDirectoryName, isDirectory: true)
    }

    private func directoryURL(for kind: SGArchiveKind) -> URL? {
        guard let root = self.rootURL else {
            return nil
        }
        return root.appendingPathComponent(kind.directoryName, isDirectory: true)
    }

    private var mediaURL: URL? {
        guard let root = self.rootURL else {
            return nil
        }
        return root.appendingPathComponent(SGMessageArchive.mediaDirectoryName, isDirectory: true)
    }

    private func ensureDirectory(_ url: URL?) -> Bool {
        guard let url = url else {
            return false
        }
        if self.fileManager.fileExists(atPath: url.path) {
            return true
        }
        do {
            try self.fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
            return true
        } catch {
            SGLogger.shared.log("SGPrivacy", "can't create \(url.path): \(error)")
            return false
        }
    }

    // MARK: - Запись

    /// Кладёт сообщение в архив. `mediaFiles` — готовые файлы на диске.
    ///
    /// Копирование файлов идёт **синхронно**, в очередь уходит только запись
    /// JSON. Это обязательно: вызывающий хук сидит внутри транзакции Postbox,
    /// а исходник стирается сразу после неё — отложенная копия почти всегда
    /// опоздала бы. Плата — блокировка потока транзакции на время копирования.
    public func capture(message: Message, kind: SGArchiveKind, mediaFiles: [(name: String, url: URL)] = []) {
        var storedNames: [String] = []
        if !mediaFiles.isEmpty {
            let key = "\(message.id.peerId.toInt64())-\(message.id.namespace)-\(message.id.id)"
            storedNames = self.copyMediaFiles(mediaFiles, forKey: key)
        }

        self.queue.async {
            guard self.ensureDirectory(self.directoryURL(for: kind)) else {
                return
            }
            guard let entry = SGArchivedMessage(message: message, kind: kind, mediaFileNames: storedNames) else {
                return
            }
            guard let directory = self.directoryURL(for: kind) else {
                return
            }

            let fileURL = directory.appendingPathComponent("\(entry.storageKey).json")
            do {
                let data = try self.encoder.encode(entry)
                try data.write(to: fileURL, options: .atomic)
            } catch {
                SGLogger.shared.log("SGPrivacy", "encode/write failed: \(error)")
                return
            }

            NotificationCenter.default.post(name: SGMessageArchive.didChangeNotification, object: nil)
        }
    }

    /// Копирует файлы в `sg-privacy/media` и возвращает имена, под которыми они
    /// там лежат. Синхронная — см. комментарий у `capture`.
    private func copyMediaFiles(_ files: [(name: String, url: URL)], forKey key: String) -> [String] {
        guard let mediaDir = self.mediaURL, self.ensureDirectory(mediaDir) else {
            SGLogger.shared.log("SGPrivacy", "media dir unavailable, storing metadata only")
            return []
        }

        var stored: [String] = []
        for (index, file) in files.enumerated() {
            let destination = mediaDir.appendingPathComponent("\(key)-\(index)-\(file.name)")
            do {
                if self.fileManager.fileExists(atPath: destination.path) {
                    try self.fileManager.removeItem(at: destination)
                }
                try self.fileManager.copyItem(at: file.url, to: destination)
                stored.append(destination.lastPathComponent)
            } catch {
                SGLogger.shared.log("SGPrivacy", "copy \(file.name) failed: \(error)")
            }
        }
        return stored
    }

    // MARK: - Чтение

    /// Архив, отсортированный от новых к старым. Читает с диска — вызывать не
    /// из горячего пути (открытие экрана архива — норм).
    public func load(kind: SGArchiveKind) -> [SGArchivedMessage] {
        guard let directory = self.directoryURL(for: kind) else {
            return []
        }
        guard let files = try? self.fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var result: [SGArchivedMessage] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file) else {
                continue
            }
            if let entry = try? self.decoder.decode(SGArchivedMessage.self, from: data) {
                result.append(entry)
            }
        }
        return result.sorted { $0.sortedTimestamp > $1.sortedTimestamp }
    }

    public func mediaURLs(for entry: SGArchivedMessage) -> [URL] {
        guard let mediaDir = self.mediaURL else {
            return []
        }
        return entry.mediaFileNames.map { mediaDir.appendingPathComponent($0) }
    }

    // MARK: - Удаление

    public func removeAll(kind: SGArchiveKind) {
        self.queue.async {
            if let directory = self.directoryURL(for: kind) {
                let entries = self.load(kind: kind)
                try? self.fileManager.removeItem(at: directory)
                if let mediaDir = self.mediaURL {
                    for entry in entries {
                        for name in entry.mediaFileNames {
                            try? self.fileManager.removeItem(at: mediaDir.appendingPathComponent(name))
                        }
                    }
                }
            }
            NotificationCenter.default.post(name: SGMessageArchive.didChangeNotification, object: nil)
        }
    }

    /// Сколько места занимает архив, в байтах.
    public func footprint() -> Int64 {
        var total: Int64 = 0
        guard let root = self.rootURL else {
            return 0
        }
        guard let enumerator = self.fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey])
            total += Int64(values?.fileSize ?? 0)
        }
        return total
    }
}