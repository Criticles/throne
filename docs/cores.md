# Ядра

## Что собрано внутри фреймворка

Всё лежит в одном `Libbox.xcframework`: второй gomobile-фреймворк дал бы второй Go-рантайм
и приложение падало бы при старте. Поэтому Xray и Turnable подключены оверлеями:

| Ядро | Источник | Как попадает в сборку |
|---|---|---|
| sing-box | `throneproj/sing-box`, ветка `wip/1.15.0-alpha.13-resync`, коммит из `core/singbox-ref.txt` | gomobile bind пакета `./experimental/libbox` |
| Xray | `xtls/xray-core` с `replace` на `throneproj/xray-core` | оверлей `core/xray_overlay/zz_xray.go` в том же пакете |
| Turnable (WireTurn) | `github.com/theairblow/turnable@v0.8.7` | оверлей `core/turnable_overlay/zz_turnable.go` |

Теги сборки sing-box (см. `core/singbox-ref.txt`):

```
with_gvisor, with_dhcp, with_wireguard, with_utls, with_clash_api, with_quic,
with_openvpn, with_low_memory
```

`with_clash_api` — на нём держатся параллельный пинг, живой трафик и список соединений.

## Почему именно этот коммит ядра

В `183cf759` появились поля AmneziaWG 3.1 (`random_trailers`, `disable_cookies`). На старом
пине `062ccfe` handshake к нашим серверам падал с `Received message with unknown type`.

## Что умеет ядро, но ещё не выведено в UI

| Возможность | Состояние |
|---|---|
| `type: masterdns` (DNS-туннель через публичные резолверы) | есть в ядре и в документации форка, UI нет |
| `type: dnstt` | есть в ядре |
| OpenVPN-клиент | собран (`with_openvpn`), профилей в UI нет |
| TUIC | собран (`with_quic`), парсера ссылок нет |
| VMess / Trojan / Shadowsocks | ядро умеет, импорт подписок их пока не разбирает |

## Обновление ядер

Ядра вшиты в приложение — обновление приходит новой сборкой. Чтобы не искать версии вручную,
в приложении есть экран **«Проверка обновлений ядер»** (Настройки → О приложении): он
спрашивает GitHub про последний релиз `throneproj/sing-box`, `throneproj/Xray-core` и
`TheAirBlow/Turnable` и даёт ссылку.

Порядок обновления в репозитории:

1. взять новый коммит/тег;
2. поправить `SINGBOX_REF` (или версию Turnable в workflow) в `core/singbox-ref.txt`;
3. прогнать CI — кэш ядра инвалидируется по хешу `core/singbox-ref.txt` и оверлеев;
4. проверить, что Swift-биндинги не поменялись (`LibboxXrayStart`, `LibboxTurnableStart`).

## WireTurn: ядро или транспорт

`Turnable` — это транспорт (клиент TURN/SRTP, он же WireTurn-обвязка), а не отдельное ядро
маршрутизации. Он поднимает локальный UDP-порт `127.0.0.1:9000`, к которому подключается
`wireguard`-эндпоинт sing-box. То есть туннель несёт sing-box, а пакеты до сервера тащит
Turnable.
