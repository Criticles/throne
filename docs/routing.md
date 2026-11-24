# Маршрутизация

## Как это устроено в приложении

Маршрутизация — это **профиль** (несколько профилей, переключаются в «Маршруте» →
«Маршрутизация»). В профиле:

- **название** — оно же подпись «активно: …» под кнопкой;
- **общий outbound** (`proxy` / `direct` / `reject` / конкретный сервер) — куда идёт всё,
  что не поймала ни одна запись;
- **правила** в порядке применения: срабатывает первая подходящая запись.

Два вида редактирования:

| Вид | Что внутри |
|---|---|
| Упрощённая | четыре списка по строке: «Напрямую», «Прокси», «Блокировать», «WARP-bypass» |
| Расширенная | записи «правило → outbound»: условие и цель, с выбором сервера из подписки |

Профиль можно **экспортировать и импортировать**: JSON или ссылка `throne://route?plan=…`
(наш формат). Совместимость с форматом Throne PC (`throne://route/<base64url>`)— следующий шаг,
схема ниже описана полностью, чтобы маппинг был очевиден.

## Атрибуты

Полный список атрибутов sing-box, который поддерживает Throne (скриншоты владельца), с
пометкой **★** — те, что реально используются в боевом профиле «Criticles Zapret».

### Совпадение по адресу и протоколу

| Атрибут | Что означает |
|---|---|
| `domain` ★ | точный домен: `claude.ai`, `ip-api.com` |
| `domain_suffix` | домен и все поддомены |
| `domain_keyword` | подстрока в домене |
| `domain_regex` | регулярное выражение по домену |
| `ip_cidr` | получатель по IP/подсети |
| `source_ip_cidr` | источник по IP/подсети |
| `source_ip_is_private` | источник из приватных сетей |
| `ip_is_private` / `ip_version` | приватность и версия IP |
| `network` | `tcp` / `udp` |
| `protocol` ★ | `dns`, `bittorrent`, `http`, `tls` — по sniffing |
| `inbound` | по входящему тегу |

### Порты и приложения

| Атрибут | Что означает |
|---|---|
| `port` / `port_range` | порт получателя |
| `source_port` / `source_port_range` | порт источника |
| `process_name` ★ | имя процесса (`Telegram.exe`, `Discord.exe`) — только десктоп |
| `process_path` / `process_path_regex` | путь процесса — только десктоп |
| `package_name` | пакет Android |
| `wifi_ssid` / `wifi_bssid` | текущая сеть |

### Наборы и действия

| Атрибут | Что означает |
|---|---|
| `rule_set` ★ | набор правил: `geosite-ru`, `geoip-ru`, `geosite-anthropic`, `geosite-spotify@ads` |
| `invert` | инвертировать условие |
| `outbound` ★ | цель: `proxy`, `direct`, `<имя сервера>` |
| `action` ★ | `route` (направить) или `reject` (заблокировать) |
| `override_address` / `override_port` | подменить адрес/порт |
| `strategy` | стратегия разрешения адреса |
| `tls_spoof` / `tls_spoof_method` | подмена TLS (используется в zapret-сценариях) |
| `no_drop` | не отбрасывать соединение при reject |
| `override_destination` | переписать место назначения |

**★ — минимальный набор, которого хватает на практике:** `domain`, `rule_set`, `process_name`,
`protocol`, `outbound`, `action`. Остальное нужно редко, но UI должен давать их добавить.

## Формат профиля Throne PC

Ссылка: `throne://route/<base64url(JSON)>`. JSON (v1):

```json
{
  "kind": "throne-route-profile",
  "v": 1,
  "name": "Criticles Zapret",
  "default_outbound": "direct",
  "rules": [
    {
      "type": "custom",
      "name": ".exe",
      "action": "route",
      "outbound": "proxy",
      "process_name": ["Telegram.exe", "trove.exe", "GlyphClient.exe"]
    },
    {
      "type": "custom",
      "name": "Block Rule",
      "action": "reject",
      "rule_set": ["geosite-spotify@ads"]
    },
    {
      "type": "custom",
      "name": "Block Domains",
      "action": "reject",
      "domain": ["s.youtube.com", "posthog.com", "ads-api.twitter.com"]
    },
    {
      "type": "custom",
      "name": "Direct Rule",
      "action": "route",
      "outbound": "direct",
      "rule_set": ["geoip-ru", "geosite-ru", "geosite-category-ru", "geosite-steam"]
    },
    { "type": "custom", "name": "Direct DNS", "action": "route", "outbound": "direct", "protocol": "dns" },
    { "type": "custom", "name": "Direct Torrent", "action": "route", "outbound": "direct", "protocol": "bittorrent" },
    {
      "type": "custom",
      "name": "Proxy Rule",
      "action": "route",
      "outbound": "proxy",
      "rule_set": ["geoip-ru-blocked", "geosite-openai", "geosite-telegram", "geosite-netflix"]
    },
    {
      "type": "custom",
      "name": "Zapret Rule",
      "action": "route",
      "outbound": "🇷🇺 RU sushuri-madonna vless · criticles",
      "rule_set": ["geosite-youtube", "geosite-discord"]
    }
  ]
}
```

Правила:

- `outbound` — `proxy`, `direct` или **точное имя сервера** из подписки;
- `action` — `route` или `reject` (у `reject` outbound не нужен);
- условия одного правила объединяются по И;
- порядок правил — порядок применения; `default_outbound` работает, если не совпало ничего.

## Что уже применяется

В dev-режиме ядро поднимает один сервер, поэтому профиль пока не влияет на трафик: он
редактируется, экспортируется и проверяется (поле «какое правило поймает адрес» на вкладке
«Соединения»). Применение — в сборке через Network Extension, где правила уходят в
`route.rules` и `route.rule_set`.
