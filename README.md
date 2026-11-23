# Throne for iOS

iOS-клиент прокси/VPN на том же ядре, что у Throne для ПК: форк `sing-box` (`throneproj/sing-box`)
плюс транспорт **Turnable** (VK TURN/SFU). Ядро **Xray** подключается для протоколов, которых в
sing-box нет — в первую очередь VLESS + XHTTP.

Сборка идёт только через GitHub Actions (macOS-раннер), подпись — на стороне пользователя
(Sideloadly / LiveContainer). Готовый артефакт — неподписанный `.ipa`.

---

## 1. Как это устроено: одно ядро, два транспорта

Ключевое ограничение iOS: **в одном процессе может жить только одна Go-среда**. Два
gomobile-фреймворка в одном приложении дают два рантайма и падение на старте — это уже
проверено на первом заходе с Turnable.

Поэтому всё, что написано на Go, линкуется в **один** фреймворк — `Libbox.xcframework`,
собранный из пакета `experimental/libbox` форка sing-box. Всё остальное добавляется туда же
**оверлеями**: файл кладётся в тот же Go-пакет и экспортирует функции с префиксом `Libbox*`,
которые gomobile поднимает в Swift.

```
                ┌──────────────────────────── Libbox.xcframework ──────────────────────────┐
Go:             │  experimental/libbox (sing-box)                                          │
                │    ├── zz_turnable.go  → LibboxTurnableStart/Stop/ListenAddress           │
                │    └── zz_xray.go      → LibboxXrayStart/Stop   (в работе)                │
                └──────────────────────────────────────────────────────────────────────────┘
iOS (Swift):    App/ (SwiftUI) ──► DevEngine ──► LibboxCommandServer (sing-box)
                                     │
                                     └────────► TurnableEngine → LibboxTurnableStart
```

Throne для ПК держит sing-box и Xray в одном Go-модуле (`core/go.mod`,
`replace github.com/xtls/xray-core => github.com/throneproj/xray-core`). Мы повторяем ту же
схему, но на уровне пакета: у gomobile один фреймворк на пакет, а два Go-рантайма в процессе
не уживаются.

---

## 2. Карта репозитория

```
core/
  singbox-ref.txt           закреплённый коммит и теги сборки ядра
  turnable_overlay/
    zz_turnable.go          оверлей: Turnable внутри пакета libbox (единый рантайм)
  turnablecore/             отдельный Go-пакет-обёртка для локальных тестов (turnprobe)
    turnable.go             Setup/Start/ListenAddress/SetLogSink
    cmd/turnprobe/main.go   CLI: поднять Turnable и смотреть лог без iOS

ios/
  project.yml               единственный источник истины для Xcode-проекта (XcodeGen)
  App/
    AppMain.swift           точка входа, вкладки VPN/Dev
    DevView.swift           экран Dev: подписка, профили, старт, проба, «Проверить все», журнал
    DevEngine.swift         запуск/остановка ядра в процессе приложения, серия проверок
    TurnableEngine.swift    обёртка над LibboxTurnable* (биндинг из оверлея)
    DevPlatform.swift       заглушка LibboxPlatformInterface для dev-режима (без NE)
    TunnelController.swift  управление VPN-профилем (Network Extension)
  PacketTunnel/
    PacketTunnelProvider.swift  NEPacketTunnelProvider: поднимает libbox с utun
    PlatformInterface.swift     реализация платформенного интерфейса libbox
  Shared/
    Profile.swift           модель профиля (kind + payload + badge + note)
    ProfileParser.swift     разбор подписки: share-ссылки, sing-box JSON, wireturn/turnable
    ProfileStore.swift      импорт по трём User-Agent, дедупликация, хранение в UserDefaults
    ConfigBuilder.swift     сборка JSON-конфига sing-box под каждый вид профиля
    WireGuardConfig.swift   разбор wg:// и amneziawg:// (включая AmneziaWG 3.1)
    VLESSLink.swift         разбор vless:// (включая type=xhttp для будущего Xray)
    Probe.swift             проверка выхода: IP, страна, город, пинг
    LogStore.swift          единый журнал (импорт + ядро + Turnable + проба)
    LibboxBoot.swift        старт libbox с TCP control-портом (в LiveContainer unix-сокет не влезает)
    TunnelLog.swift         лог для Network Extension (общий файл)
    P0Config.swift, Shared.swift

.github/workflows/ios.yml   сборка ядра, XcodeGen, xcodebuild, упаковка .ipa
scripts/                    локальные помощники (проверка скобок Swift и т.п.)
docs/                       заметки по подписи, секретам, фазе P0
```

---

## 3. Поток данных: от подписки до пакета

### 3.1 Импорт подписки

Панель отдаёт разное в зависимости от `User-Agent` и `?format=`. `ProfileStore.importAny`
делает несколько запросов и склеивает результаты:

