import Cocoa
import UniformTypeIdentifiers

/// NSTableView that only allows row drag when the mouse-down originated in
/// a designated drag-handle column. Without this filter NSTableView happily
/// starts a drag from anywhere on the row, so a user adjusting a popup risks
/// accidentally reordering the table.
final class RuleTableView: NSTableView {
    /// Column identifier that acts as the row-drag grabber. Mouse-downs
    /// outside this column are still delivered normally (clicks, popup
    /// activation, text editing) but won't initiate drag.
    var dragHandleColumnID: String?
    fileprivate(set) var dragInitiatedFromHandle = false

    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        let col = column(at: pt)
        if col >= 0, col < tableColumns.count,
           tableColumns[col].identifier.rawValue == dragHandleColumnID {
            dragInitiatedFromHandle = true
        } else {
            dragInitiatedFromHandle = false
        }
        super.mouseDown(with: event)
    }
}

/// Small "grip" icon shown at the start of each rule row. Purely visual: the
/// row's drag is initiated by NSTableView when the user mouse-drags anywhere
/// inside a row (see `tableView(_:pasteboardWriterForRow:)`). The handle's
/// jobs are (a) signal draggability with an open-hand cursor on hover, and
/// (b) give users an obvious target to grab when they don't want to risk
/// clicking a checkbox / popup by accident.
final class DragHandleView: NSView {
    private var trackingArea: NSTrackingArea?
    override var intrinsicContentSize: NSSize { NSSize(width: 16, height: 16) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        let img = NSImageView()
        img.image = NSImage(systemSymbolName: "line.3.horizontal",
                            accessibilityDescription: "Drag to reorder")
        img.contentTintColor = .tertiaryLabelColor
        img.translatesAutoresizingMaskIntoConstraints = false
        addSubview(img)
        NSLayoutConstraint.activate([
            img.centerXAnchor.constraint(equalTo: centerXAnchor),
            img.centerYAnchor.constraint(equalTo: centerYAnchor),
            img.widthAnchor.constraint(equalToConstant: 14),
            img.heightAnchor.constraint(equalToConstant: 14),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    // NSTableView aggressively manages cursor rects, so addCursorRect doesn't
    // stick. A tracking area + explicit push/pop in mouseEntered/Exited makes
    // the hand cursor reliably appear over the handle.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        NSCursor.openHand.push()
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.pop()
    }
}

class SettingsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private var appTableView: NSTableView!
    private var termTableView: NSTableView!
    private let inputSources = listInputSources()

    convenience init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = "TermIMS Settings"
        w.center()
        w.minSize = NSSize(width: 620, height: 380)
        w.isReleasedWhenClosed = false
        self.init(window: w)
        buildUI()
    }

    // MARK: Tab Builder

