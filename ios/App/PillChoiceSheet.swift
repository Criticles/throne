import SwiftUI

/// Универсальный выбор «снизу» для шторок: затемнение и панель с плашками.
/// Нужен там, где системный `confirmationDialog` привязан к строке внутри `.sheet`:
/// он всплывает у навбара и закрывает родительскую шторку.
struct PillChoiceSheet: View {
    struct Item: Identifiable {
        let id: String
        let title: String
        let detail: String?
        let accent: Bool
    }

    let title: String
    let items: [Item]
    let extraTitle: String?
    let onPick: (Item) -> Void
    let onExtra: () -> Void
    let onCancel: () -> Void

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture { onCancel() }

            VStack(spacing: 0) {
                Text(title)
                    .font(.headline)
                    .padding(.top, 14)
                    .padding(.bottom, 10)

                ScrollView {
                    VStack(spacing: 7) {
                        ForEach(items) { item in
                            pill(item.title, detail: item.detail, accent: item.accent) { onPick(item) }
                        }
                        if let extraTitle {
                            pill(extraTitle, detail: nil, accent: false, action: onExtra)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 6)
                }
                .frame(maxHeight: 320)

                Button("Отмена") { onCancel() }
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(.secondary)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
            }
            .background(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemGroupedBackground))
            )
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .transition(.opacity)
    }

    private func pill(_ text: String, detail: String?, accent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(text)
                    .font(.subheadline)
                    .foregroundColor(accent ? Theme.accent : .primary)
                    .lineLimit(1)
                Spacer(minLength: 6)
                if let detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity)
            .background(accent ? Theme.accent.opacity(0.14) : Color(uiColor: .tertiarySystemFill))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
