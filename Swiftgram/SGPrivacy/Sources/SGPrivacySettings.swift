import Foundation

/// Настройки приватности живут отдельно от `SGSimpleSettings`.
///
/// Причина: `SGSimpleSettings` — общий файл, где на каждый ключ приходится
/// `Keys`-case, запись в `defaultValues`, `@UserDefault`-свойство и прогрев в
/// `preCacheValues`. Добавлять туда четыре независимые фичи — значит править
/// один большой файл в четырёх местах. Здесь всё рядом, и модуль остаётся
/// листовым: его можно подключить к `TelegramCore`, не затащив UI в ядро.
public final class SGPrivacySettings {
    public static let shared = SGPrivacySettings()

    public enum Key: String, CaseIterable {
        // Режим призрака
        case ghostMode
        case ghostHideOnline
        case ghostHideReadReceipts
        case ghostHideActivity
        // Сохранение удалённых
        case antiDelete
        case antiDeleteSaveMedia
        // Одноразовые сообщения
        case keepViewOnce
        case keepViewOnceSaveMedia
    }

    public static let defaultValues: [String: Any] = [
        Key.ghostMode.rawValue: false,
        Key.ghostHideOnline.rawValue: true,
        Key.ghostHideReadReceipts.rawValue: true,
        Key.ghostHideActivity.rawValue: true,
        Key.antiDelete.rawValue: false,
        Key.antiDeleteSaveMedia.rawValue: true,
        Key.keepViewOnce.rawValue: false,
        Key.keepViewOnceSaveMedia.rawValue: true
    ]

    private let defaults: UserDefaults
    private let lock = NSLock()
    private var observers: [String: [UUID: () -> Void]] = [:]

    private init() {
        self.defaults = .standard
        self.defaults.register(defaults: SGPrivacySettings.defaultValues)
    }

    // MARK: - Значения

    /// Единая точка записи: без неё UI пришлось бы знать про каждое свойство.
    public func set(_ value: Bool, for key: Key) {
        self.store(value, for: key)
    }

    public var ghostMode: Bool {
        get { return self.bool(for: .ghostMode) }
        set { self.store(newValue, for: .ghostMode) }
    }

    public var ghostHideOnline: Bool {
        get { return self.bool(for: .ghostHideOnline) }
        set { self.store(newValue, for: .ghostHideOnline) }
    }

    public var ghostHideReadReceipts: Bool {
        get { return self.bool(for: .ghostHideReadReceipts) }
        set { self.store(newValue, for: .ghostHideReadReceipts) }
    }

    public var ghostHideActivity: Bool {
        get { return self.bool(for: .ghostHideActivity) }
        set { self.store(newValue, for: .ghostHideActivity) }
    }

    public var antiDelete: Bool {
        get { return self.bool(for: .antiDelete) }
        set { self.store(newValue, for: .antiDelete) }
    }

    public var antiDeleteSaveMedia: Bool {
        get { return self.bool(for: .antiDeleteSaveMedia) }
        set { self.store(newValue, for: .antiDeleteSaveMedia) }
    }

    public var keepViewOnce: Bool {
        get { return self.bool(for: .keepViewOnce) }
        set { self.store(newValue, for: .keepViewOnce) }
    }

    public var keepViewOnceSaveMedia: Bool {
        get { return self.bool(for: .keepViewOnceSaveMedia) }
        set { self.store(newValue, for: .keepViewOnceSaveMedia) }
    }

    private func bool(for key: Key) -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.defaults.bool(forKey: key.rawValue)
    }

    private func store(_ value: Bool, for key: Key) {
        self.lock.lock()
        self.defaults.set(value, forKey: key.rawValue)
        let callbacks: [() -> Void] = self.observers[key.rawValue].map { Array($0.values) } ?? []
        self.lock.unlock()

        for callback in callbacks {
            callback()
        }
    }

    // MARK: - Подписки

    /// Вызывает `callback` при каждом изменении `key`. Токен освобождается —
    /// подписка снимается; отменять вручную не обязательно.
    public func observe(_ key: Key, _ callback: @escaping () -> Void) -> SGPrivacySettingsToken {
        let token = UUID()
        self.lock.lock()
        self.observers[key.rawValue, default: [:]][token] = callback
        self.lock.unlock()

        return SGPrivacySettingsToken { [weak self] in
            guard let strongSelf = self else {
                return
            }
            strongSelf.lock.lock()
            strongSelf.observers[key.rawValue]?[token] = nil
            strongSelf.lock.unlock()
        }
    }
}

/// Токен подписки. Снимает подписку в `deinit`, поэтому хранить его нужно
/// ровно столько же, сколько живёт наблюдатель.
public final class SGPrivacySettingsToken {
    private let lock = NSLock()
    private var onCancel: (() -> Void)?

    fileprivate init(onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
    }

    deinit {
        self.cancel()
    }

    public func cancel() {
        self.lock.lock()
        let block = self.onCancel
        self.onCancel = nil
        self.lock.unlock()

        block?()
    }
}