| Запрос | Что даёт | Как разбирается |
|---|---|---|
| UA `v2rayNG/1.8.5` | base64-список share-ссылок (vless, hysteria2) | `ProfileParser.parseStructural` + построчный разбор |
| UA `Throne/1.1.0` | смешанный текст: ссылки + JSON-конфиг sing-box | построчно: `{`/`[` → JSON, иначе ссылка |
| UA `YPtun/3.7.0` | base64-список с `amneziawg://` | `WireGuardConfig.parse` |
| `?format=wireturn` | массив `{kernelConfig:{config}, wgConfig, vlessConfig}` | `parseWireturn` |
| `?format=turnable` | массив объектов-транспортов без ключей | `parseTurnable` |

Дедупликация:
- обычные профили — по «личности сервера» (`протокол|хост|порт`), потому что панель присылает
  один сервер и ссылкой, и куском JSON-конфига;
- WireTurn и Turnable — по имени; между собой они **не** склеиваются (см. §4).

### 3.2 Запуск профиля (dev-режим)

`DevEngine.start(profile:)`:

1. Для WireTurn поднимается транспорт: `LibboxTurnableStart(kernelConfig, 127.0.0.1:9000)`.
2. Для WireTurn подмешивается MTU (по умолчанию 1200 вместо панельных 1280 — поверх TURN/SRTP
   крупные пакеты фрагментируются).
3. `ConfigBuilder.build(profile:)` собирает JSON sing-box:
   - inbound — `mixed` на `127.0.0.1:7891` (HTTP CONNECT + SOCKS5);
   - outbound/endpoints — по виду профиля;
   - DNS — см. §5;
   - `route.auto_detect_interface = false` (Network Extension в dev-режиме нет).
4. `LibboxCommandServer.startOrReloadService(json)` — sing-box стартует внутри процесса.
5. Проверка выхода через локальный прокси (§6).

### 3.3 Схемы по протоколам

```
VLESS + Reality        приложение → 127.0.0.1:7891 → vless outbound → сервер:443
Hysteria2              приложение → 127.0.0.1:7891 → hysteria2 outbound (QUIC/UDP)
Mieru                  приложение → 127.0.0.1:7891 → mieru outbound (TCP/UDP, свой протокол)
WireGuard / AmneziaWG  приложение → 127.0.0.1:7891 → endpoint wireguard → сервер:UDP
                       (AmneziaWG 3.1: random_trailers, disable_cookies, s1/s2/h1..h4, i1)
WireTurn               приложение → 127.0.0.1:7891 → endpoint wireguard → 127.0.0.1:9000
                                                            └─ Turnable: VK TURN/SFU → шлюз → WARP
Turnable (сырой)       только транспорт: VK-авторизация, капча, SRTP; туннеля нет (нет ключей WG)
```

---

## 4. Turnable: почему это транспорт, а не протокол

Turnable поднимает локальный UDP-порт и гоняет через него произвольные пакеты. Сам по себе он
не даёт адреса в сети и не шифрует полезную нагрузку — это «труба».

Панель отдаёт два разных формата одного и того же сервера:

- `?format=wireturn` → транспорт **плюс** `wgConfig` (`privateKey`, `publicKey`, `address`, `mtu`):
  из этого собирается полноценный туннель «WireGuard поверх Turnable»;
- `?format=turnable` → **только** описание транспорта (`gateway`, `call_id`, `pub_key`, `routes`).

Проверено на реальной подписке: объект из `turnable` совпадает с `kernelConfig.config` из
`wireturn` символ в символ, но без `wgConfig`. Поэтому профиль Turnable запускает транспорт
(VK-авторизация → капча → SRTP-сессия → `peer online 8/8`) и на этом останавливается: туннель
строить не из чего. В интерфейсе это штатный режим, а не «ограничение сборки».

Версия Turnable закреплена в CI: **v0.8.7** (в 0.8.5 капча VK упиралась в `ERROR_LIMIT`).
В 0.8.7 переписан отпечаток браузера: canvas/audio-хэши, WebGL-рендерер, шрифты, экран,
таймзона, `hardwareConcurrency`, `jsHeapSizeLimit`, телеметрия — именно это снимает лимит.

---

## 5. DNS: почему он идёт через туннель

Провайдер подменяет ответы системного резолвера. Замеры на этой машине и на устройстве:

```
системный DNS:  api.ipify.org → 198.20.0.68 / 8.6.112.0   (подмена)
Cloudflare DoH: api.ipify.org → 104.26.12.205             (настоящий)
```

Если резолвить до туннеля, sing-box отправляет пакет на подставленный адрес: WireGuard-handshake
проходит, а данных нет (`connection upload finished` через 20 с, `CFNetwork 310`).

Поэтому `ConfigBuilder.dnsConfig(detour:)` для всех WireGuard/WireTurn-профилей ставит DNS
через сам туннель:

```json
{"servers":[{"type":"udp","server":"1.1.1.1","detour":"wg-out","tag":"dns-remote"}],
 "final":"dns-remote","strategy":"ipv4_only"}
```

