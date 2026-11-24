import SwiftUI

/// Единый вид приложения: акцент, карточки, бейджи протоколов, кнопка подключения.
enum Theme {
    /// Фирменный коралл Throne — тот же, что в настольной и Android-версии.
    static let accent = Color(red: 0.94, green: 0.34, blue: 0.36)

    /// Задержка как светофор: зелёный — играть и смотреть, оранжевый — терпимо, красный — нет.
    static func pingColor(_ millis: Int?) -> Color {
        guard let millis else { return Color(uiColor: .tertiaryLabel) }
        switch millis {
        case ..<250: return .green
        case ..<500: return .orange
        default: return .red
        }
    }

    static func pingText(_ millis: Int?) -> String {
        guard let millis else { return "—" }
        return "\(millis) мс"
    }
}

/// Бейдж протокола: «VLESS · Reality», «Xray · XHTTP», «WireGuard».
struct ProtocolBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundColor(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(uiColor: .tertiarySystemFill))
            )
    }
}

/// Главная кнопка экрана «Серверы»: одно нажатие — туннель поднят или погашен.
struct PowerButton: View {
    let on: Bool
    let busy: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(on ? Theme.accent : Color(uiColor: .tertiarySystemFill))
                    .frame(width: 60, height: 60)
                if busy {
                    ProgressView().progressViewStyle(.circular).tint(.white)
                } else {
                    Image(systemName: "power")
                        .font(.system(size: 23, weight: .semibold))
                        .foregroundColor(on ? .white : .secondary)
                }
            }
            .overlay(
                Circle()
                    .stroke(Theme.accent.opacity(on ? 0.22 : 0), lineWidth: 7)
                    .frame(width: 60, height: 60)
            )
            .animation(.easeInOut(duration: 0.2), value: on)
        }
        .buttonStyle(.plain)
    }
}

/// «Папка» сверху списка: подписка целиком или все серверы.
struct FolderChip: View {
    let title: String
    let count: Int
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.subheadline.weight(selected ? .semibold : .regular))
                Text("\(count)")
                    .font(.caption2)
                    .foregroundColor(selected ? Color.white.opacity(0.85) : .secondary)
            }
            .foregroundColor(selected ? .white : .primary)
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .background(
                Capsule().fill(selected ? Theme.accent : Color(uiColor: .tertiarySystemFill))
            )
        }
        .buttonStyle(.plain)
    }
}

/// Плашка-кнопка: используется для «Пинг», «Скорость» и подсказок в карточках.
struct PlaqueButton: View {
    let title: String
    let icon: String
    var filled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption2.weight(.semibold))
                Text(title)
                    .font(.caption2.weight(.medium))
            }
            .foregroundColor(filled ? .white : Theme.accent)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(filled ? Theme.accent : Theme.accent.opacity(0.12))
            )
        }
        .buttonStyle(.borderless)
    }
}

/// Маленькая кнопка в заголовке секции: только иконка, чтобы не отнимать место у названия.
struct HeaderButton: View {
    let icon: String
    var tint: Color = .secondary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))
                .foregroundColor(tint)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color(uiColor: .tertiarySystemFill)))
        }
        .buttonStyle(.borderless)
    }
}
