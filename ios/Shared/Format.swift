import Foundation

/// Единый формат размеров и скоростей во всём приложении: единица подбирается
/// по величине — Б, КБ, МБ, ГБ, ТБ (для скорости те же с «/с»).
///
/// Почему не `ByteCountFormatter`: на нуле он выдаёт «Zero KB» и в разных локалях
/// ставит разные разделители, поэтому считаем сами — с запятой, как принято в русском.
enum Format {
    /// Размер: «0 Б», «812 Б», «12 КБ», «1,4 МБ», «3,2 ГБ».
    static func size(_ bytes: Int64) -> String {
        amount(Double(bytes), units: ["Б", "КБ", "МБ", "ГБ", "ТБ"])
    }

    static func size(_ bytes: Double) -> String {
        amount(bytes, units: ["Б", "КБ", "МБ", "ГБ", "ТБ"])
    }

    /// Скорость: «0 Б/с», «214 КБ/с», «1,2 МБ/с».
    static func rate(_ bytesPerSecond: Double) -> String {
        amount(bytesPerSecond, units: ["Б/с", "КБ/с", "МБ/с", "ГБ/с", "ТБ/с"])
    }

    /// Бит в секунду — для пинга и замеров скорости, где считают в мегабитах.
    static func rateFromMbps(_ megabits: Double) -> String {
        amount(megabits, units: ["Мбит/с", "Гбит/с"], base: 1000)
    }

    private static func amount(_ value: Double, units: [String], base: Double = 1024) -> String {
        guard value > 0, value.isFinite else { return "0 " + units[0] }
        var size = value
        var index = 0
        while size >= base, index < units.count - 1 {
            size /= base
            index += 1
        }
        let digits = (index == 0 || size >= 100) ? 0 : 1
        let text = String(format: "%.\(digits)f", size).replacingOccurrences(of: ".", with: ",")
        return text + " " + units[index]
    }
}