Отдельный случай — пир WireGuard, заданный доменом (`engage.cloudflareclient.com` у WARP).
Его нельзя резолвить через туннель, которого ещё нет: адрес разрешается заранее системным
`getaddrinfo` (`ConfigBuilder.resolveHost`) и подставляется в конфиг. То же делается для
эндпоинтов в JSON, который присылает панель.

---

## 6. Проверка выхода: IP, страна, пинг

`Probe.viaProxy(port:)`:

1. **Cloudflare trace** (`https://www.cloudflare.com/cdn-cgi/trace`) — основной источник IP и
   `loc`; живёт на CDN и не отдаёт 502. Резерв — `ipinfo.io`, затем `ip-api.com` (HTTP).
2. **Страна** локализуется по-русски: `🇩🇪 Германия`, `🇫🇮 Финляндия`.
3. **Пинг — один RTT через туннель, по прогретому соединению.** Мерять первым запросом
   нельзя: в него входит подъём соединения — TCP, TLS, у VLESS ещё Reality/XHTTP, у WireGuard
   хендшейк. Отсюда были 900–2300 мс при реальных ~200. Поэтому сначала прогрев (он и поднимает
   туннель), затем три запроса по уже открытому keep-alive соединению
   (`httpMaximumConnectionsPerHost = 1`) и в итог идёт минимум — это и есть один круг до выхода,
   одинаково посчитанный для VLESS, hysteria2, mieru, WireGuard и WireTurn.

У каждой пробы есть потолок по времени (`Probe.timed`): мёртвый профиль (WARP из панели, чей
хендшейк не отвечает) больше не держит очередь десятками секунд — он падает по таймауту и
проверка идёт дальше.

Кнопка «Проверить все» поднимает профили по очереди, снимает IP/страну/задержку и гасит их.
У VK-капчи есть лимит на подряд идущие авторизации, поэтому в серии выполняется не больше
8 WireTurn-профилей, остальные помечаются причиной пропуска.

---

## 7. Сборка

### CI (GitHub Actions, macOS)

1. `core/singbox-ref.txt` → клон форка, checkout на закреплённый коммит.
2. Оверлеи `zz_turnable.go` (и `zz_xray.go` после подключения Xray) копируются в пакет libbox.
3. `go mod edit -require` для Turnable, `go mod tidy`.
4. `gomobile bind` → `ios/Frameworks/Libbox.xcframework` (кэш по хешу `singbox-ref.txt`,
   оверлеев и самого workflow).
5. `xcodegen generate`, затем `xcodebuild -sdk iphoneos CODE_SIGNING_ALLOWED=NO`.
6. Упаковка в `Throne-unsigned.ipa`; артефакты — `.ipa`, заголовки фреймворка, лог сборки.

Холодная сборка ядра — 15–20 минут, тёплая — около минуты. Ключ кэша включает хеш workflow,
поэтому изменение шагов сборки сбрасывает кэш.

### Локально (macOS)

```bash
cd ios
xcodegen generate
xcodebuild -project Throne.xcodeproj -scheme Throne -sdk iphoneos build
```

### Установка на устройство

Подпись своя (Sideloadly / Xcode / LiveContainer), `.ipa` неподписанный.

---

## 8. Режимы запуска и ограничения

| Режим | Что работает | Что нет |
|---|---|---|
| **Dev** (вкладка Dev) | ядро в процессе приложения, локальный прокси 7891, все протоколы | системного VPN нет, приложение должно быть активно |
| **VPN** (Network Extension) | системный TUN, весь трафик устройства | нужна подпись с entitlement; в LiveContainer падает `permission denied` |

Технические ограничения:

- в LiveContainer unix-сокет libbox не помещается в `sun_path`, поэтому control-порт TCP (9101+);
- Turnable, запущенный в процессе приложения, iOS усыпляет при сворачивании — для постоянной
  работы его нужно поднимать внутри PacketTunnel;
- Xray (VLESS + XHTTP) пока не подключён: два профиля из подписки с `type=xhttp` не поднимаются
  и ждут ядра Xray.

---

## 9. Дорожная карта

- [x] Ядро sing-box (форк Throne) + gomobile + CI + неподписанный `.ipa`
- [x] VLESS/Reality, Hysteria2, Mieru, AmneziaWG 3.1, WireGuard
- [x] Turnable как транспорт (VK-авторизация, капча, SRTP)
- [x] WireGuard поверх Turnable (WireTurn), MTU, DNS через туннель
- [x] Проверка выхода: IP + страна + пинг в один круг, серийная проверка профилей
- [ ] **Xray**: VLESS + XHTTP (оверлей `zz_xray.go`, `replace` на `throneproj/xray-core`)
- [ ] Профиль «AUTO» (urltest по всей подписке) отдельной кнопкой
- [ ] Поднятие Turnable внутри PacketTunnel
- [ ] Подпись и установка без LiveContainer
