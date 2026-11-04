import AppKit
import SwiftUI
import TakeListCore

/// Native AppKit table: fast with thousands of takes, variable row heights, reliable scroll-to-row.
struct TakeTableView: NSViewRepresentable {
    let sheet: TakeSheet
    let rows: [DisplayRow]
    let version: Int
    let settings: ScanSettings
    let focus: Focus?
    let issueRows: Set<UUID>
    let onEdit: (UUID) -> Void
    let onCommit: (UUID, Int, String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        let table = NSTableView()
        table.style = .plain
        table.usesAlternatingRowBackgroundColors = false
        table.gridStyleMask = [.solidHorizontalGridLineMask, .solidVerticalGridLineMask]
        table.gridColor = NSColor.separatorColor.withAlphaComponent(0.4)
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = false
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.intercellSpacing = NSSize(width: 6, height: 2)
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.doubleClicked(_:))
        let menu = NSMenu()
        menu.addItem(withTitle: "Zelle bearbeiten", action: #selector(Coordinator.menuEditCell(_:)), keyEquivalent: "").target = context.coordinator
        menu.addItem(withTitle: "Ganze Zeile bearbeiten …", action: #selector(Coordinator.menuEditRow(_:)), keyEquivalent: "").target = context.coordinator
        table.menu = menu
        scroll.documentView = table
        context.coordinator.table = table
        context.coordinator.scrollView = scroll
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.columnResized(_:)),
                                               name: NSTableView.columnDidResizeNotification, object: table)
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.update(self)
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
        weak var table: NSTableView?
        weak var scrollView: NSScrollView?
        var rows: [DisplayRow] = []
        var sheet: TakeSheet?
        var settings = ScanSettings()
        var focus: Focus?
        var issueRows: Set<UUID> = []
        var onEdit: ((UUID) -> Void)?
        var onCommit: ((UUID, Int, String) -> Void)?
        private var editing: (rowID: UUID, col: Int, original: String, field: NSTextField)?
        private var editCancelled = false
        private var structureKey = ""
        private var version = -1
        private var lastScrollToken: UUID?
        private var heights: [Int: CGFloat] = [:]
        private var resizePending = false
        private var tc = Timecode(fps: 25)

        static let font = NSFont.systemFont(ofSize: 12)
        static let monoFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        static let smallFont = NSFont.systemFont(ofSize: 11)

        func update(_ v: TakeTableView) {
            onEdit = v.onEdit
            onCommit = v.onCommit
            guard let table else { return }
            // Never reload under an active cell editor; the commit triggers the next update anyway.
            if editing != nil { return }
            let key = "\(v.sheet.id)|\(v.sheet.displayColumns)|\(v.sheet.headers.joined(separator: "\u{1}"))|\(v.sheet.mapping)"
            var reload = false
            if key != structureKey {
                structureKey = key
                rebuildColumns(v.sheet, table)
                reload = true
            }
            if v.version != version || v.settings != settings || v.issueRows != issueRows || sheet?.id != v.sheet.id || reload {
                version = v.version
                sheet = v.sheet
                settings = v.settings
                tc = Timecode(fps: v.settings.fps)
                issueRows = v.issueRows
                rows = v.rows
                focus = v.focus
                heights.removeAll()
                table.reloadData()
            } else if v.focus != focus {
                focus = v.focus
                refreshRowViews()
            }
            if let f = v.focus, f.token != lastScrollToken {
                lastScrollToken = f.token
                DispatchQueue.main.async { [weak self] in self?.scroll(to: f.scrollTo) }
            }
        }

        // MARK: Columns

        private func rebuildColumns(_ sheet: TakeSheet, _ table: NSTableView) {
            for c in table.tableColumns { table.removeTableColumn(c) }
            func add(_ id: String, _ title: String, _ width: CGFloat, tip: String? = nil) {
                let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
                col.title = title
                col.width = width
                col.minWidth = 30
                col.headerToolTip = tip
                table.addTableColumn(col)
            }
            add("num", "Zeile", 54, tip: "Zeilennummer in der Excel-Tabelle")
            let m = sheet.mapping
            let headers = sheet.headers
            for i in sheet.displayColumns {
                let h = headers[i]
                let label = m.label(for: i)
                let title = label.map { "\(h)  ‹\($0)›" } ?? h
                let width: CGFloat
                if i == m.text { width = 460 } else if i == m.role { width = 130 } else if i == m.tcIn || i == m.tcOut { width = m.combinedTimecode ? 190 : 100 } else { width = 110 }
                add("c\(i)", title, width, tip: "Spalte \(columnLetters(i))")
            }
            add("words", "Wörter", 56)
            add("dur", "Dauer", 60)
        }