    private func buildUI() {
        guard let cv = window?.contentView else { return }
        let tabView = NSTabView()
        tabView.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(tabView)
        NSLayoutConstraint.activate([
            tabView.topAnchor.constraint(equalTo: cv.topAnchor, constant: 8),
            tabView.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 8),
            tabView.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -8),
            tabView.bottomAnchor.constraint(equalTo: cv.bottomAnchor, constant: -8),
        ])

        let t1 = NSTabViewItem(identifier: "general"); t1.label = "General"
        t1.view = buildGeneralTab()
        let t2 = NSTabViewItem(identifier: "apps"); t2.label = "App Rules"
        t2.view = buildAppRulesTab()
        let t3 = NSTabViewItem(identifier: "terminal"); t3.label = "Terminal Rules"
        t3.view = buildTerminalRulesTab()

        tabView.addTabViewItem(t1)
        tabView.addTabViewItem(t2)
        tabView.addTabViewItem(t3)

        appTableView.dataSource = self; appTableView.delegate = self
        termTableView.dataSource = self; termTableView.delegate = self
        appTableView.registerForDraggedTypes([Self.appRowDragType])
        termTableView.registerForDraggedTypes([Self.termRowDragType])
        appTableView.draggingDestinationFeedbackStyle = .gap
        termTableView.draggingDestinationFeedbackStyle = .gap
    }

    static let appRowDragType  = NSPasteboard.PasteboardType("top.cuiko.termims.app-rule-row")
    static let termRowDragType = NSPasteboard.PasteboardType("top.cuiko.termims.term-rule-row")

    // MARK: General Tab

    private func buildGeneralTab() -> NSView {
        let v = NSView()
        let store = RuleStore.shared

        let defLabel = label("Default Input Method:")
        let defPopup = imPopup(selected: store.defaultSourceID, includeNone: true)
        defPopup.tag = 900
        defPopup.target = self; defPopup.action = #selector(defaultIMChanged(_:))

        let sep1 = separator()
        let indLabel = label("Indicator")
        indLabel.font = .systemFont(ofSize: 13, weight: .semibold)

        let indCheck = NSButton(checkboxWithTitle: "Show input method indicator on switch",
                                target: self, action: #selector(indicatorToggled(_:)))
        indCheck.translatesAutoresizingMaskIntoConstraints = false
        indCheck.state = store.indicatorEnabled ? .on : .off

        let posLabel = label("Position:")
        let posPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        posPopup.translatesAutoresizingMaskIntoConstraints = false
        for p in IndicatorPosition.allCases { posPopup.addItem(withTitle: p.rawValue) }
        if let idx = IndicatorPosition.allCases.firstIndex(of: store.indicatorPosition) {
            posPopup.selectItem(at: idx)
        }
        posPopup.target = self; posPopup.action = #selector(indicatorPosChanged(_:))

        let sep2 = separator()
        let appLabel = label("Application")
        appLabel.font = .systemFont(ofSize: 13, weight: .semibold)

        let hideCheck = NSButton(checkboxWithTitle: "Hide menu bar icon (reopen app to show Settings)",
                                 target: self, action: #selector(hideIconToggled(_:)))
        hideCheck.translatesAutoresizingMaskIntoConstraints = false
        hideCheck.state = store.hideMenuBarIcon ? .on : .off

        let sep3 = separator()
        let debugLabel = label("Debug")
        debugLabel.font = .systemFont(ofSize: 13, weight: .semibold)

        let debugCheck = NSButton(checkboxWithTitle: "Enable debug logging",
                                  target: self, action: #selector(debugLogToggled(_:)))
        debugCheck.translatesAutoresizingMaskIntoConstraints = false
        debugCheck.state = store.debugLogEnabled ? .on : .off

        let clearBtn = NSButton(title: "Clear Log", target: self, action: #selector(clearDebugLog(_:)))
        clearBtn.translatesAutoresizingMaskIntoConstraints = false
        clearBtn.bezelStyle = .rounded
        clearBtn.controlSize = .regular

        for sub in [defLabel, defPopup, sep1, indLabel, indCheck, posLabel, posPopup,
                    sep2, appLabel, hideCheck,
                    sep3, debugLabel, debugCheck, clearBtn] { v.addSubview(sub) }
        NSLayoutConstraint.activate([
            defLabel.topAnchor.constraint(equalTo: v.topAnchor, constant: 20),
            defLabel.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 16),
            defPopup.centerYAnchor.constraint(equalTo: defLabel.centerYAnchor),
            defPopup.leadingAnchor.constraint(equalTo: defLabel.trailingAnchor, constant: 8),
            defPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),

            sep1.topAnchor.constraint(equalTo: defLabel.bottomAnchor, constant: 20),
            sep1.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 12),
            sep1.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -12),

            indLabel.topAnchor.constraint(equalTo: sep1.bottomAnchor, constant: 16),
            indLabel.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 16),
            indCheck.topAnchor.constraint(equalTo: indLabel.bottomAnchor, constant: 10),
            indCheck.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 16),
            posLabel.topAnchor.constraint(equalTo: indCheck.bottomAnchor, constant: 12),
            posLabel.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 16),
            posPopup.centerYAnchor.constraint(equalTo: posLabel.centerYAnchor),
            posPopup.leadingAnchor.constraint(equalTo: posLabel.trailingAnchor, constant: 8),
            posPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),

            sep2.topAnchor.constraint(equalTo: posLabel.bottomAnchor, constant: 20),
            sep2.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 12),
            sep2.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -12),

            appLabel.topAnchor.constraint(equalTo: sep2.bottomAnchor, constant: 16),
            appLabel.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 16),
            hideCheck.topAnchor.constraint(equalTo: appLabel.bottomAnchor, constant: 10),
            hideCheck.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 16),

            sep3.topAnchor.constraint(equalTo: hideCheck.bottomAnchor, constant: 20),
            sep3.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 12),
            sep3.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -12),

            debugLabel.topAnchor.constraint(equalTo: sep3.bottomAnchor, constant: 16),
            debugLabel.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 16),
            debugCheck.topAnchor.constraint(equalTo: debugLabel.bottomAnchor, constant: 10),
            debugCheck.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 16),
            clearBtn.centerYAnchor.constraint(equalTo: debugCheck.centerYAnchor),
            clearBtn.leadingAnchor.constraint(equalTo: debugCheck.trailingAnchor, constant: 12),
        ])
        return v
    }

    @objc private func defaultIMChanged(_ sender: NSPopUpButton) {
        let store = RuleStore.shared
        if sender.indexOfSelectedItem == 0 {
            store.defaultSourceName = nil; store.defaultSourceID = nil
        } else {
            let src = inputSources[sender.indexOfSelectedItem - 1]
            store.defaultSourceName = src.name; store.defaultSourceID = src.id
        }
    }
    @objc private func indicatorToggled(_ sender: NSButton) {
        RuleStore.shared.indicatorEnabled = sender.state == .on
    }
    @objc private func indicatorPosChanged(_ sender: NSPopUpButton) {
        RuleStore.shared.indicatorPosition = IndicatorPosition.allCases[sender.indexOfSelectedItem]
    }
    @objc private func hideIconToggled(_ sender: NSButton) {
        RuleStore.shared.hideMenuBarIcon = sender.state == .on
    }
    @objc private func debugLogToggled(_ sender: NSButton) {
        RuleStore.shared.debugLogEnabled = sender.state == .on
    }
    @objc private func clearDebugLog(_ sender: NSButton) {
        Log.clear()
    }

    // MARK: App Rules Tab

    private func buildAppRulesTab() -> NSView {
        let v = NSView()
        let sv = scrolledTable(&appTableView)
        let addBtn = smallButton("+", action: #selector(addAppRule))
        let rmBtn  = smallButton("\u{2212}", action: #selector(removeAppRule))
        for sub in [sv, addBtn, rmBtn] { v.addSubview(sub) }
        NSLayoutConstraint.activate([
            sv.topAnchor.constraint(equalTo: v.topAnchor, constant: 12),
            sv.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 8),
            sv.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -8),
            sv.bottomAnchor.constraint(equalTo: addBtn.topAnchor, constant: -6),
            addBtn.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 8),
            addBtn.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -8),
            rmBtn.leadingAnchor.constraint(equalTo: addBtn.trailingAnchor),
            rmBtn.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -8),
        ])
        return v
    }

    @objc private func addAppRule() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.applicationBundle]
        panel.beginSheetModal(for: window!) { resp in
            guard resp == .OK, let url = panel.url, let b = Bundle(url: url),
                  let bid = b.bundleIdentifier else { return }
            var rules = RuleStore.shared.rules
            if rules.contains(where: { $0.appBundleID == bid }) { return }
            let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            let im = self.inputSources.first { $0.id.contains("ABC") } ?? self.inputSources.first
                     ?? IMSource(id: "com.apple.keylayout.ABC", name: "ABC")
            rules.append(Rule(appBundleID: bid, appName: name, inputSourceID: im.id, inputSourceName: im.name))
            RuleStore.shared.rules = rules
            self.appTableView.reloadData()
        }
    }
    @objc private func removeAppRule() {
        let r = appTableView.selectedRow; guard r >= 0 else { return }
        var rules = RuleStore.shared.rules; rules.remove(at: r)
        RuleStore.shared.rules = rules; appTableView.reloadData()
    }

    // MARK: Terminal Rules Tab

    private func buildTerminalRulesTab() -> NSView {
        let v = NSView()
        let store = RuleStore.shared

        let defLabel = label("Default Input Method (in terminal):")
        let defPopup = imPopup(selected: store.terminalDefaultSourceID, includeNone: true)
        defPopup.tag = 901
        defPopup.target = self; defPopup.action = #selector(termDefaultIMChanged(_:))

        let hintLabel = label("When a terminal tab matches a rule below, switch to that rule's input method instead:")
        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .secondaryLabelColor

        let sv = scrolledTermTable(&termTableView)
        let addBtn = smallButton("+", action: #selector(addTermRule))
        let rmBtn  = smallButton("\u{2212}", action: #selector(removeTermRule))

        for sub in [defLabel, defPopup, hintLabel, sv, addBtn, rmBtn] { v.addSubview(sub) }
        NSLayoutConstraint.activate([
            defLabel.topAnchor.constraint(equalTo: v.topAnchor, constant: 14),
            defLabel.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 12),
            defPopup.centerYAnchor.constraint(equalTo: defLabel.centerYAnchor),
            defPopup.leadingAnchor.constraint(equalTo: defLabel.trailingAnchor, constant: 8),
            defPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),

            hintLabel.topAnchor.constraint(equalTo: defLabel.bottomAnchor, constant: 10),
            hintLabel.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 12),
            hintLabel.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -12),

            sv.topAnchor.constraint(equalTo: hintLabel.bottomAnchor, constant: 8),
            sv.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 8),
            sv.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -8),
            sv.bottomAnchor.constraint(equalTo: addBtn.topAnchor, constant: -6),
            addBtn.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 8),
            addBtn.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -8),
            rmBtn.leadingAnchor.constraint(equalTo: addBtn.trailingAnchor),
            rmBtn.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -8),
        ])
        return v
    }

    @objc private func termDefaultIMChanged(_ sender: NSPopUpButton) {
        let store = RuleStore.shared
        if sender.indexOfSelectedItem == 0 {
            store.terminalDefaultSourceName = nil; store.terminalDefaultSourceID = nil
        } else {
            let src = inputSources[sender.indexOfSelectedItem - 1]
            store.terminalDefaultSourceName = src.name; store.terminalDefaultSourceID = src.id
        }
    }

    @objc private func addTermRule() {
        let im = inputSources.first { $0.id.contains("ABC") } ?? inputSources.first
                 ?? IMSource(id: "com.apple.keylayout.ABC", name: "ABC")
        var rules = RuleStore.shared.terminalRules
        rules.append(TerminalRule(inputSourceID: im.id, inputSourceName: im.name))
        RuleStore.shared.terminalRules = rules
        termTableView.reloadData()
    }

    @objc private func removeTermRule() {
        let r = termTableView.selectedRow; guard r >= 0 else { return }
        var rules = RuleStore.shared.terminalRules; rules.remove(at: r)
        RuleStore.shared.terminalRules = rules; termTableView.reloadData()
    }

    private func scrolledTermTable(_ tv: inout NSTableView!) -> NSScrollView {
        let sv = NSScrollView(); sv.translatesAutoresizingMaskIntoConstraints = false
        sv.hasVerticalScroller = true; sv.borderType = .bezelBorder
        let rtv = RuleTableView()
        rtv.dragHandleColumnID = "tdrag"
        tv = rtv
        tv.usesAlternatingRowBackgroundColors = true; tv.rowHeight = 24
        let colDrag = NSTableColumn(identifier: .init("tdrag")); colDrag.title = ""; colDrag.width = 24; colDrag.minWidth = 24; colDrag.maxWidth = 24
        let colOn = NSTableColumn(identifier: .init("ton")); colOn.title = ""; colOn.width = 30; colOn.minWidth = 30; colOn.maxWidth = 30
        let colType = NSTableColumn(identifier: .init("ttype")); colType.title = "Match"; colType.width = 100; colType.minWidth = 80
        let colPat = NSTableColumn(identifier: .init("tpat")); colPat.title = "Pattern"; colPat.width = 140; colPat.minWidth = 80
        let colIM = NSTableColumn(identifier: .init("tim")); colIM.title = "Input Method"; colIM.width = 160; colIM.minWidth = 120
        let colNote = NSTableColumn(identifier: .init("tnote")); colNote.title = "Note"; colNote.width = 140; colNote.minWidth = 80
        tv.addTableColumn(colDrag); tv.addTableColumn(colOn); tv.addTableColumn(colType); tv.addTableColumn(colPat); tv.addTableColumn(colIM); tv.addTableColumn(colNote)
        sv.documentView = tv; return sv
    }

    // MARK: Table Drag Reordering

    func tableView(_ tv: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        // Only allow drag when the mouse-down was on the drag handle column —
        // see RuleTableView.mouseDown. Prevents accidental row reorder when a
        // user drags a popup or text field to select / scroll.
        if let rtv = tv as? RuleTableView, !rtv.dragInitiatedFromHandle { return nil }
        let item = NSPasteboardItem()
        let type = (tv === termTableView) ? Self.termRowDragType : Self.appRowDragType
        item.setString("\(row)", forType: type)
        return item
    }

    func tableView(_ tv: NSTableView,
                   validateDrop info: NSDraggingInfo,
                   proposedRow row: Int,
                   proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
        guard op == .above else { return [] }
        return .move
    }

    func tableView(_ tv: NSTableView,
                   acceptDrop info: NSDraggingInfo,
                   row: Int,
                   dropOperation op: NSTableView.DropOperation) -> Bool {
        let type = (tv === termTableView) ? Self.termRowDragType : Self.appRowDragType
        guard let items = info.draggingPasteboard.pasteboardItems,
              let str = items.first?.string(forType: type),
              let src = Int(str), src != row, src != row - 1 else { return false }

        if tv === termTableView {
            var rules = RuleStore.shared.terminalRules
            let dst = src < row ? row - 1 : row
            let moved = rules.remove(at: src)
            rules.insert(moved, at: dst)
            RuleStore.shared.terminalRules = rules
        } else {
            var rules = RuleStore.shared.rules
            let dst = src < row ? row - 1 : row
            let moved = rules.remove(at: src)
            rules.insert(moved, at: dst)
            RuleStore.shared.rules = rules
        }
        tv.reloadData()
        return true
    }

    // MARK: Table DataSource / Delegate

    func numberOfRows(in tv: NSTableView) -> Int {
        if tv === termTableView { return RuleStore.shared.terminalRules.count }
        return RuleStore.shared.rules.count
    }

    func tableView(_ tv: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        if tv === termTableView { return termTableCellView(col, row: row) }
        let rules = RuleStore.shared.rules
        guard row < rules.count else { return nil }
        let rule = rules[row]
        switch col?.identifier.rawValue {
        case "adrag":
            return centeredNarrowCellView(tv, id: "adrag\(row)", control: DragHandleView())
        case "on":
            let btn = recycledCheckbox(tv, id: "aon")
            btn.state = rule.enabled ? .on : .off; btn.tag = row
            btn.target = self; btn.action = #selector(appToggle(_:))
            return centeredNarrowCellView(tv, id: "aon\(row)", control: btn)
        case "app":
            let cell = recycledAppCell(tv)
            cell.textField?.stringValue = rule.appName
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: rule.appBundleID) {
                cell.imageView?.image = NSWorkspace.shared.icon(forFile: url.path)
            } else {
                cell.imageView?.image = NSImage(systemSymbolName: "app", accessibilityDescription: nil)
            }
            return cell
        case "im":
            let popup = recycledIMPopup(tv, id: "aim")
            configureIMPopup(popup, selected: rule.inputSourceID, row: row)
            popup.target = self; popup.action = #selector(appIMChanged(_:))
            return popup
        default: return nil
        }
    }

    /// Stretches the control to fill the full cell width — used for wide
    /// controls (popup buttons, text fields). The table's default 3pt
    /// horizontal intercell spacing keeps a small gap between columns
    /// (macOS standard), while controls themselves occupy 100% of their
    /// own cell.
    private func centeredCellView(_ tv: NSTableView, id: String, control: NSView) -> NSView {
        let cell = NSTableCellView()
        cell.identifier = NSUserInterfaceItemIdentifier(id + "cell")
        control.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(control)
        NSLayoutConstraint.activate([
            control.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            control.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
            control.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    /// Centers a narrow control (checkbox, drag handle) at its intrinsic size
    /// inside the cell. Stretching a checkbox via leading/trailing pins the
    /// visible glyph to the left of the cell — using centerX keeps it
    /// visually centered under the column header.
    private func centeredNarrowCellView(_ tv: NSTableView, id: String, control: NSView) -> NSView {
        let cell = NSTableCellView()
        cell.identifier = NSUserInterfaceItemIdentifier(id + "cell")
        control.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(control)
        NSLayoutConstraint.activate([
            control.centerXAnchor.constraint(equalTo: cell.centerXAnchor),
            control.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private func termTableCellView(_ col: NSTableColumn?, row: Int) -> NSView? {
        let rules = RuleStore.shared.terminalRules
        guard row < rules.count else { return nil }
        let rule = rules[row]
        switch col?.identifier.rawValue {
        case "tdrag":
            return centeredNarrowCellView(termTableView, id: "tdrag\(row)", control: DragHandleView())
        case "ton":
            let btn = recycledCheckbox(termTableView, id: "ton")
            btn.state = rule.enabled ? .on : .off; btn.tag = row
            btn.target = self; btn.action = #selector(termToggle(_:))
            return centeredNarrowCellView(termTableView, id: "ton\(row)", control: btn)
        case "ttype":
            let popup = recycledMatchTypePopup(termTableView)
            popup.removeAllItems()
            for t in TerminalMatchType.allCases { popup.addItem(withTitle: t.rawValue) }
            if let idx = TerminalMatchType.allCases.firstIndex(of: rule.matchType) { popup.selectItem(at: idx) }
            popup.tag = row
            popup.target = self; popup.action = #selector(termMatchTypeChanged(_:))
            return centeredCellView(termTableView, id: "ttype\(row)", control: popup)
        case "tpat":
            let tf = recycledPatternField(termTableView)
            tf.stringValue = rule.pattern; tf.tag = row
            tf.target = self; tf.action = #selector(termPatternChanged(_:))
            return centeredCellView(termTableView, id: "tpat\(row)", control: tf)
        case "tim":
            let popup = recycledIMPopup(termTableView, id: "tim")
            configureIMPopup(popup, selected: rule.inputSourceID, row: row)
            popup.target = self; popup.action = #selector(termIMChanged(_:))
            return centeredCellView(termTableView, id: "tim\(row)", control: popup)
        case "tnote":
            let tf = recycledNoteField(termTableView)
            tf.stringValue = rule.note; tf.tag = row
            tf.target = self; tf.action = #selector(termNoteChanged(_:))
            return centeredCellView(termTableView, id: "tnote\(row)", control: tf)
        default: return nil
        }
    }

    // MARK: Table Actions

    @objc private func appToggle(_ s: NSButton) {
        var r = RuleStore.shared.rules; guard s.tag < r.count else { return }
        r[s.tag].enabled = s.state == .on; RuleStore.shared.rules = r
    }
    @objc private func appIMChanged(_ s: NSPopUpButton) {
        var r = RuleStore.shared.rules
        guard s.tag < r.count, let item = s.selectedItem, let sid = item.representedObject as? String else { return }
        r[s.tag].inputSourceID = sid; r[s.tag].inputSourceName = item.title; RuleStore.shared.rules = r
    }

    @objc private func termToggle(_ s: NSButton) {
        var r = RuleStore.shared.terminalRules; guard s.tag < r.count else { return }
        r[s.tag].enabled = s.state == .on; RuleStore.shared.terminalRules = r
    }
    @objc private func termMatchTypeChanged(_ s: NSPopUpButton) {
        var r = RuleStore.shared.terminalRules; guard s.tag < r.count else { return }
        r[s.tag].matchType = TerminalMatchType.allCases[s.indexOfSelectedItem]
        RuleStore.shared.terminalRules = r
    }
    @objc private func termPatternChanged(_ s: NSTextField) {
        var r = RuleStore.shared.terminalRules; guard s.tag < r.count else { return }
        r[s.tag].pattern = s.stringValue; RuleStore.shared.terminalRules = r
    }
    @objc private func termIMChanged(_ s: NSPopUpButton) {
        var r = RuleStore.shared.terminalRules
        guard s.tag < r.count, let item = s.selectedItem, let sid = item.representedObject as? String else { return }
        r[s.tag].inputSourceID = sid; r[s.tag].inputSourceName = item.title; RuleStore.shared.terminalRules = r
    }
    @objc private func termNoteChanged(_ s: NSTextField) {
        var r = RuleStore.shared.terminalRules; guard s.tag < r.count else { return }
        r[s.tag].note = s.stringValue; RuleStore.shared.terminalRules = r
    }

    // MARK: View Factories

    private func label(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.translatesAutoresizingMaskIntoConstraints = false; l.font = .systemFont(ofSize: 13)
        return l
    }
    private func separator() -> NSBox {
        let b = NSBox(); b.translatesAutoresizingMaskIntoConstraints = false; b.boxType = .separator; return b
    }
    private func smallButton(_ title: String, action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.translatesAutoresizingMaskIntoConstraints = false; b.bezelStyle = .smallSquare
        b.widthAnchor.constraint(equalToConstant: 28).isActive = true
        b.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return b
    }

    private func imPopup(selected sid: String?, includeNone: Bool) -> NSPopUpButton {
        let p = NSPopUpButton(frame: .zero, pullsDown: false)
        p.translatesAutoresizingMaskIntoConstraints = false
        if includeNone { p.addItem(withTitle: "None"); p.lastItem?.representedObject = nil }
        for src in inputSources { p.addItem(withTitle: src.name); p.lastItem?.representedObject = src.id }
        if let sid, let idx = inputSources.firstIndex(where: { $0.id == sid }) {
            p.selectItem(at: idx + (includeNone ? 1 : 0))
        } else if includeNone { p.selectItem(at: 0) }
        return p
    }

    private func scrolledTable(_ tv: inout NSTableView!) -> NSScrollView {
        let sv = NSScrollView(); sv.translatesAutoresizingMaskIntoConstraints = false
        sv.hasVerticalScroller = true; sv.borderType = .bezelBorder
        let rtv = RuleTableView()
        rtv.dragHandleColumnID = "adrag"
        tv = rtv
        tv.usesAlternatingRowBackgroundColors = true; tv.rowHeight = 24
        let colDrag = NSTableColumn(identifier: .init("adrag")); colDrag.title = ""; colDrag.width = 24; colDrag.minWidth = 24; colDrag.maxWidth = 24
        let colOn = NSTableColumn(identifier: .init("on")); colOn.title = ""; colOn.width = 30; colOn.minWidth = 30; colOn.maxWidth = 30
        let colApp = NSTableColumn(identifier: .init("app")); colApp.title = "Application"; colApp.width = 200; colApp.minWidth = 120
        let colIM = NSTableColumn(identifier: .init("im")); colIM.title = "Input Method"; colIM.width = 200; colIM.minWidth = 120
        tv.addTableColumn(colDrag); tv.addTableColumn(colOn); tv.addTableColumn(colApp); tv.addTableColumn(colIM)
        sv.documentView = tv; return sv
    }

    private func recycledCheckbox(_ tv: NSTableView, id: String) -> NSButton {
        let uid = NSUserInterfaceItemIdentifier(id)
        if let v = tv.makeView(withIdentifier: uid, owner: nil) as? NSButton { return v }
        let b = NSButton(checkboxWithTitle: "", target: nil, action: nil); b.identifier = uid; return b
    }

    private func recycledAppCell(_ tv: NSTableView) -> NSTableCellView {
        let uid = NSUserInterfaceItemIdentifier("appcell")
        if let v = tv.makeView(withIdentifier: uid, owner: nil) as? NSTableCellView { return v }
        let v = NSTableCellView(); v.identifier = uid
        let iv = NSImageView(); iv.translatesAutoresizingMaskIntoConstraints = false
        let tf = NSTextField(labelWithString: ""); tf.translatesAutoresizingMaskIntoConstraints = false; tf.lineBreakMode = .byTruncatingTail
        v.addSubview(iv); v.addSubview(tf); v.imageView = iv; v.textField = tf
        NSLayoutConstraint.activate([
            iv.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 2),
            iv.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            iv.widthAnchor.constraint(equalToConstant: 20), iv.heightAnchor.constraint(equalToConstant: 20),
            tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 6),
            tf.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -2),
            tf.centerYAnchor.constraint(equalTo: v.centerYAnchor),
        ])
        return v
    }

    private func recycledIMPopup(_ tv: NSTableView, id: String) -> NSPopUpButton {
        let uid = NSUserInterfaceItemIdentifier(id)
        if let v = tv.makeView(withIdentifier: uid, owner: nil) as? NSPopUpButton { return v }
        let p = NSPopUpButton(frame: .zero, pullsDown: false)
        p.identifier = uid; p.controlSize = .small; p.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        return p
    }

    private func recycledMatchTypePopup(_ tv: NSTableView) -> NSPopUpButton {
        let uid = NSUserInterfaceItemIdentifier("tmtype")
        if let v = tv.makeView(withIdentifier: uid, owner: nil) as? NSPopUpButton { return v }
        let p = NSPopUpButton(frame: .zero, pullsDown: false)
        p.identifier = uid; p.controlSize = .small; p.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        return p
    }

    private func recycledPatternField(_ tv: NSTableView) -> NSTextField {
        let uid = NSUserInterfaceItemIdentifier("tpat")
        if let v = tv.makeView(withIdentifier: uid, owner: nil) as? NSTextField { return v }
        let tf = NSTextField()
        tf.identifier = uid; tf.controlSize = .small; tf.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        tf.placeholderString = "e.g. opencode, nvim"
        tf.lineBreakMode = .byTruncatingTail; tf.cell?.sendsActionOnEndEditing = true
        return tf
    }

    private func recycledNoteField(_ tv: NSTableView) -> NSTextField {
        let uid = NSUserInterfaceItemIdentifier("tnote")
        if let v = tv.makeView(withIdentifier: uid, owner: nil) as? NSTextField { return v }
        let tf = NSTextField()
        tf.identifier = uid; tf.controlSize = .small; tf.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        tf.placeholderString = ""
        tf.lineBreakMode = .byTruncatingTail; tf.cell?.sendsActionOnEndEditing = true
        return tf
    }

    private func configureIMPopup(_ popup: NSPopUpButton, selected sid: String, row: Int) {
        popup.removeAllItems()
        for src in inputSources { popup.addItem(withTitle: src.name); popup.lastItem?.representedObject = src.id }
        if let idx = inputSources.firstIndex(where: { $0.id == sid }) { popup.selectItem(at: idx) }
        popup.tag = row
    }
}
