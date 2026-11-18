import SwiftUI

/// Settings' one row and six controls (docs/design/app-shell.md › Settings › Layout), drawn
/// from `Tokens` the way the web's `.set-row` is: label left, control right, a hairline between
/// rows. No system `Form`, grouped list or `TabView`.

enum SettingsLook {
    static let column: CGFloat = 720
    static let top: CGFloat = 40
    static let rowPad: CGFloat = 11
    static let label: CGFloat = 14
    static let description: CGFloat = 12
}

/// The page: the section's title, then its rows, on the transcript's measure.
struct SettingsPage<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.frog(size: 17, weight: .semibold))
                    .foregroundStyle(Tokens.text)
                    .padding(.bottom, 10)
                    .accessibilityAddTraits(.isHeader)
                content
            }
            .frame(maxWidth: SettingsLook.column, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.top, SettingsLook.top)
            .padding(.bottom, 48)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.automatic)
    }
}

/// A group's muted label: 22 above, 4 below.
struct SettingsGroupLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.frog(size: 12, weight: .semibold))
            .foregroundStyle(Tokens.textSecondary)
            .padding(.top, 22)
            .padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Rows with a hairline between them and none after the last.
struct SettingsRows<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        Group(subviews: content) { rows in
            VStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    row
                    if row.id != rows.last?.id {
                        Rectangle().fill(Tokens.line).frame(height: 1)
                    }
                }
            }
        }
    }
}

/// Label (and description) on the left, the control on the right.
struct SettingsRow<Control: View>: View {
    let label: String
    var description: String? = nil
    @ViewBuilder var control: Control

    init(_ label: String, description: String? = nil, @ViewBuilder control: () -> Control) {
        self.label = label
        self.description = description
        self.control = control()
    }

    init(_ row: SettingsCatalog.Row, description: String? = nil, @ViewBuilder control: () -> Control) {
        self.init(row.label, description: description ?? row.description, control: control)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.frog(size: SettingsLook.label))
                    .foregroundStyle(Tokens.text)
                if let description, !description.isEmpty {
                    Text(description)
                        .font(.frog(size: SettingsLook.description))
                        .foregroundStyle(Tokens.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control
        }
        .padding(.vertical, SettingsLook.rowPad)
        .accessibilityElement(children: .contain)
    }
}

/// On or off, at once; green when on.
struct FrogToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule().fill(configuration.isOn ? Tokens.accent : Tokens.lineStrong)
                Circle()
                    .fill(configuration.isOn ? Tokens.onAccent : Color(white: 0.93))
                    .shadow(color: .black.opacity(configuration.isOn ? 0 : 0.15), radius: 1, y: 0.5)
                    .frame(width: 16, height: 16)
                    .padding(2)
            }
            .frame(width: 34, height: 20)
            .animation(.snappy(duration: 0.15), value: configuration.isOn)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(configuration.isOn ? "on" : "off")
    }
}

/// A row's switch.
struct FrogToggle: View {
    let label: String
    @Binding var isOn: Bool
    var body: some View {
        Toggle(label, isOn: $isOn).labelsHidden().toggleStyle(FrogToggleStyle())
    }
}

/// Two to four choices on a line: a capsule track, the chosen one raised.
struct FrogSegmented: View {
    let label: String
    let options: [SettingsCatalog.Option]
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.id) { o in
                Button { selection = o.id } label: {
                    Text(o.label)
                        .font(.frog(size: 12))
                        .foregroundStyle(selection == o.id ? Tokens.text : Tokens.textSecondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(selection == o.id ? Tokens.well : .clear, in: .rect(cornerRadius: 7))
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == o.id ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(2)
        .background(Tokens.raised, in: .rect(cornerRadius: 9))
        .fixedSize()
        .accessibilityLabel(label)
    }
}

/// Five or more choices, or names of any length: a bordered pill that opens a menu.
struct FrogPillMenu<Items: View>: View {
    let title: String
    @ViewBuilder var items: Items

    var body: some View {
        Menu { items } label: {
            HStack(spacing: 6) {
                Text(title).font(.frog(size: 12)).foregroundStyle(Tokens.text).lineLimit(1)
                Image(systemName: "chevron.down").font(.frog(size: 9, weight: .semibold)).foregroundStyle(Tokens.textSecondary)
            }
            .padding(.leading, 12).padding(.trailing, 10).padding(.vertical, 3)
            .overlay(Capsule().strokeBorder(Tokens.lineStrong))
            .contentShape(Capsule())
            .padding(1)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

/// One short value; saves on return or when it loses focus. No Save button.
struct FrogField: View {
    let label: String
    @Binding var text: String
    var width: CGFloat = 180
    var onCommit: () -> Void = {}
    @FocusState private var focused: Bool

    var body: some View {
        TextField(label, text: $text)
            .textFieldStyle(.plain)
            .font(.frog(size: 12.5))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Tokens.raised, in: .rect(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Tokens.lineStrong))
            .frame(width: width)
            .focused($focused)
            .onSubmit(onCommit)
            .onChange(of: focused) { if !focused { onCommit() } }
            .accessibilityLabel(label)
    }
}

/// Bordered and small; red text only for what can't be undone (and it asks first).
struct SettingsButtonStyle: ButtonStyle {
    var destructive = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.frog(size: 12))
            .foregroundStyle(destructive ? Tokens.warn : Tokens.text)
            .padding(.horizontal, 12).padding(.vertical, 4)
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Tokens.lineStrong))
            .background(configuration.isPressed ? Tokens.hover : .clear, in: .rect(cornerRadius: 8))
            .contentShape(.rect)
    }
}

/// A read-only fact where a control would be.
struct SettingsValue: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.frog(size: 13)).foregroundStyle(Tokens.textSecondary).monospacedDigit().lineLimit(1)
    }
}
