# Throne for iOS — клиент на ядре ThroneCore + Turnable

Рабочее имя проекта — **Throne** (не «Throne», чтобы не смешивать с апстримом).
Продукт: iOS-клиент прокси/VPN с тем же ядром, что у Throne (sing-box-форк + Xray) и с
дополнительным транспортом Turnable.

**Текущий статус: фаза P0 — скелет.** Кода протоколов, подписок и Turnable здесь ещё нет;
цель P0 — доказать, что связка «gomobile-ядро + Network Extension + подпись + CI» работает.

## Структура

```
ios/                     Xcode-проект, генерируется из project.yml (XcodeGen)
  App/                   приложение (SwiftUI)
  PacketTunnel/          NEPacketTunnelProvider + реализация LibboxPlatformInterface
  Shared/                общий код приложения и расширения
  Frameworks/            сюда CI кладёт Libbox.xcframework (в git не входит)
docs/                    P0, инструкция по Apple-аккаунту и секретам
.github/workflows/ios.yml  сборка неподписанного .ipa + (опционально) подпись и TestFlight
scripts/                 локальные помощники для macOS
core/                    закреплённый коммит ядра (P1 добавит xray/turnable-биндинги)
```

## Ядро

P0 использует `experimental/libbox` из форка `throneproj/sing-box` — того самого, на котором
работает Throne. Коммит закреплён в `core/singbox-ref.txt`. Позже к нему добавляются
`thronecore`-биндинги (Xray) и Turnable как отдельные пакеты в одном XCFramework.

## Приёмка P0

1. `xcodegen generate` собирает проект без ручных правок.
2. CI отдаёт артефакт `Throne-unsigned.ipa`.
3. На устройстве: приложение ставится, туннель поднимается, в логе видно версию sing-box
   и строку `tunnel started`.
4. Трафик идёт в обход: `curl https://ifconfig.me` через туннель возвращает IP сервера провайдера
   (для P0 — прямое соединение через `direct`, то есть проверяется работоспособность TUN,
   а не сервера).

## Что читать дальше

- `docs/apple-setup.md` — что нужно сделать в Apple Developer (аккаунт, App ID, сертификат, секреты).
- `docs/p0.md` — объём фазы, порядок запуска, критерии и известные ограничения.
