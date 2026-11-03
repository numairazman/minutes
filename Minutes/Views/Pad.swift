import SwiftUI
import UIKit

// The app draws its own menus, confirmations, renames and notices: a page torn off the pad slides
// up over everything. No system action sheets, alerts, context menus or sheets — those carry the
// stock look the rest of the app avoids. (The share sheet and the Files picker stay: they're iOS's
// own doors to OneDrive and Files, and can't be replaced.)

@MainActor
@Observable
final class Pad {
    struct Card: Identifiable {
        let id = UUID()
        let content: AnyView
    }

    private(set) var card: Card?

    func show<Content: View>(@ViewBuilder _ content: () -> Content) {
        card = Card(content: AnyView(content()))
    }

    func dismiss() {
        card = nil
    }
}

private struct PageMetricsKey: EnvironmentKey {
    static let defaultValue = PageMetrics(marginWidth: 62)
}

extension EnvironmentValues {
    var pageMetrics: PageMetrics {
        get { self[PageMetricsKey.self] }
        set { self[PageMetricsKey.self] = newValue }
    }
}

/// Lays a screen out with its own `Pad` host on top, so cards cover the top bar too.
struct PadHost: View {
    let pad: Pad
    @ScaledMetric(relativeTo: .footnote) private var marginWidth: CGFloat = 62
    @State private var drag: CGFloat = 0

    var body: some View {
        let metrics = PageMetrics(marginWidth: marginWidth)
        ZStack(alignment: .bottom) {
            if let card = pad.card {
                Color.black.opacity(0.42)
                    .ignoresSafeArea()
                    .onTapGesture { pad.dismiss() }
                    .transition(.opacity)
                    .accessibilityLabel("Close")
                    .accessibilityAddTraits(.isButton)

                card.content
                    .environment(\.pageMetrics, metrics)
                    .environment(pad)
                    .padding(.top, 26)
                    .padding(.bottom, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(alignment: .top) {
                        UnevenRoundedRectangle(topLeadingRadius: 26, topTrailingRadius: 26, style: .continuous)
                            .fill(Color.paper)
                            .overlay(alignment: .topLeading) {
                                Rectangle()
                                    .fill(Color.margin.opacity(0.55))
                                    .frame(width: 1)
                                    .offset(x: metrics.ruleX)
                                    .padding(.top, 12)
                            }
                            .ignoresSafeArea(edges: .bottom)
                    }
                    .offset(y: max(0, drag))
                    .gesture(
                        DragGesture()
                            .onChanged { drag = $0.translation.height }
                            .onEnded { value in
                                if value.translation.height > 90 { pad.dismiss() }
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { drag = 0 }
                            }
                    )
                    .transition(.move(edge: .bottom))
                    .id(card.id)
                    .accessibilityAddTraits(.isModal)
            }
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.9), value: pad.card?.id)
    }
}

// MARK: - Card parts

/// The heading of a card: what this is, and (optionally) what will happen.
struct PadHeading: View {
    let title: String
    var message: String?
    @Environment(\.pageMetrics) private var metrics

    var body: some View {
        MarginRow(metrics: metrics) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(Typeface.page(.title2, .semibold))
                    .foregroundStyle(Color.ink)
                    .accessibilityAddTraits(.isHeader)
                if let message {
                    Text(message)
                        .font(Typeface.note(.subheadline))
                        .foregroundStyle(Color.pencil)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.bottom, 14)
    }
}

/// One line of a menu card: icon in the margin, words on the page, a ruled line under it.
struct PadAction: View {
    let title: String
    let icon: String
    var destructive = false
    var enabled = true
    let action: () -> Void
    @Environment(\.pageMetrics) private var metrics

    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                MarginRow(metrics: metrics, alignment: .center) {
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(destructive ? Color.margin : Color.ink)
                } page: {
                    Text(title)
                        .font(Typeface.page(.body))
                        .foregroundStyle(destructive ? Color.margin : Color.ink)
                }
                .padding(.vertical, 14)
                RuledLine()
            }
            .contentShape(Rectangle())
            .opacity(enabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/// The confirm / cancel pair at the foot of a card.
struct PadButtons: View {
    let title: String
    var destructive = false
    var enabled = true
    let action: () -> Void
    @Environment(Pad.self) private var pad
    @Environment(\.pageMetrics) private var metrics

    var body: some View {
        MarginRow(metrics: metrics, alignment: .center) {
            HStack(spacing: 18) {
                Button(title, action: action)
                    .buttonStyle(InkFilledStyle(color: destructive ? .margin : .ballpoint))
                    .disabled(!enabled)
                Button("Cancel") { pad.dismiss() }
                    .buttonStyle(.plain)
                    .font(Typeface.note(.body, .medium))
                    .foregroundStyle(Color.pencil)
            }
        }
        .padding(.top, 10)
        .padding(.bottom, 6)
    }
}

/// "Are you sure?" as a card.
struct ConfirmCard: View {
    let title: String
    var message: String?
    let actionTitle: String
    var destructive = false
    let action: () -> Void
    @Environment(Pad.self) private var pad

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PadHeading(title: title, message: message)
            PadButtons(title: actionTitle, destructive: destructive) {
                pad.dismiss()
                action()
            }
        }
    }
}

