# mikrotik-doh-failover

<!-- md-i18n:switcher -->
**На других языках:** [English](README.md) · [Deutsch](README.de.md) · [中文](README.zh.md) · [हिन्दी](README.hi.md) · [Español](README.es.md) · Русский

**Отказоустойчивая конфигурация DNS-over-HTTPS (DoH) для MikroTik RouterOS в виде `.rsc`-скриптов, пригодных для diff.**

[**Документация**](docs/) · [**Релизы**](https://github.com/paulmann/mikrotik-doh-failover/releases) · [**История изменений**](CHANGELOG.md) · [**Проблемы**](https://github.com/paulmann/mikrotik-doh-failover/issues) · [**Безопасность**](SECURITY.md) · [**Для агентов**](AGENTS.md)

[![Лицензия: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Версия](https://img.shields.io/github/v/release/paulmann/mikrotik-doh-failover?label=release&sort=semver)](https://github.com/paulmann/mikrotik-doh-failover/releases)
[![RouterOS](https://img.shields.io/badge/RouterOS-7.20%2B-red)](https://help.mikrotik.com/docs/spaces/ROS/pages/37748767/DNS)

<img src="https://github.com/paulmann/mikrotik-doh-failover/raw/main/assets/social-preview.png"
     alt="mikrotik-doh-failover: один проверенный DoH-апстрим для RouterOS с резервным вторым DoH-эндпоинтом"
     width="100%">

RouterOS пропускает DNS локальной сети через роутер, но по умолчанию этот участок до
апстрима идёт открытым текстом. Этот проект настраивает **один проверенный** DoH-апстрим
с резервным вторым DoH-эндпоинтом, принудительно направляет классический DNS локальной сети на
роутер и добавляет плановую проверку состояния, которая при сбое переключает DoH и
второй DoH-эндпоинт. Это сопровождение «как воспроизвести и поддерживать» к статье
[«Архитектура отказоустойчивого DNS-over-HTTPS в RouterOS»](https://sysadministrator.ru/%d0%b0%d1%80%d1%85%d0%b8%d1%82%d0%b5%d0%ba%d1%82%d1%83%d1%80%d0%b0-%d0%be%d1%82%d0%ba%d0%b0%d0%b7%d0%be%d1%83%d1%81%d1%82%d0%be%d0%b9%d1%87%d0%b8%d0%b2%d0%be%d0%b3%d0%be-dns-over-https-%d0%b2-routeros/)
на `sysadministrator.ru`.

> **Состояние документации.** Числа в этом README измерены по опубликованному
> дереву 2026-10-22 (v0.1.0). Подробное обоснование решений — в
> [`docs/`](docs/); скрипты проверены на RouterOS 7.23.1 и 7.24.5.

---

## Содержание

- [Что это и зачем](#что-это-и-зачем)
- [Возможности](#возможности)
- [В цифрах](#в-цифрах)
- [Как это работает](#как-это-работает)
- [Установка](#установка)
- [Первые шаги](#первые-шаги)
- [Надёжность и ограничения](#надёжность-и-ограничения)
- [Безопасность](#безопасность)
- [Требования и совместимость](#требования-и-совместимость)
- [Документация](#документация)
- [Участие](#участие)
- [Лицензия](#лицензия)

---

## Что это и зачем

Распространённый неработающий подход к «DoH на MikroTik» — добавить несколько
DoH-серверов через `/ip dns static-server type=doh` и ждать от них резервирования.
Такого синтаксиса нет, и резервирования он не даёт: RouterOS поддерживает ровно
**один** `use-doh-server`. Другая частая ошибка — `verify-doh-cert=yes` без
доверенного CA: разрешение имён при этом молча останавливается полностью.

Проект обходит и то, и другое:

- **один активный DoH-апстрим** (по умолчанию обычный Cloudflare, без фильтрации),
  а обычные `servers` служат только загрузкой (bootstrap), не рабочим откатом;
- **управляемый скрипт отказоустойчивости**, который при сбое очищает
  `use-doh-server`, а после восстановления возвращает его;
- **явный импорт CA** — проверено, что встроенное хранилище доверия не покрывает
  цепочку Cloudflare на 7.23/7.24;
- **статические A-записи для загрузки**, чтобы имя хоста DoH разрешалось, даже
  когда обычный DNS недоступен.

Каждое утверждение в этом README и в `docs/` проверено на реальных устройствах;
там, где поведение отличается, указаны версия и `device-mode`.

## Возможности

| Возможность | Подробности |
|---|---|
| Шифрованный апстрим | один DoH-апстрим с `verify-doh-cert=yes` |
| Откат | второй **DoH**-эндпоинт (Google), когда основной недоступен |
| Проверка | судит ОТВЕТ по содержимому, а не по типу; опрос эндпоинтов через `/tool fetch` |
| Восстановление | автоматический возврат на DoH после успешной проверки состояния |
| Загрузка | статические A-записи для имени хоста DoH |
| Принудительный классический DNS | `dstnat redirect` для UDP/TCP 53 с моста локальной сети |
| Защита резолвера | отбрасывать DNS из WAN, принимать из локальной сети (UDP и TCP) |
| Политика переключения | только `read,write,policy,test` (без `ftp`/`reboot`/`password`) |

## В цифрах

Измерено по опубликованному дереву 2026-10-22 (v0.1.0):

| Что считается | Количество | Откуда измерено |
|---|---|---|
| Скрипты RouterOS | 7 | `routeros/` |
| Примеры конфигураций | 1 | `examples/` |
| Документы | 3 | `docs/` |
| Схемы | 3 | `diagrams/` |
| Проверенных устройств | 5 | `docs/verification.md` |
| Проверенных версий RouterOS | 2 (7.23.1, 7.24.5) | `docs/verification.md` |

## Как это работает

```mermaid
flowchart LR
    Client["LAN client"] -->|"DNS 53"| ForceDNS["force-DNS redirect"]
    ForceDNS --> Resolver["Router resolver"]
    Resolver --> Mode{"DoH healthy?"}
    Mode -->|"yes"| DoH["DoH upstream<br/>verify-doh-cert=yes"]
    Mode -->|"no"| Plain["второй DoH-эндпоинт"]
    Monitor["health monitor 3m"] -->|"flips use-doh-server"| Resolver
    CA["Trusted CA"] -->|"TLS validation"| DoH
    NTP["NTP"] -->|"clock"| CA
```

| Компонент | Задача |
|---|---|
| `00-install-ca.rsc` | якорь доверия для `verify-doh-cert=yes` |
| `01-configure-doh.rsc` | один DoH-апстрим + загрузка + откат |
| `02-security-policies.rsc` | принудительный классический DNS + защита резолвера |
| `03-capsman.rsc` | точечная интеграция с CAPsMAN/DHCP |
| `04-cert-update.rsc` | необязательное обновление CA |
| `05-dns-health-monitor.rsc` | проверка состояния + планировщик переключения |

## Установка

Требования:

- RouterOS **7.20+** (проверено на 7.23.1, 7.24.5);
- синхронизированное время по NTP;
- `device-mode` `advanced` для автоматического **планировщика** переключения.

Быстрый старт (обычный Cloudflare без фильтрации — умолчание с 0.2.0):

```rsc
# 1. Upload certs/cloudflare-doh-ca.crt to the router, then:
/import file-name=00-install-ca.rsc
/import file-name=01-configure-doh.rsc
/import file-name=02-security-policies.rsc
/import file-name=05-dns-health-monitor.rsc
```

Для других провайдеров (Quad9, Google, Cloudflare standard/security) измените
значения в [`routeros/config.example.rsc`](routeros/config.example.rsc).

## Первые шаги

```rsc
/ip dns cache flush
:put [:resolve example.com]     # ожидается 104.20.x / 172.66.x
                                # 8.6.112.0 / 8.47.69.0 — это «пара-заглушка», а не авария:
                                # см. docs/troubleshooting.md §6.10
:put [:resolve pornhub.com]     # с обычным резолвером — реальный адрес;
                                # 0.0.0.0 только с Family/Security
/log print where message~"connection error"
```

## Надёжность и ограничения

| Ситуация | Поведение |
|---|---|
| DoH недоступен | монитор переключается на резервный DoH, проверяет переключение и откатывается, если тот не работает (`error`/`warning`) |
| DoH восстановился | монитор возвращается на основной (`warning`) |
| Недоступны оба эндпоинта | монитор оставляет текущую конфигурацию и один раз пишет `error` |
| Ответы — «пара-заглушка» | монитор пишет это один раз и **не** переключается: второй эндпоинт вернёт ту же пару (§6.10) |
| Клиент использует свой DoH/DoT | **не блокируется** (задокументированное ограничение) |
| `device-mode=home` | планировщик отклоняется; монитор запускается вручную |

### Планировщик отклонён: `not allowed by device-mode`

На устройствах с `device-mode=home` (например, на проверенном здесь RB4011iGS+)
RouterOS отклоняет `/system scheduler add` и `/tool fetch` с сообщением
`not allowed by device-mode`. Это ожидаемое ограничение RouterOS, а не дефект
скрипта: конфигурация DoH и принудительный DNS работают, но монитор
отказоустойчивости можно запускать только вручную. Варианты:

1. оставить `home` и запускать `/system script run DNS_HealthMonitor_Failover` вручную;
2. перейти на `advanced`, чтобы включить планировщик:
   ```rsc
   /system/device-mode/update device-mode=advanced
   ```
   затем подтвердить изменение и перезагрузить устройство.

## Безопасность

- Резолвер отбрасывает DNS из WAN и перенаправляет только классический DNS (53); то, что
  клиент может обойти это своим DoH (443) или DoT (853), описано, а не скрыто.
- Выбор Cloudflare/Quad9/Google означает доверие этого третьего лица к своим запросам;
  DoH скрывает их только от локального участка.
- Загрузка CA — только из доверенного источника; `check-certificate=no` годится лишь там.
- Отчёты об уязвимостях и модель безопасности — в [SECURITY.md](SECURITY.md).

## Требования и совместимость

| Устройство | RouterOS | device-mode | Беспроводной стек | Результат |
|---|---|---|---|---|
| Chateau PRO ax | 7.24.5 | advanced | прежний `/caps-man` (контроллер) | проверено (хаб) |
| cAP ax | 7.24.5 | advanced | прежний `/caps-man` (клиент) | проверено |
| RB4011iGS+ | 7.24.5 | home | — | проверено; планировщик заблокирован |
| hAP ax² | 7.24.5 | advanced | — | проверено |
| RB951Ui-2HnD | 7.24.5 | advanced | — | проверено |
| RB2011UiAS | 7.23.1 | advanced | — | проверено |

## Документация

| Документ | Содержание |
|---|---|
| [`docs/architecture.md`](docs/architecture.md) | обоснование решений и модель угроз |
| [`docs/verification.md`](docs/verification.md) | проверки по подсистемам + чек-лист теста переключения |
| [`docs/troubleshooting.md`](docs/troubleshooting.md) | известные отказы и обходы |
| [`routeros/config.example.rsc`](routeros/config.example.rsc) | все настраиваемые значения |

## Участие

Прочитайте [CONTRIBUTING.md](CONTRIBUTING.md). Вопросы безопасности —
[SECURITY.md](SECURITY.md), никогда не публичный issue.

## Лицензия

[MIT](LICENSE) © 2026 Mikhail Deynekin.
