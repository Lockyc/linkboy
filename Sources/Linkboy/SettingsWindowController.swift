import AppKit
import LinkboyCore

/// The app's one live copy of `Preferences`: every change is saved and handed to each observer.
final class PreferencesModel {
    private(set) var value = Preferences.load()
    private var observers: [(Preferences) -> Void] = []

    func observe(_ f: @escaping (Preferences) -> Void) { observers.append(f) }

    func update(_ change: (inout Preferences) -> Void) {
        var next = value
        change(&next)
        guard next != value else { return }
        value = next
        value.save()
        observers.forEach { $0(value) }
    }
}

final class SettingsWindowController: NSWindowController {
    private let model: PreferencesModel
    private let layout = NSPopUpButton()
    private let listWidth = NSSlider(value: 320, minValue: 200, maxValue: 600, target: nil, action: nil)
    private let listWidthLabel = NSTextField(labelWithString: "")
    private let fontSize = NSStepper()
    private let fontSizeLabel = NSTextField(labelWithString: "")
    private let density = NSPopUpButton()

    init(model: PreferencesModel) {
        self.model = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 180),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Settings"
        window.animationBehavior = .none
        super.init(window: window)

        layout.addItems(withTitles: ["Single pane", "Side by side"])
        density.addItems(withTitles: ["Compact", "Regular"])
        fontSize.minValue = 10
        fontSize.maxValue = 20
        fontSize.increment = 1
        listWidth.isContinuous = true
        for control in [layout, listWidth, fontSize, density] as [NSControl] {
            control.target = self
            control.action = #selector(changed(_:))
        }
        listWidth.widthAnchor.constraint(equalToConstant: 200).isActive = true

        func row(_ views: NSView...) -> NSStackView {
            let s = NSStackView(views: views)
            s.orientation = .horizontal
            s.spacing = 8
            return s
        }
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Layout"), layout],
            [NSTextField(labelWithString: "List width"), row(listWidth, listWidthLabel)],
            [NSTextField(labelWithString: "List font size"), row(fontSize, fontSizeLabel)],
            [NSTextField(labelWithString: "List density"), density],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.rowSpacing = 12
        grid.columnSpacing = 8
        grid.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            grid.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
        ])
        window.contentView = content
        model.observe { [weak self] in self?.show($0) }
        show(model.value)
        listWidthLabel.widthAnchor.constraint(equalToConstant: 60).isActive = true
        window.setContentSize(content.fittingSize)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func present() {
        window?.center()
        showWindow(nil)
    }

    private func show(_ p: Preferences) {
        layout.selectItem(at: p.layout == .single ? 0 : 1)
        listWidth.doubleValue = p.listWidth
        listWidthLabel.stringValue = "\(Int(p.listWidth.rounded())) pt"
        fontSize.doubleValue = p.listFontSize
        fontSizeLabel.stringValue = "\(Int(p.listFontSize)) pt"
        density.selectItem(at: p.density == .compact ? 0 : 1)
    }

    @objc private func changed(_ sender: NSControl) {
        model.update { p in
            if sender === layout { p.layout = layout.indexOfSelectedItem == 0 ? .single : .sideBySide }
            if sender === listWidth { p.listWidth = listWidth.doubleValue.rounded() }
            if sender === fontSize { p.listFontSize = fontSize.doubleValue }
            if sender === density { p.density = density.indexOfSelectedItem == 0 ? .compact : .regular }
        }
    }
}
