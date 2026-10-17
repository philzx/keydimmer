import KeyDimmerCore
import SwiftUI

enum Brand {
    static let ember = Color(red: 1.0, green: 0.55, blue: 0.2)
    static let shade = Color(red: 0.45, green: 0.5, blue: 0.95)
    static let tagline = "Below the bottom step."
}

struct MenuContent: View {
    @Bindable var model: AppModel
    @FocusState private var focusedSlider: Light?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let reason = model.unsupportedReason {
                Label(reason, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if model.hasKeyboard {
                LadderSlider(ladder: model.ladder, index: model.levelIndex, name: "Keyboard brightness") {
                    model.select(index: $0)
                }
                .focusable()
                .focusEffectDisabled()
                .focused($focusedSlider, equals: .keyboard)
                .onKeyPress(keys: [.leftArrow, .downArrow]) { _ in model.step(by: -1); return .handled }
                .onKeyPress(keys: [.rightArrow, .upArrow]) { _ in model.step(by: 1); return .handled }
                status
            }
            if let ladder = model.displayLadder, let level = model.displayLevel {
                if model.hasKeyboard { Divider() }
                displaySection(ladder: ladder, level: level)
            }
            Divider()
            settings
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 320)
        .onAppear {
            focusedSlider = model.hasKeyboard ? .keyboard : .display
            model.refreshLaunchAtLogin()
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("KeyDimmer").font(.headline)
                Text(Brand.tagline).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if model.hasKeyboard { keyboardLevel }
        }
    }

