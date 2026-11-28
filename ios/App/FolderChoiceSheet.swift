import SwiftUI

/// Выбор папки прямо в текущей шторке: затемнение + панель снизу.
/// Системный `confirmationDialog` внутри `.sheet` ведёт себя непредсказуемо —
/// всплывает у навбара и закрывает родителя, поэтому рисуем панель сами.
struct FolderChoiceSheet: View {
    struct Option: Identifiable {
        let id: UUID
        let title: String
        let detail: String?
        let isDefault: Bool
    }

    let title: String
    let defaultTitle: String
    let defaultDetail: String?
    let options: [Option]
    let onDefault: () -> Void
    let onPick: (Option) -> Void
    let onNew: () -> Void
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
                        pill(defaultTitle, detail: defaultDetail, accent: true) { onDefault() }

                        ForEach(options) { option in
                            pill(option.title, detail: option.detail, accent: false) { onPick(option) }
                        }

                        Button {
                            onNew()
                        } label: {
                            Text("＋ Новая папка")
                                .font(.subheadline)
                                .foregroundColor(Theme.accent)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 13)
                                .background(Color(uiColor: .tertiarySystemFill))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 6)
                }
                .frame(maxHeight: 300)

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
