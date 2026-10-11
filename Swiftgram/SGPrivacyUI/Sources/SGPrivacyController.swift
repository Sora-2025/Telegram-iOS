import Foundation
import UIKit
import Display
import SwiftSignalKit
import AccountContext
import TelegramCore
import TelegramPresentationData
import ItemListUI
import PresentationDataUtils
import OverlayStatusController

import SGPrivacy
import SGAppIcons

private enum SGPrivacySection: Int32 {
    case ghost
    case antiDelete
    case viewOnce
    case archive
    case about
}

private enum SGPrivacyEntry: ItemListNodeEntry {
    case header(id: Int, section: SGPrivacySection, text: String)
    case toggle(id: Int, section: SGPrivacySection, key: SGPrivacySettings.Key, value: Bool, text: String, enabled: Bool)
    case notice(id: Int, section: SGPrivacySection, text: String)
    case disclosure(id: Int, section: SGPrivacySection, link: SGPrivacyLink, text: String, value: String)
    case action(id: Int, section: SGPrivacySection, actionType: SGPrivacyAction, text: String, destructive: Bool)

    var section: ItemListSectionId {
        switch self {
        case let .header(_, section, _):
            return section.rawValue
        case let .toggle(_, section, _, _, _, _):
            return section.rawValue
        case let .notice(_, section, _):
            return section.rawValue
        case let .disclosure(_, section, _, _, _):
            return section.rawValue
        case let .action(_, section, _, _, _):
            return section.rawValue
        }
    }

    var stableId: Int {
        switch self {
        case let .header(id, _, _):
            return id
        case let .toggle(id, _, _, _, _, _):
            return id
        case let .notice(id, _, _):
            return id
        case let .disclosure(id, _, _, _, _):
            return id
        case let .action(id, _, _, _, _):
            return id
        }
    }

    static func < (lhs: SGPrivacyEntry, rhs: SGPrivacyEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    static func == (lhs: SGPrivacyEntry, rhs: SGPrivacyEntry) -> Bool {
        return lhs.stableId == rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! SGPrivacyArguments
        switch self {
        case let .header(_, _, text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, badge: nil, sectionId: self.section)
        case let .toggle(_, _, key, value, text, enabled):
            return ItemListSwitchItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: text,
                value: value,
                enabled: enabled,
                maximumNumberOfLines: 0,
                sectionId: self.section,
                style: .blocks,
                updated: { value in
                    arguments.setBool(key, value)
                }
            )
        case let .notice(_, _, text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .disclosure(_, _, link, text, value):
            return ItemListDisclosureItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: text,
                label: value,
                sectionId: self.section,
                style: .blocks
            ) {
                arguments.openLink(link)
            }
        case let .action(_, _, actionType, text, destructive):
            return ItemListActionItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: text,
                kind: destructive ? .destructive : .generic,
                alignment: .natural,
                sectionId: self.section,
                style: .blocks,
                action: {
                    arguments.run(actionType)
                }
            )
        }
    }
}

private enum SGPrivacyLink: Hashable {
    case archived(kind: SGArchiveKind)
    case appIcon
}

private enum SGPrivacyAction: Hashable {
    case clearArchive(kind: SGArchiveKind)
}

private struct SGPrivacyArguments {
    let setBool: (SGPrivacySettings.Key, Bool) -> Void
    let openLink: (SGPrivacyLink) -> Void
    let run: (SGPrivacyAction) -> Void
}

private func sgCountLabel(_ kind: SGArchiveKind) -> String {
    let count = SGMessageArchive.shared.load(kind: kind).count
    return count > 0 ? "\(count)" : "—"
}

private func sgFootprintLabel() -> String {
    let bytes = SGMessageArchive.shared.footprint()
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    return formatter.string(fromByteCount: bytes)
}

