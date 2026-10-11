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

private enum SGArchiveEntry: ItemListNodeEntry {
    case header(id: Int, text: String)
    case message(id: Int, entry: SGArchivedMessage, dateText: String, preview: String)

    var section: ItemListSectionId {
        return 0
    }

    var stableId: Int {
        switch self {
        case let .header(id, _):
            return id
        case let .message(id, _, _, _):
            return id
        }
    }

    static func < (lhs: SGArchiveEntry, rhs: SGArchiveEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    static func == (lhs: SGArchiveEntry, rhs: SGArchiveEntry) -> Bool {
        return lhs.stableId == rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        switch self {
        case let .header(_, text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, badge: nil, sectionId: self.section)
        case let .message(_, entry, dateText, preview):
            let arguments = arguments as! SGArchiveArguments
            let title = entry.isOutgoing ? "Вы: \(preview)" : preview
            return ItemListDisclosureItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: title,
                label: dateText,
                sectionId: self.section,
                style: .blocks
            ) {
                arguments.open(entry)
            }
        }
    }
}

private struct SGArchiveArguments {
    let open: (SGArchivedMessage) -> Void
}

private func sgDateFormatter() -> DateFormatter {
    let formatter = DateFormatter()
    formatter.dateStyle = .short
    formatter.timeStyle = .short
    return formatter
}

private func sgArchivePreview(_ entry: SGArchivedMessage) -> String {
    var text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
    if !entry.mediaFileNames.isEmpty {
        let files = entry.mediaFileNames.count == 1 ? "1 файл" : "\(entry.mediaFileNames.count) файлов"
        text = text.isEmpty ? "📎 \(files)" : "📎 \(files) · \(text)"
    }
    if text.isEmpty {
        return "(без текста)"
    }
    return text.count > 120 ? String(text.prefix(120)) + "…" : text
}

private func sgArchiveEntries(kind: SGArchiveKind) -> [SGArchiveEntry] {
    let formatter = sgDateFormatter()
    let messages = SGMessageArchive.shared.load(kind: kind)
    guard !messages.isEmpty else {
        return []
    }
    var entries: [SGArchiveEntry] = [
        .header(id: 0, text: "\(messages.count) \(sgPlural(messages.count))")
    ]
    for (index, message) in messages.enumerated() {
        let date = Date(timeIntervalSince1970: TimeInterval(message.timestamp))
        entries.append(.message(
            id: index + 1,
            entry: message,
            dateText: formatter.string(from: date),
            preview: sgArchivePreview(message)
        ))
    }
    return entries
}

private func sgPlural(_ count: Int) -> String {
    let mod100 = count % 100
    if (11...14).contains(mod100) {
        return "сообщений"
    }
    switch count % 10 {
    case 1:
        return "сообщение"
    case 2...4:
        return "сообщения"
    default:
        return "сообщений"
    }
}

private enum SGArchiveDetailEntry: ItemListNodeEntry {
    case text(id: Int, text: String)
    case header(id: Int, text: String)

    var section: ItemListSectionId {
        return 0
    }

    var stableId: Int {
        switch self {
        case let .text(id, _):
            return id
        case let .header(id, _):
            return id
        }
    }

    static func < (lhs: SGArchiveDetailEntry, rhs: SGArchiveDetailEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    static func == (lhs: SGArchiveDetailEntry, rhs: SGArchiveDetailEntry) -> Bool {
        return lhs.stableId == rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        switch self {
        case let .text(_, text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .header(_, text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, badge: nil, sectionId: self.section)
        }
    }
}

/// Просмотр одной записи архива: полный текст и список сохранённых файлов.
public func sgArchivedMessageController(context: AccountContext, entry: SGArchivedMessage) -> ViewController {
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }

    let fileNames = entry.mediaFileNames.isEmpty
        ? "Файлы не сохранены"
        : entry.mediaFileNames.map { "• \($0)" }.joined(separator: "\n")

    let entries: [SGArchiveDetailEntry] = [
        .text(id: 0, text: entry.text.isEmpty ? "(без текста)" : entry.text),
        .header(id: 1, text: "Вложения"),
        .text(id: 2, text: fileNames)
    ]

    let controllerState = ItemListControllerState(
        presentationData: ItemListPresentationData(presentationData),
        title: .text("Сообщение"),
        leftNavigationButton: nil,
        rightNavigationButton: nil,
        backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)
    )
    let listState = ItemListNodeState(
        presentationData: ItemListPresentationData(presentationData),
        entries: entries,
        style: .blocks,
        ensureVisibleItemTag: nil,
        initialScrollToItem: nil
    )

    return ItemListController(
        context: context,
        state: ValuePromise(true, ignoreRepeated: true).get()
        |> map { _ -> (ItemListControllerState, (ItemListNodeState, Any)) in
            return (controllerState, (listState, Void()))
        }
    )
}

/// Экран архива: удалённые или одноразовые сообщения.
public func sgArchivedMessagesController(context: AccountContext, kind: SGArchiveKind) -> ViewController {
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

    let arguments = SGArchiveArguments(open: { entry in
        pushControllerImpl?(sgArchivedMessageController(context: context, entry: entry))
    })

    let title = kind == .deleted ? "Удалённые сообщения" : "Одноразовые сообщения"

    let signal = combineLatest(context.sharedContext.presentationData, reloadSignal)
    |> map { presentationData, _ -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text(title),
            leftNavigationButton: nil,
            rightNavigationButton: nil,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)
        )
        let listState = ItemListNodeState(
            presentationData: ItemListPresentationData(presentationData),
            entries: sgArchiveEntries(kind: kind),
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