        // MARK: Data

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        private func content(_ id: String, _ d: DisplayRow) -> (String, NSFont, NSColor) {
            guard let sheet else { return ("", Self.font, .labelColor) }
            let m = sheet.mapping
            let row = d.row
            switch id {
            case "num":
                let mark = issueRows.contains(row.id) ? " ⚠︎" : ""
                return (d.kind == .added ? "↳ neu" : row.label + mark, Self.smallFont, issueRows.contains(row.id) ? .systemOrange : .secondaryLabelColor)
            case "words":
                guard sheet.isTake(row) else { return ("", Self.monoFont, .labelColor) }
                let w = TextSplitter.wordCount(row.text(m.text), ignoreDirections: settings.ignoreDirections)
                let over = settings.maxWordsEnabled && w > settings.maxWords
                return ("\(w)", Self.monoFont, over ? .systemRed : .secondaryLabelColor)
            case "dur":
                let info = Scanner.takeInfo(row, m, tc)
                guard let a = info.inF, let b = info.outF else { return ("", Self.monoFont, .labelColor) }
                let over = settings.maxDurationEnabled && tc.seconds(b - a) > settings.maxDurationSeconds
                return (String(format: "%.1f s", tc.seconds(b - a)), Self.monoFont, over || b <= a ? .systemRed : .secondaryLabelColor)
            default:
                let col = Int(id.dropFirst()) ?? 0
                let cell = row.cell(col)
                if (col == m.tcIn || col == m.tcOut), !m.combinedTimecode, case .number = cell.value, let p = tc.parse(cell) {
                    return (tc.string(p.frames, style: .frames(separator: ":")), Self.monoFont, .labelColor)
                }
                let isTC = col == m.tcIn || col == m.tcOut
                return (cell.text, isTC ? Self.monoFont : Self.font, .labelColor)
            }
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, rows.indices.contains(row) else { return nil }
            let id = tableColumn.identifier
            let field: NSTextField
            if let f = tableView.makeView(withIdentifier: id, owner: self) as? NSTextField {
                field = f
            } else {
                field = NSTextField(wrappingLabelWithString: "")
                field.identifier = id
                field.isSelectable = false
                field.lineBreakMode = .byWordWrapping
                field.cell?.wraps = true
                field.cell?.truncatesLastVisibleLine = false
                if id.rawValue == "words" || id.rawValue == "dur" { field.alignment = .right }
            }
            let d = rows[row]
            let (text, font, color) = content(id.rawValue, d)
            var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: d.kind == .removed ? NSColor.secondaryLabelColor : color]
            if d.kind == .removed {
                attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                attrs[.strikethroughColor] = NSColor.systemRed
            }
            field.attributedStringValue = NSAttributedString(string: text, attributes: attrs)
            return field
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let v = (tableView.makeView(withIdentifier: TakeRowView.id, owner: self) as? TakeRowView) ?? TakeRowView()
            v.identifier = TakeRowView.id
            configure(v, row)
            return v
        }

        private func configure(_ v: TakeRowView, _ row: Int) {
            guard rows.indices.contains(row) else { return }
            let d = rows[row]
            v.kind = d.kind
            var hl = false
            if let f = focus {
                hl = f.rowIDs.contains(d.row.id) || (f.proposalID != nil && d.proposalID == f.proposalID)
            }
            v.highlighted = hl
            v.needsDisplay = true
        }

        private func refreshRowViews() {
            table?.enumerateAvailableRowViews { rv, idx in
                if let rv = rv as? TakeRowView { self.configure(rv, idx) }
            }
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            if let h = heights[row] { return h }
            var h: CGFloat = 18
            if rows.indices.contains(row) {
                for col in tableView.tableColumns {
                    let (text, font, _) = content(col.identifier.rawValue, rows[row])
                    guard text.count > 8 || text.contains("\n") else { continue }
                    let rect = (text as NSString).boundingRect(with: NSSize(width: max(10, col.width - 6), height: .greatestFiniteMagnitude),
                                                               options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font])
                    h = max(h, ceil(rect.height) + 4)
                }
            }
            heights[row] = h
            return h
        }

        @objc func columnResized(_ note: Notification) {
            guard !resizePending else { return }
            resizePending = true
            DispatchQueue.main.async { [weak self] in
                guard let self, let table = self.table else { return }
                self.resizePending = false
                self.heights.removeAll()
                table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<self.rows.count))
            }
        }

        @objc func doubleClicked(_ sender: Any?) {
            guard let table, rows.indices.contains(table.clickedRow) else { return }
            let d = rows[table.clickedRow]
            guard d.kind == .normal else { NSSound.beep(); return }
            if !beginEditing(row: table.clickedRow, column: table.clickedColumn) { onEdit?(d.row.id) }
        }

        @objc func menuEditCell(_ sender: Any?) {
            guard let table, rows.indices.contains(table.clickedRow), rows[table.clickedRow].kind == .normal else { NSSound.beep(); return }
            if !beginEditing(row: table.clickedRow, column: table.clickedColumn) { onEdit?(rows[table.clickedRow].row.id) }
        }

        @objc func menuEditRow(_ sender: Any?) {
            guard let table, rows.indices.contains(table.clickedRow), rows[table.clickedRow].kind == .normal else { NSSound.beep(); return }
            onEdit?(rows[table.clickedRow].row.id)
        }

        /// Starts inline editing of a sheet cell. Returns false for non-editable columns (row number, words, duration).
        private func beginEditing(row: Int, column: Int) -> Bool {
            guard let table, column >= 0, column < table.tableColumns.count else { return false }
            let id = table.tableColumns[column].identifier.rawValue
            guard id.hasPrefix("c"), let col = Int(id.dropFirst()),
                  let field = table.view(atColumn: column, row: row, makeIfNecessary: true) as? NSTextField else { return false }
            let (text, font, _) = content(id, rows[row])
            editing = (rows[row].row.id, col, text, field)
            editCancelled = false
            field.isEditable = true
            field.isSelectable = true
            field.delegate = self
            field.font = font
            field.textColor = .labelColor
            field.stringValue = text
            field.drawsBackground = true
            field.backgroundColor = .textBackgroundColor
            table.editColumn(column, row: row, with: nil, select: true)
            if field.currentEditor() == nil { table.window?.makeFirstResponder(field) }
            return true
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                editCancelled = true
                table?.window?.makeFirstResponder(table)
                return true
            }
            return false
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            guard let e = editing else { return }
            let newText = e.field.stringValue
            e.field.isEditable = false
            e.field.isSelectable = false
            e.field.drawsBackground = false
            e.field.delegate = nil
            editing = nil
            if !editCancelled, newText != e.original {
                onCommit?(e.rowID, e.col, newText)
            } else {
                table?.reloadData()
            }
        }

        private func scroll(to rowID: UUID) {
            guard let table, let scrollView, let idx = rows.firstIndex(where: { $0.row.id == rowID }) else { return }
            table.scrollRowToVisible(idx)
            let rect = table.rect(ofRow: idx)
            let clip = scrollView.contentView
            let inset = clip.contentInsets.top
            let visibleHeight = clip.bounds.height - inset
            var y = rect.minY - max(0, (visibleHeight - rect.height) / 2) - inset
            let maxY = max(-inset, table.bounds.height - clip.bounds.height)
            y = min(max(-inset, y), maxY)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                clip.animator().setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: y))
            } completionHandler: {
                scrollView.reflectScrolledClipView(clip)
            }
            refreshRowViews()
        }
    }
}

final class TakeRowView: NSTableRowView {
    static let id = NSUserInterfaceItemIdentifier("TakeRow")
    var kind: DisplayKind = .normal
    var highlighted = false

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        switch kind {
        case .removed: NSColor.systemRed.withAlphaComponent(0.13).setFill(); bounds.fill()
        case .added: NSColor.systemGreen.withAlphaComponent(0.16).setFill(); bounds.fill()
        case .normal: break
        }
        if highlighted {
            NSColor.systemYellow.withAlphaComponent(kind == .normal ? 0.30 : 0.18).setFill()
            bounds.fill(using: .sourceOver)
            NSColor.systemOrange.setFill()
            NSRect(x: 0, y: 0, width: 4, height: bounds.height).fill()
        }
    }
}
