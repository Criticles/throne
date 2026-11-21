# Что нужно сделать в Apple Developer (один раз)

Всё, что ниже, делается **вами** — я не касаюсь паролей, сертификатов и приватных ключей.
Инструкция рассчитана на Windows: Xcode не нужен, нужен только `openssl` (он есть в git-bash).

## 0. Что понадобится

- Apple Developer Program, **платный** ($99/год). Бесплатный personal team не выдаёт
  entitlement `com.apple.developer.networking.networkextension`, без него VPN-расширение не запустится.
- iPhone с iOS 15+ для установки сборок.
- 15–20 минут.

## 1. Team ID

developer.apple.com → Account → Membership → **Team ID** (10 символов). Он пойдёт в секрет `TEAM_ID`.

## 2. App Group

Certificates, Identifiers & Profiles → **Identifiers** → фильтр *App Groups* → **+**:

```
group.com.egor.orbita
```

(если меняете bundle id — меняйте и здесь, и в трёх местах проекта: `ios/project.yml`,
`ios/Shared/SharedConstants.swift`, `docs/`.)

## 3. Два App ID

**App ID приложения:** Identifiers → App IDs → **+** → App
- Bundle ID: `com.egor.orbita` (Explicit)
- Capabilities: ✅ **App Groups** (выбрать `group.com.egor.orbita`)

**App ID расширения:** Identifiers → App IDs → **+** → App
- Bundle ID: `com.egor.orbita.tunnel` (Explicit)
- Capabilities: ✅ **App Groups** (та же группа), ✅ **Network Extensions**
  и внутри отметить **Packet Tunnel**

## 4. Сертификат (Apple Distribution)

Создаём CSR без Mac:

```bash
openssl genrsa -out orbita.key 2048
openssl req -new -key orbita.key -out orbita.csr \
  -subj "/CN=Orbita/emailAddress=ВАШ_APPLE_ID/C=RU"
```

Certificates → **+** → *Apple Distribution* (или *Apple Development*, если ставите только на свой
телефон по кабелю/Ad Hoc) → загрузить `orbita.csr` → скачать `distribution.cer` → собрать `.p12`:

```bash
openssl x509 -in distribution.cer -inform DER -out distribution.pem -outform PEM
openssl pkcs12 -export -inkey orbita.key -in distribution.pem -out orbita.p12
# пароль экспорта запомните — он пойдёт в секрет APPLE_CERT_PASSWORD
```

`orbita.key` и `orbita.p12` **не коммитить**.

## 5. Provisioning profiles — НЕ НУЖНЫ (по умолчанию)

CI подписывает сборку **автоматически** по ключу App Store Connect: `xcodebuild archive`
с флагами `-allowProvisioningUpdates` и `-authenticationKey*` сам создаёт и скачивает профили
для обоих таргетов. От вас нужны только: платный аккаунт, App ID с capabilities (п. 2–3),
сертификат (п. 4) и ключ API (п. 6).

Если автоматическая подпись не заведётся (например, Apple потребует ручного профиля),
тогда: Profiles → **+** → *App Store Connect* для `com.egor.orbita` и для
`com.egor.orbita.tunnel`, и добавьте их base64 в секреты `PROFILE_APP` / `PROFILE_TUNNEL` —
это резервный путь, workflow его пока не использует.

## 5a. Установка на телефон без TestFlight

Нужен UDID: Devices → **+** → UDID телефона. Дальше либо *Ad Hoc* профиль для обоих App ID,
либо переподпись неподписанного `.ipa` на Windows (Sideloadly/AltStore) вашим сертификатом.

## 6. Ключ для загрузки в TestFlight

Users and Access → **Integrations** → App Store Connect API → **+**
- роль: *App Manager*
- скачать `.p8` (**скачивается один раз**), записать **Key ID** и **Issuer ID**.

## 7. Секреты в GitHub

Settings → Secrets and variables → Actions → New repository secret. Значения — base64:

```bash
base64 -w0 orbita.p12 > p12.b64
base64 -w0 orbita_app.mobileprovision > app.b64
base64 -w0 orbita_tunnel.mobileprovision > tunnel.b64
base64 -w0 AuthKey_XXXX.p8 > key.b64
```

| Секрет | Значение |
|---|---|
| `TEAM_ID` | Team ID из п.1 |
| `APPLE_CERT_P12` | содержимое `p12.b64` |
| `APPLE_CERT_PASSWORD` | пароль экспорта `.p12` |
| `ASC_KEY_ID` | Key ID из п.6 |
| `ASC_ISSUER_ID` | Issuer ID из п.6 |
| `ASC_KEY_P8` | содержимое `key.b64` |
| `PROFILE_APP`, `PROFILE_TUNNEL` | не нужны при автоматической подписи; резерв |

Пока секретов нет, CI всё равно собирает **неподписанный** `.ipa` — его можно переподписать
на Windows (Sideloadly/AltStore) своим сертификатом, и он уже проверяет, что весь iOS-код компилируется.

## 8. Что прислать мне

Только: Team ID (не секрет), подтверждение что bundle id остаётся `com.egor.orbita`,
и скриншот лога CI после первого запуска. Пароли, `.p12` и `.p8` мне не нужны и присылать их не надо.
