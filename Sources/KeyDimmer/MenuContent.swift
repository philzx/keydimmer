import KeyDimmerCore
import SwiftUI

enum Brand {
    static let ember = Color(red: 1.0, green: 0.55, blue: 0.2)
    static let tagline = "Below the bottom step."
}

struct MenuContent: View {
    @Bindable var model: AppModel
    @FocusState private var sliderFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let reason = model.unsupportedReason {
                Label(reason, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                LadderSlider(ladder: model.ladder, index: model.levelIndex) { model.select(index: $0) }
                    .focusable()
                    .focusEffectDisabled()
                    .focused($sliderFocused)
                    .onKeyPress(keys: [.leftArrow, .downArrow]) { _ in model.step(by: -1); return .handled }
                    .onKeyPress(keys: [.rightArrow, .upArrow]) { _ in model.step(by: 1); return .handled }
                status
            }
            Divider()
            settings
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 320)
        .onAppear { sliderFocused = true }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("KeyDimmer").font(.headline)
                Text(Brand.tagline).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
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
            settingRow("Launch at login", isOn: Binding(
                get: { _ = model.launchAtLoginRevision; return model.launchAtLogin },
                set: { model.launchAtLogin = $0 }
            ))
            settingRow("Global shortcuts", detail: "⌃⌥↑ ⌃⌥↓", isOn: $model.hotkeysEnabled)
            settingRow("Turn off with macOS inactivity timer", isOn: $model.followsInactivity)
        }
    }

    private func settingRow(_ title: String, detail: String? = nil, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(title)
            if let detail {
                Text(detail).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
    }

    private var footer: some View {
        HStack {
            Text("v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
            Button("Quit KeyDimmer") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}

/// One continuous control over Off, the embers and the macOS steps, with the macOS floor marked.
struct LadderSlider: View {
    let ladder: Ladder
    let index: Int
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
                HStack(spacing: 0) {
                    Text("Off").frame(width: 30, alignment: .leading)
                    Text("Embers").foregroundStyle(Brand.ember)
                        .frame(width: max(proxy.size.width * fraction - 30, 0), alignment: .center)
                    Text("macOS").frame(maxWidth: .infinity, alignment: .center)
                }
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
            }
            .frame(height: 12)
        }
        .accessibilityElement()
        .accessibilityLabel("Keyboard brightness")
        .accessibilityValue(ladder.level(at: index).title)
        .accessibilityAdjustableAction { direction in
            onChange(min(max(index + (direction == .increment ? 1 : -1), 0), ladder.count - 1))
        }
    }

    private var firstSystemIndex: Int {
        ladder.levels.firstIndex { if case .system = $0 { return true } else { return false } } ?? ladder.count
    }

    private var thumbColor: Color {
        ladder.level(at: index).isEmber ? Brand.ember : .accentColor
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