private func sgPrivacyEntries(context: AccountContext) -> [SGPrivacyEntry] {
    let settings = SGPrivacySettings.shared
    var entries: [SGPrivacyEntry] = []
    var id = 0
    func next() -> Int {
        id += 1
        return id
    }

    entries.append(.header(id: next(), section: .ghost, text: "РЕЖИМ ПРИЗРАКА"))
    entries.append(.toggle(id: next(), section: .ghost, key: .ghostMode, value: settings.ghostMode, text: "Включить режим призрака", enabled: true))
    entries.append(.notice(id: next(), section: .ghost, text: "Пока включено, приложение не сообщает серверу о вашей активности. Галочки прочтения и «был(а) в сети» у собеседников не появляются."))
    entries.append(.toggle(id: next(), section: .ghost, key: .ghostHideOnline, value: settings.ghostHideOnline, text: "Скрывать онлайн-статус", enabled: settings.ghostMode))
    entries.append(.toggle(id: next(), section: .ghost, key: .ghostHideReadReceipts, value: settings.ghostHideReadReceipts, text: "Не отправлять прочтения", enabled: settings.ghostMode))
    entries.append(.toggle(id: next(), section: .ghost, key: .ghostHideActivity, value: settings.ghostHideActivity, text: "Не отправлять «печатает…»", enabled: settings.ghostMode))

    entries.append(.header(id: next(), section: .antiDelete, text: "УДАЛЁННЫЕ СООБЩЕНИЯ"))
    entries.append(.toggle(id: next(), section: .antiDelete, key: .antiDelete, value: settings.antiDelete, text: "Сохранять удалённые сообщения", enabled: true))
    entries.append(.notice(id: next(), section: .antiDelete, text: "Сообщения, удалённые вами или собеседником, складываются в архив. Хранятся текст, время и вложения-файлы; сами медиафайлы приходят уже удалёнными с сервера, поэтому вложения остаются ссылками."))
    entries.append(.toggle(id: next(), section: .antiDelete, key: .antiDeleteSaveMedia, value: settings.antiDeleteSaveMedia, text: "Сохранять вложения", enabled: settings.antiDelete))

    entries.append(.header(id: next(), section: .viewOnce, text: "ОДНОРАЗОВЫЕ СООБЩЕНИЯ"))
    entries.append(.toggle(id: next(), section: .viewOnce, key: .keepViewOnce, value: settings.keepViewOnce, text: "Сохранять одноразовые сообщения", enabled: true))
    entries.append(.notice(id: next(), section: .viewOnce, text: "Открытое одноразовое сообщение копируется в архив, а серверу не уходит отметка о прочтении — содержимое не выгорает и не исчезает по таймеру."))
    entries.append(.toggle(id: next(), section: .viewOnce, key: .keepViewOnceSaveMedia, value: settings.keepViewOnceSaveMedia, text: "Сохранять файлы", enabled: settings.keepViewOnce))

    entries.append(.header(id: next(), section: .archive, text: "АРХИВ"))
    entries.append(.disclosure(id: next(), section: .archive, link: .archived(kind: .deleted), text: "Удалённые сообщения", value: sgCountLabel(.deleted)))
    entries.append(.disclosure(id: next(), section: .archive, link: .archived(kind: .viewOnce), text: "Одноразовые сообщения", value: sgCountLabel(.viewOnce)))
    entries.append(.disclosure(id: next(), section: .archive, link: .appIcon, text: "Иконка приложения", value: SGAppIcon.selectedIcon(context: context)?.title ?? "—"))
    entries.append(.action(id: next(), section: .archive, actionType: .clearArchive(kind: .deleted), text: "Очистить архив удалённых", destructive: true))
    entries.append(.action(id: next(), section: .archive, actionType: .clearArchive(kind: .viewOnce), text: "Очистить архив одноразовых", destructive: true))

    entries.append(.header(id: next(), section: .about, text: "ХРАНИЛИЩЕ"))
    entries.append(.notice(id: next(), section: .about, text: "Занято: \(sgFootprintLabel())"))
    return entries
}

/// Экран приватности: режим призрака, anti-delete, одноразовые, архив, иконка.
public func sgPrivacyController(context: AccountContext) -> ViewController {
    var pushControllerImpl: ((ViewController) -> Void)?

    let reloadPromise = ValuePromise(true, ignoreRepeated: false)
    let archiveChanged = Signal<Void, NoError> { subscriber in
        // Первое значение — обязательно: combineLatest ждёт, пока каждый источник
        // отдаст хоть что-то, а уведомления до первого изменения не будет.
        subscriber.putNext(())
        let token = NotificationCenter.default.addObserver(
            forName: SGMessageArchive.didChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            subscriber.putNext(())
        }
        return ActionDisposable {
            NotificationCenter.default.removeObserver(token)
        }
    }
    let reloadSignal = combineLatest(reloadPromise.get(), archiveChanged)
    |> map { _, _ in true }

    let arguments = SGPrivacyArguments(
        setBool: { key, value in
            SGPrivacySettings.shared.set(key, value)
            reloadPromise.set(true)
        },
        openLink: { link in
            switch link {
            case let .archived(kind):
                pushControllerImpl?(sgArchivedMessagesController(context: context, kind: kind))
            case .appIcon:
                pushControllerImpl?(sgAppIconsController(context: context))
            }
        },
        run: { action in
            switch action {
            case let .clearArchive(kind):
                SGMessageArchive.shared.removeAll(kind: kind)
                reloadPromise.set(true)
            }
        }
    )

    let signal = combineLatest(context.sharedContext.presentationData, reloadSignal)
    |> map { presentationData, _ -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text("Приватность"),
            leftNavigationButton: nil,
            rightNavigationButton: nil,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)
        )
        let listState = ItemListNodeState(
            presentationData: ItemListPresentationData(presentationData),
            entries: sgPrivacyEntries(context: context),
            style: .blocks,
            ensureVisibleItemTag: nil,
            initialScrollToItem: nil
        )
        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    pushControllerImpl = { [weak controller] c in
        (controller?.navigationController as? NavigationController)?.pushViewController(c)
    }
    return controller
}