/// Something went wrong, said plainly, with one way out.
struct NoticeCard: View {
    let title: String
    let message: String
    var onDismiss: () -> Void = {}
    @Environment(Pad.self) private var pad
    @Environment(\.pageMetrics) private var metrics

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PadHeading(title: title, message: message)
            MarginRow(metrics: metrics) {
                Button("OK") {
                    pad.dismiss()
                    onDismiss()
                }
                .buttonStyle(InkFilledStyle(color: .ballpoint))
            }
            .padding(.top, 10)
            .padding(.bottom, 6)
        }
    }
}

/// Rename something: one ink line to write on.
struct RenameCard: View {
    let title: String
    var message: String?
    let placeholder: String
    let initial: String
    let save: (String) -> Void
    @Environment(Pad.self) private var pad
    @Environment(\.pageMetrics) private var metrics
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PadHeading(title: title, message: message)
            MarginRow(metrics: metrics) {
                InkField(placeholder: placeholder, text: $text)
                    .focused($focused)
                    .submitLabel(.done)
                    .onSubmit(commit)
            }
            .padding(.bottom, 12)
            PadButtons(title: "Save", action: commit)
        }
        .onAppear {
            text = initial
            focused = true
        }
    }

    private func commit() {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        pad.dismiss()
        save(value)
    }
}

// MARK: - Controls

/// A filled ink capsule — the one strong button, used once per card.
struct InkFilledStyle: ButtonStyle {
    var color: Color = .ballpoint
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typeface.note(.body, .semibold))
            .foregroundStyle(Color.paper)
            .padding(.horizontal, 22)
            .padding(.vertical, 11)
            .background(Capsule().fill(isEnabled ? color : Color.pencil.opacity(0.5)))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// A text field that's a line to write on: serif text over a rule that turns blue while you type.
struct InkField: View {
    let placeholder: String
    @Binding var text: String
    var secure = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if secure {
                    SecureField("", text: $text, prompt: Text(placeholder).foregroundStyle(Color.pencil.opacity(0.7)))
                } else {
                    TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(Color.pencil.opacity(0.7)))
                }
            }
            .textFieldStyle(.plain)
            .font(Typeface.page(.title3))
            .foregroundStyle(Color.ink)
            .tint(.ballpoint)
            .focused($focused)
            .accessibilityLabel(placeholder)
            Rectangle()
                .fill(focused ? Color.ballpoint : Color.rule)
                .frame(height: focused ? 2 : 1)
                .animation(.easeOut(duration: 0.15), value: focused)
        }
    }
}

/// A toggle drawn as a box on a form, ticked in blue ballpoint.
struct TickBoxStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(alignment: .center, spacing: 14) {
                configuration.label
                    .font(Typeface.page(.body))
                    .foregroundStyle(Color.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ZStack {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(configuration.isOn ? Color.ballpoint : Color.pencil, lineWidth: 1.6)
                        .frame(width: 24, height: 24)
                    if configuration.isOn {
                        Image(systemName: "checkmark")
                            .font(.system(size: 15, weight: .heavy))
                            .foregroundStyle(Color.ballpoint)
                            .rotationEffect(.degrees(-4))
                            .offset(x: 1.5, y: -1.5)
                            .transition(.scale(scale: 0.4).combined(with: .opacity))
                    }
                }
                .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isOn)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
    }
}

// MARK: - Top bar

/// The app's own top bar: ink icons on paper, the page fading out beneath it as it scrolls.
struct PageBar<Leading: View, Trailing: View>: View {
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 4) {
            leading
            Spacer(minLength: 0)
            trailing
        }
        .padding(.horizontal, 8)
        .frame(height: 48)
        .background {
            LinearGradient(colors: [Color.paper, Color.paper, Color.paper.opacity(0)], startPoint: .top, endPoint: .bottom)
                .padding(.bottom, -18)
                .ignoresSafeArea(edges: .top)
        }
    }
}

/// An ink icon button for the top bar.
struct BarKey: View {
    let systemImage: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Color.ink)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(label)
    }
}

/// Back, as an ink chevron. Pairs with the swipe-back fix below, since hiding the system bar
/// would otherwise switch the edge swipe off.
struct BackKey: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        BarKey(systemImage: "chevron.left", label: "Back") { dismiss() }
    }
}

// UIKit turns off the edge-swipe back gesture when the navigation bar is hidden. Every screen
// here hides it and draws its own bar, so give the gesture back whenever there's somewhere to go.
extension UINavigationController: @retroactive UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        viewControllers.count > 1
    }
}
