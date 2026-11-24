# Протоколы

## Что разбирается при импорте подписки

| Протокол | Ядро | Импорт | Бейдж |
|---|---|---|---|
| VLESS (TLS / Reality) | sing-box | `vless://` | `VLESS · Reality`, `VLESS · TLS`, `VLESS` |
| VLESS + XHTTP | Xray | `vless://` с `type=xhttp` | `Xray · XHTTP`, `Xray · XHTTP + Reality` |
| Hysteria2 / hy2 | sing-box | `hysteria2://`, `hy2://` | `Hysteria2` |
| Mieru | sing-box | `mierus://` (и JSON панели) | `Mieru` |
| WireGuard | sing-box | `wg://`, JSON подписки | `WireGuard` |
| AmneziaWG | sing-box | `amneziawg://`, JSON подписки | `AmneziaWG` |
| WireTurn | sing-box + Turnable | `?format=wireturn` | `WireTurn` |
| sing-box JSON | sing-box | `?format=`/JSON в подписке | `JSON подписки` |

Разделение AWG и WG сделано намеренно: у AmneziaWG свои поля обфускации
(`amps`, `hosts`, `s1/s2/h1–h4`, `random_trailers`), и ядро падает на неизвестных полях,
если их не отфильтровать.

## Что ядро умеет, но импорт пока не разбирает

| Протокол | Причина |
|---|---|
| VMess | нет парсера ссылок; JSON-профиль сработает как «JSON подписки» |
| Trojan | то же |
| Shadowsocks | то же |
| TUIC | ядро собрано с `with_quic`, парсера нет |
| OpenVPN | собран (`with_openvpn`), профилей в UI нет |
| MasterDNS / DNSTT | есть в ядре (форк `throneproj/sing-box`), UI нет |
| SOCKS / HTTP | как outbound в JSON работают |

## Фильтр протоколов при импорте

Настройки → «Протоколы при импорте» — кнопка со списком всех типов. Выключенное не попадает
ни в первичный импорт, ни в обновление подписки; уже добавленные серверы остаются.

## Теги сборки ядра

```
with_gvisor, with_dhcp, with_wireguard, with_utls, with_clash_api, with_quic,
with_openvpn, with_low_memory
```

`with_clash_api` обязателен: на нём параллельный пинг, живой трафик и список соединений.
