import AppKit

/// An editable list: one column (words) or two (corrections, snippets). Edits are reported as they end.
@MainActor
final class ListEditor: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private(set) var rows: [[String]]
    private let columnCount: Int
    private let table = NSTableView()
    private let buttons = NSSegmentedControl()
    var onChange: () -> Void = {}

    init(titles: [String], rows: [[String]]) {
        columnCount = titles.count
        self.rows = rows
        super.init(frame: .zero)

        for (index, title) in titles.enumerated() {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c\(index)"))
            column.title = title
            column.isEditable = true
            column.resizingMask = .autoresizingMask
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.allowsMultipleSelection = true

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        buttons.segmentStyle = .smallSquare
        buttons.trackingMode = .momentary
        buttons.segmentCount = 2
        buttons.setImage(NSImage(systemSymbolName: "plus", accessibilityDescription: "Add"), forSegment: 0)
        buttons.setImage(NSImage(systemSymbolName: "minus", accessibilityDescription: "Remove"), forSegment: 1)
        buttons.setWidth(28, forSegment: 0)
        buttons.setWidth(28, forSegment: 1)
        buttons.target = self
        buttons.action = #selector(buttonPressed(_:))

        for view in [scroll, buttons] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            buttons.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: -1),
            buttons.leadingAnchor.constraint(equalTo: leadingAnchor),
            buttons.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Adds a row, fills its first column if given, and starts editing the first empty cell.
    func addRow(first: String = "") {
        window?.makeFirstResponder(table)
        rows.append([first] + Array(repeating: "", count: columnCount - 1))
        table.reloadData()
        let row = rows.count - 1
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
        table.editColumn(first.isEmpty ? 0 : min(1, columnCount - 1), row: row, with: nil, select: true)
    }

    @objc private func buttonPressed(_ sender: NSSegmentedControl) {
        if sender.selectedSegment == 0 {
            addRow()
        } else {
            let selected = table.selectedRowIndexes
            guard !selected.isEmpty else { return }
            table.abortEditing()
            for index in selected.reversed() where index < rows.count { rows.remove(at: index) }
            table.reloadData()
            onChange()
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        guard let column = tableColumn.flatMap({ tableView.tableColumns.firstIndex(of: $0) }), row < rows.count else { return nil }
        return rows[row][column]
    }

    func tableView(_ tableView: NSTableView, setObjectValue object: Any?, for tableColumn: NSTableColumn?, row: Int) {
        guard let column = tableColumn.flatMap({ tableView.tableColumns.firstIndex(of: $0) }), row < rows.count else { return }
        rows[row][column] = (object as? String) ?? ""
        onChange()
    }
}

/// The Dictionary window: words to spell exactly, corrections for words Whisper keeps getting wrong,
/// and snippets. Every edit is saved as it is made. The last dictation is shown so a misheard word
/// can become a correction in two clicks; it is held in memory only and never written to disk.
@MainActor
final class DictionaryWindowController: NSObject, NSWindowDelegate {
    private unowned let owner: ApplicationController
    private let window: NSWindow
    private var hasBeenShown = false
    private let tabs = NSTabView()
    private var words: ListEditor!
    private var corrections: ListEditor!
    private var snippets: ListEditor!
    private let lastDictation = NSTextView()
    private let lastHint = NSTextField(wrappingLabelWithString: "")
    private let correctButton = NSButton(title: "Correct Selected Word", target: nil, action: nil)

    var isVisible: Bool { window.isVisible }

    init(owner: ApplicationController) {
        self.owner = owner
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = "LocalFlow Dictionary"
        window.minSize = NSSize(width: 460, height: 440)
        window.isReleasedWhenClosed = false
        window.delegate = self
        build()
    }

    func show() {
        reload()
        refreshLastDictation()
        if !hasBeenShown { window.center(); hasBeenShown = true }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Shows the Corrections tab with the last dictation ready to pick from.
    func showCorrections() {
        show()
        tabs.selectTabViewItem(at: 1)
    }

    func windowWillClose(_ notification: Notification) {
        window.makeFirstResponder(nil)
        owner.windowClosed(window)
    }

    private func reload() {
        let dictionary = owner.settings.dictionary
        let wordsView = ListEditor(titles: ["Word"], rows: dictionary.words.map { [$0] })
        let correctionsView = ListEditor(titles: ["When LocalFlow writes", "Write instead"],
                                         rows: DictionarySettings.rows(dictionary.replacements).map { [$0.0, $0.1] })
        let snippetsView = ListEditor(titles: ["When I say", "Type"],
                                      rows: DictionarySettings.rows(dictionary.snippets).map { [$0.0, $0.1] })
        for view in [wordsView, correctionsView, snippetsView] { view.onChange = { [weak self] in self?.save() } }
        words = wordsView
        corrections = correctionsView
        snippets = snippetsView
        place(wordsView, in: 0)
        place(correctionsView, in: 1)
        place(snippetsView, in: 2)
    }

    private func save() {
        var dictionary = DictionarySettings()
        dictionary.words = DictionarySettings.words(fromRows: words.rows.map { $0[0] })
        dictionary.replacements = DictionarySettings.pairs(fromRows: corrections.rows.map { ($0[0], $0[1]) })
        dictionary.snippets = DictionarySettings.pairs(fromRows: snippets.rows.map { ($0[0], $0[1]) })
        owner.setDictionary(dictionary)
    }

    func refreshLastDictation() {
        let text = owner.lastDictation ?? ""
        lastDictation.string = text
        lastHint.stringValue = text.isEmpty
            ? "Your next dictation will show here. Select a word LocalFlow got wrong, then click Correct Selected Word."
            : "Select a word LocalFlow got wrong, then click Correct Selected Word and type what it should be."
        correctButton.isEnabled = !text.isEmpty
    }

    @objc private func correctSelection(_ sender: Any?) {
        let range = lastDictation.selectedRange()
        let selection = (lastDictation.string as NSString).substring(with: range)
        guard let heard = Personalization.correctionCandidate(selection) else {
            NSSound.beep()
            lastHint.stringValue = "Select the wrong word in your last dictation first (double-click it), then click Correct Selected Word."
            return
        }
        // The new row lives on the Corrections tab: from any other tab it was added out of sight,
        // and with no table on screen to edit, nothing seemed to happen (2026-11-17).
        tabs.selectTabViewItem(at: 1)
        corrections.addRow(first: heard)
        lastHint.stringValue = "Type what \"\(heard)\" should be, then press Return."
    }

    // MARK: Layout

    private var holders: [NSView] = []

    private func place(_ editor: NSView, in index: Int) {
        let holder = holders[index]
        holder.subviews.filter { $0 is ListEditor }.forEach { $0.removeFromSuperview() }
        editor.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(editor)
        let top = holder.subviews.first { $0 is NSTextField } ?? holder
        NSLayoutConstraint.activate([
            editor.topAnchor.constraint(equalTo: top === holder ? holder.topAnchor : top.bottomAnchor, constant: 10),
            editor.leadingAnchor.constraint(equalTo: holder.leadingAnchor),
            editor.trailingAnchor.constraint(equalTo: holder.trailingAnchor),
            editor.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
        ])
    }

    private func tab(_ title: String, note: String) -> NSView {
        let holder = NSView()
        let label = NSTextField(wrappingLabelWithString: note)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: holder.topAnchor),
            label.leadingAnchor.constraint(equalTo: holder.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: holder.trailingAnchor),
        ])
        let item = NSTabViewItem(identifier: title)
        item.label = title
        let padded = NSView()
        holder.translatesAutoresizingMaskIntoConstraints = false
        padded.addSubview(holder)
        NSLayoutConstraint.activate([
            holder.topAnchor.constraint(equalTo: padded.topAnchor, constant: 12),
            holder.leadingAnchor.constraint(equalTo: padded.leadingAnchor, constant: 14),
            holder.trailingAnchor.constraint(equalTo: padded.trailingAnchor, constant: -14),
            holder.bottomAnchor.constraint(equalTo: padded.bottomAnchor, constant: -12),
        ])
        item.view = padded
        tabs.addTabViewItem(item)
        holders.append(holder)
        return holder
    }

    private func build() {
        _ = tab("Words", note: "Names, products and jargon to spell exactly as written. LocalFlow listens for them and keeps their spelling.")
        _ = tab("Corrections", note: "When LocalFlow keeps writing a word wrong, correct it here. It is replaced whole-word, in any case, in every dictation.")
        _ = tab("Snippets", note: "Say the phrase and LocalFlow types the text instead, such as \"my calendar link\" for a URL.")

        let content = NSView()
        tabs.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(tabs)

        let lastTitle = NSTextField(labelWithString: "Last dictation")
        lastTitle.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        lastHint.textColor = .secondaryLabelColor
        lastDictation.isEditable = false
        lastDictation.isSelectable = true
        lastDictation.font = .systemFont(ofSize: NSFont.systemFontSize)
        lastDictation.textContainerInset = NSSize(width: 4, height: 4)
        let lastScroll = NSScrollView()
        lastScroll.documentView = lastDictation
        lastScroll.hasVerticalScroller = true
        lastScroll.borderType = .bezelBorder
        lastDictation.autoresizingMask = [.width]
        correctButton.target = self
        correctButton.action = #selector(correctSelection(_:))
        correctButton.bezelStyle = .rounded

        for view in [lastTitle, lastHint, lastScroll, correctButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            tabs.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            tabs.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),

            lastTitle.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 14),
            lastTitle.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            lastHint.topAnchor.constraint(equalTo: lastTitle.bottomAnchor, constant: 4),
            lastHint.leadingAnchor.constraint(equalTo: lastTitle.leadingAnchor),
            lastHint.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            lastScroll.topAnchor.constraint(equalTo: lastHint.bottomAnchor, constant: 8),
            lastScroll.leadingAnchor.constraint(equalTo: lastTitle.leadingAnchor),
            lastScroll.trailingAnchor.constraint(equalTo: lastHint.trailingAnchor),
            lastScroll.heightAnchor.constraint(equalToConstant: 64),
            correctButton.topAnchor.constraint(equalTo: lastScroll.bottomAnchor, constant: 10),
            correctButton.trailingAnchor.constraint(equalTo: lastHint.trailingAnchor),
            correctButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])
        window.contentView = content
    }
}
