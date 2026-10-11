import Foundation
import UIKit

import AccountContext
import TelegramPresentationData

/// Обёртка над `PresentationAppIcon`.
///
/// Сам набор иконок живёт в `AppDelegate` (`getAvailableAlternateIcons`) — там
/// же он попадает в `Telegram/BUILD:alternate_icon_folders`. Держать второй
/// список значит гарантированно разъехаться с ним, поэтому здесь только
/// отображение и применение.
///
/// Чтобы добавить свою иконку: создать `Telegram-iOS/SGMy.alticon/` с
/// `SGMy@2x.png` и `SGMy@3x.png`, вписать `"SGMy"` в `alternate_icon_folders`
/// и в `AlternateIcons.plist`, затем добавить `PresentationAppIcon` в список
/// в `AppDelegate.swift`.
public struct SGAppIcon: Hashable {
    public let name: String
    public let isPremium: Bool
    public let isSGPro: Bool

    public init(name: String, isPremium: Bool, isSGPro: Bool) {
        self.name = name
        self.isPremium = isPremium
        self.isSGPro = isSGPro
    }

    public init(_ icon: PresentationAppIcon) {
        self.name = icon.name
        self.isPremium = icon.isPremium
        self.isSGPro = icon.isSGPro
    }

    /// «SGNeonBlue» -> «Neon Blue». Без префикса смотрелось бы криво.
    public var title: String {
        var value = self.name
        if value.hasPrefix("SG") {
            value.removeFirst(2)
        }
        if value.hasPrefix("Icon") {
            value.removeFirst(4)
        }
        let spaced = value.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
        return spaced.isEmpty ? self.name : spaced
    }

    public static func icons(context: AccountContext) -> [SGAppIcon] {
        return context.sharedContext.applicationBindings.getAvailableAlternateIcons().map { SGAppIcon($0) }
    }

    public static func selectedIcon(context: AccountContext) -> SGAppIcon? {
        let icons = self.icons(context: context)
        if let name = context.sharedContext.applicationBindings.getAlternateIconName() {
            return icons.first { $0.name == name }
        }
        return icons.first { $0.name == "SGDefault" } ?? icons.first
    }
}

/// Переключение иконки.
public enum SGAppIconManager {
    /// iOS не спрашивает текущую иконку через API, поэтому выбор подтверждаем
    /// сами — иначе после перезапуска показывается старая.
    public static func apply(_ icon: SGAppIcon, completion: ((Error?) -> Void)? = nil) {
        let run = {
            guard UIApplication.shared.supportsAlternateIcons else {
                completion?(nil)
                return
            }
            UIApplication.shared.setAlternateIconName(icon.name) { error in
                DispatchQueue.main.async {
                    completion?(error)
                }
            }
        }
        if Thread.isMainThread {
            run()
        } else {
            DispatchQueue.main.async(execute: run)
        }
    }
}