    private var keyboardLevel: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(model.level.title)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .foregroundStyle(model.level.isEmber ? Brand.ember : .primary)
                .contentTransition(.numericText())
            if let duty = model.dutyDescription {
                Text("duty \(duty)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }

    private func displaySection(ladder: Ladder, level: Level) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Display").font(.subheadline.weight(.medium))
                Spacer()
                Text(level.title)
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .foregroundStyle(level.isShade ? Brand.shade : .primary)
                    .contentTransition(.numericText())
            }
            LadderSlider(ladder: ladder, index: model.displayLevelIndex, name: "Display brightness") {
                model.selectDisplay(index: $0)
            }
            .focusable()
            .focusEffectDisabled()
            .focused($focusedSlider, equals: .display)
            .onKeyPress(keys: [.leftArrow, .downArrow]) { _ in model.stepDisplay(by: -1); return .handled }
            .onKeyPress(keys: [.rightArrow, .upArrow]) { _ in model.stepDisplay(by: 1); return .handled }
            if let reason = model.shadesUnavailableReason {
                Label("Shades are off while \(reason)", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        let (symbol, text, color): (String, String, Color) = {
            if model.isCalibrating { return ("scope", "Measuring this Mac's floor…", .secondary) }
            switch model.pause {
            case .sleeping?: return ("moon.zzz", "Paused while asleep", .secondary)
            case .lidClosed?: return ("laptopcomputer", "Paused while the lid is closed", .secondary)
            case .inactive?: return ("hand.raised", "Off after inactivity — touch a key to resume", .secondary)
            case nil: break
            }
            guard model.level.isEmber else { return ("checkmark.circle", "macOS is in control", .secondary) }
            let stability = model.stats.stability * 100
            return ("waveform.path", String(format: "Holding steady · %.1f%% on target", stability), Brand.ember)
        }()
        Label(text, systemImage: symbol)
            .font(.caption)
            .foregroundStyle(color)
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 8) {
            settingRow("Launch at login", isOn: $model.launchAtLogin)
            if model.launchAtLoginNeedsApproval {
                notice("Waiting for your approval in System Settings.", action: "Open Login Items") {
                    model.openLoginItemsSettings()
                }
            } else if let error = model.launchAtLoginError {
                notice("Couldn't change: \(error)")
            }
            HStack {
                Text("Global shortcuts")
                Picker("Shortcut modifiers", selection: $model.hotkeyModifiers) {
                    ForEach(HotKeys.Modifiers.allCases) { Text(shortcutsTitle($0)).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .controlSize(.small)
                .disabled(!model.hotkeysEnabled)
                Spacer()
                switchToggle("Global shortcuts", isOn: $model.hotkeysEnabled)
            }
            if model.hotkeysEnabled, let taken = takenShortcuts {
                notice("\(taken) taken by another app. Choose other keys.")
            }
            if model.hasKeyboard {
                settingRow("Turn off with macOS inactivity timer", isOn: $model.followsInactivity)
                HStack {
                    Text("macOS floor")
                    Text(model.calibrationFailed ? "measuring failed" : model.floorDescription ?? "not measured")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Recalibrate") { model.recalibrate() }
                        .buttonStyle(.link)
                        .font(.caption)
                        .disabled(model.isCalibrating)
                        .help("Measure the dimmest level macOS allows on this Mac again")
                }
            }
            HStack {
                Text("Check for updates")
                if let result = updateCheckDescription {
                    Text(result).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Check Now") { model.updates.checkNow() }
                    .buttonStyle(.link)
                    .font(.caption)
                    .disabled(!model.updates.canCheck || model.updates.isChecking || model.updates.isInstalling)
                    .help("Ask GitHub for a newer release now")
                switchToggle("Check for updates", isOn: Binding(
                    get: { model.updates.isEnabled },
                    set: { model.updates.isEnabled = $0 }
                ))
            }
        }
    }

    /// The shortcuts macOS refused, e.g. "⌃⌥↑/↓ are" or "⌃⌥↑/↓ and ⌃⌥⇧↑/↓ are".
    private var takenShortcuts: String? {
        let symbols = model.hotkeyModifiers.symbols
        let keys = [Light.keyboard, .display].filter(model.unavailableShortcuts.contains).map {
            $0 == .display ? "\(symbols)⇧↑/↓" : "\(symbols)↑/↓"
        }
        return keys.isEmpty ? nil : keys.joined(separator: " and ") + " are"
    }

    private var updateCheckDescription: String? {
        if model.updates.isChecking { return "checking…" }
        switch model.updates.checkResult {
        case .upToDate?: return "up to date"
        case .failed?: return "check failed"
        case nil: return nil
        }
    }

    /// The keyboard's arrows, plus a reminder of the display's ⇧; only for the lights this Mac has.
    private func shortcutsTitle(_ modifiers: HotKeys.Modifiers) -> String {
        let symbols = modifiers.symbols
        switch (model.hasKeyboard, model.hasDisplay) {
        case (true, true): return "\(symbols)↑ \(symbols)↓ (+⇧ display)"
        case (false, true): return "\(symbols)⇧↑ \(symbols)⇧↓"
        default: return "\(symbols)↑ \(symbols)↓"
        }
    }

    private func settingRow(_ title: String, detail: String? = nil, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(title)
            if let detail {
                Text(detail).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Spacer()
            switchToggle(title, isOn: isOn)
        }
    }

    private func switchToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(title, isOn: isOn)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
    }

    private func notice(_ text: String, action: String? = nil, perform: @escaping () -> Void = {}) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Label(text, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            if let action {
                Spacer(minLength: 4)
                Button(action, action: perform).buttonStyle(.link)
            }
        }
        .font(.caption)
    }

    private var footer: some View {
        HStack {
            if model.updates.isInstalling {
                Label("Updating…", systemImage: "arrow.down.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let release = model.updates.available {
                Button { model.updates.install() } label: {
                    Label("Update to v\(release.version)", systemImage: "arrow.down.circle.fill")
                        .font(.caption)
                }
                .buttonStyle(.link)
            } else {
                Text("v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button("Quit KeyDimmer") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}

/// One continuous control over a light's ladder (Off and the embers, or the shades, then the
/// macOS steps), with the macOS floor marked.
struct LadderSlider: View {
    let ladder: Ladder
    let index: Int
    let name: String
    let onChange: (Int) -> Void

    private let thumb: CGFloat = 18

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { proxy in
                let width = proxy.size.width - thumb
                let step = width / CGFloat(max(ladder.count - 1, 1))
                ZStack(alignment: .leading) {
                    track(step: step)
                        .padding(.horizontal, thumb / 2)
                    floorMarker
                        .offset(x: thumb / 2 + step * (CGFloat(firstSystemIndex) - 0.5) - 0.5)
                    Circle()
                        .fill(.background)
                        .overlay(Circle().strokeBorder(thumbColor, lineWidth: 2))
                        .shadow(color: thumbColor.opacity(0.45), radius: 4)
                        .frame(width: thumb, height: thumb)
                        .offset(x: step * CGFloat(index))
                        .animation(.snappy(duration: 0.18), value: index)
                }
                .frame(height: thumb)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    let position = Int(((value.location.x - thumb / 2) / step).rounded())
                    let clamped = min(max(position, 0), ladder.count - 1)
                    if clamped != index { onChange(clamped) }
                })
            }
            .frame(height: thumb)

            GeometryReader { proxy in
                let fraction = CGFloat(firstSystemIndex) / CGFloat(max(ladder.count - 1, 1))
                let offWidth: CGFloat = hasOff ? 30 : 0
                HStack(spacing: 0) {
                    if hasOff { Text("Off").frame(width: offWidth, alignment: .leading) }
                    Text(belowFloorName).foregroundStyle(belowFloorColor)
                        .frame(width: max(proxy.size.width * fraction - offWidth, 0), alignment: .center)
                    Text("macOS").frame(maxWidth: .infinity, alignment: .center)
                }
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
            }
            .frame(height: 12)
        }
        .accessibilityElement()
        .accessibilityLabel(name)
        .accessibilityValue(ladder.level(at: index).title)
        .accessibilityAdjustableAction { direction in
            onChange(min(max(index + (direction == .increment ? 1 : -1), 0), ladder.count - 1))
        }
    }

    private var firstSystemIndex: Int {
        ladder.levels.firstIndex { if case .system = $0 { return true } else { return false } } ?? ladder.count
    }

    private var hasOff: Bool { ladder.levels.first == .off }

    private var hasShades: Bool { ladder.levels.contains(where: \.isShade) }

    private var belowFloorName: String { hasShades ? "Shades" : "Embers" }

    private var belowFloorColor: Color { hasShades ? Brand.shade : Brand.ember }

    private var thumbColor: Color {
        let level = ladder.level(at: index)
        if level.isEmber { return Brand.ember }
        if level.isShade { return Brand.shade }
        return .accentColor
    }

    private func track(step: CGFloat) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(ladder.levels.enumerated()), id: \.offset) { offset, level in
                Capsule()
                    .fill(color(for: level, active: offset <= index))
                    .frame(width: max(step - 2, 2), height: 6)
                    .frame(width: offset == 0 ? 0 : step)
            }
        }
        .frame(height: 6)
    }

    private func color(for level: Level, active: Bool) -> Color {
        switch level {
        case .off:
            return .clear
        case let .ember(i, _):
            let embers = ladder.levels.filter(\.isEmber).count
            let t = Double(i) / Double(max(embers, 1))
            return active ? Brand.ember.opacity(0.35 + 0.65 * t) : Brand.ember.opacity(0.12 + 0.1 * t)
        case let .shade(i, _):
            let shades = ladder.levels.filter(\.isShade).count
            let t = Double(i) / Double(max(shades, 1))
            return active ? Brand.shade.opacity(0.35 + 0.65 * t) : Brand.shade.opacity(0.12 + 0.1 * t)
        case let .system(step):
            let t = Double(step) / Double(Ladder.systemSteps)
            return active ? Color.accentColor.opacity(0.45 + 0.55 * t) : Color.secondary.opacity(0.18)
        }
    }

    private var floorMarker: some View {
        Rectangle()
            .fill(.secondary.opacity(0.6))
            .frame(width: 1, height: thumb)
            .help("macOS minimum")
    }
}
