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

private enum SGAppIconEntry: ItemListNodeEntry {
    case header(id: Int, text: String)
    case icon(id: Int, icon: SGAppIcon, selected: Bool, locked: Bool)

    var section: ItemListSectionId {
        return 0
    }

    var stableId: Int {
        switch self {
        case let .header(id, _):
            return id
        case let .icon(id, _, _, _):
            return id
        }
    }

    static func < (lhs: SGAppIconEntry, rhs: SGAppIconEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    static func == (lhs: SGAppIconEntry, rhs: SGAppIconEntry) -> Bool {
        return lhs.stableId == rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        switch self {
        case let .header(_, text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, badge: nil, sectionId: self.section)
        case let .icon(_, icon, selected, locked):
            let arguments = arguments as! SGAppIconArguments
            let suffix = selected ? "  ✓" : (locked ? "  🔒" : "")
return ItemListDisclosureItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: title,
                enabled: !locked,
                label: "",
                sectionId: self.section,
                style: .blocks
            ) {
                arguments.select(icon)
            }
        }
    }
}

private struct SGAppIconArguments {
    let select: (SGAppIcon) -> Void
}

private func sgAppIconEntries(icons: [SGAppIcon], selected: SGAppIcon?) -> [SGAppIconEntry] {
    var entries: [SGAppIconEntry] = [SGAppIconEntry.header(id: 0, text: "ИКОНКА ПРИЛОЖЕНИЯ")]
    for (index, icon) in icons.enumerated() {
        entries.append(.icon(
            id: index + 1,
            icon: icon,
            selected: icon == selected,
            locked: icon.isSGPro || icon.isPremium
        ))
    }
    return entries
}

/// Экран выбора иконки приложения.
///
/// Дублирует секцию «Иконка приложения» на экране кастомизации — там выбор
/// встроен в сетку. Оставлен как отдельная точка входа из «Приватности»,
/// где список идёт текстом и читается без прокрутки.
public func sgAppIconsController(context: AccountContext) -> ViewController {
    var presentControllerImpl: ((ViewController, ViewControllerPresentationArguments?) -> Void)?
    let promise = ValuePromise(SGAppIcon.selectedIcon(context: context), ignoreRepeated: true)

    let arguments = SGAppIconArguments(select: { icon in
        guard !icon.isSGPro, !icon.isPremium else {
            return
        }
        SGAppIconManager.apply(icon) { error in
            if let error = error {
                let presentationData = context.sharedContext.currentPresentationData.with { $0 }
                presentControllerImpl?(
                    UndoOverlayController(
                        presentationData: presentationData,
                        content: .info(title: nil, text: error.localizedDescription, timeout: nil, customUndoText: nil),
                        elevatedLayout: false,
                        action: { _ in false }
                    ),
                    nil
                )
            } else {
                promise.set(icon)
            }
        }
    })

    let signal = combineLatest(context.sharedContext.presentationData, promise.get())
    |> map { presentationData, selected -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text("Иконка"),
            leftNavigationButton: nil,
            rightNavigationButton: nil,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)
        )
        let listState = ItemListNodeState(
            presentationData: ItemListPresentationData(presentationData),
            entries: sgAppIconEntries(icons: SGAppIcon.icons(context: context), selected: selected),
            style: .blocks,
            ensureVisibleItemTag: nil,
            initialScrollToItem: nil
        )
        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    presentControllerImpl = { [weak controller] c, a in
        controller?.present(c, in: .window(.root), with: a)
    }
    return controller
}