# Мониторинг DoH и VPN флота микротиков в Zabbix

Схема: коллектор на `192.168.31.31` раз в 2 минуты опрашивает каждый роутер по SSH
и отправляет значения trapper-элементам Zabbix. Сами роутеры ничего не шлют —
на `mt-flotskaya` это невозможно (`device-mode=home`, `fetch` и `scheduler` закрыты).

```
192.168.31.31 (hp-debian)
  doh-zabbix-collector.timer  ->  doh-zabbix-collector.service
        |  ssh chateau-md@<роутер>   (ключ /root/.ssh/id_mikrotik_agent)
        v
  RouterOS: :resolve трех канареек + /ip dns get use-doh-server
            + /interface wireguard peers last-handshake
        |
        v  zabbix_sender 127.0.0.1:10051
  Zabbix 8.0 (https://22877.ru) trapper-элементы -> триггеры -> дерево сервисов
```

## 1. Что снимается

| Ключ элемента | Тип | Смысл |
|---|---|---|
| `doh.state` | число | 0 здоров, 1 пара-заглушка, 2 не отвечает, 3 нет данных |
| `doh.endpoint` | текст | текущий `/ip dns use-doh-server` |
| `doh.canary` | текст | ответы на `example.com`, `cdnjs.cloudflare.com`, `cdn.tailwindcss.com` |
| `doh.monitor` | число | установлен ли на устройстве скрипт-монитор DoH |
| `vpn.state` | число | 0 ок, 1 деградация, 2 авария, 3 нет данных |
| `vpn.peers` | число | количество пиров wireguard |
| `vpn.handshake` | число (с) | возраст самого свежего рукопожатия |
| `vpn.detail` | текст | пояснение словами |

Классификация VPN: нет пиров — авария; рукопожатий нет больше 15 минут — авария;
старше 5 минут — деградация; иначе ок. Устройства без туннелей (`mt-31-2`, `mt-31-9`)
всегда ок — туннели им не нужны.

## 2. Триггеры

| Имя | Выражение | Важность |
|---|---|---|
| DoH не работает | `last(/<host>/doh.state)=2` | Disaster |
| Нет данных о состоянии DoH | `nodata(/<host>/doh.state,15m)=1` | Warning |
| VPN-туннель лежит | `last(/<host>/vpn.state)=2` | Disaster |
| VPN-туннель нестабилен | `last(/<host>/vpn.state)=1` | Warning |
| Нет данных о состоянии VPN | `nodata(/<host>/vpn.state,15m)=1` | Warning |

Триггера «DoH отдаёт пару-заглушку» нет намеренно: для сетей этого флота пара
`8.6.112.x / 8.47.69.x` — штатный ответ Cloudflare (см. `docs/troubleshooting.md` §6.10),
и триггер висел бы постоянно. Состояние видно в `doh.state` (=1) и в `doh.canary`.

## 3. Дерево сервисов

```
DoH на микротиках
  ├── DoH на микротиках / mt-31-1     (теги: service=doh, device=mt-31-1)
  ├── … по одному на устройство
VPN                       (бывший «VPN Гжатская»)
  ├── Транспорт / Туннель / Транспорт / …
  └── Микротики
        ├── Микротики / mt-31-1       (теги: service=vpn, device=mt-31-1)
        └── … по одному на устройство
```

Правила Zabbix 8.0, на которые пришлось наткнуться:

* у сервиса не может быть одновременно `problem_tags` и детей — родитель агрегирует
  детей, лист получает статус по меткам;
* агрегация родителей работает только при `algorithm=2` («проблема, если хотя бы
  у одного ребёнка»); при `algorithm=1` одна авария наверх не поднимается;
* статус сервиса `-1` в API — это **OK**, а не «нет данных»; проверять аварию надо
  по `status>=1`;
* IE: `parentid` и параметр `auth` в JSON-RPC удалены: токен идёт заголовком
  `Authorization: Bearer`, иерархия — массивом `parents`;
* подписи значений (`valuemap`) принадлежат хосту, общих нет.

## 4. Установка с нуля

```bash
# 1. объекты в Zabbix (идемпотентно)
python3 doh-zabbix-setup.py

# 2. коллектор и таймер на 192.168.31.31
install -m 755 doh-zabbix-collector.py /usr/local/bin/
# юниты — в репозитории: systemd/doh-zabbix-collector.{service,timer}
systemctl daemon-reload && systemctl enable --now doh-zabbix-collector.timer

# 3. проверка
systemctl list-timers doh-zabbix-collector.timer
journalctl -u doh-zabbix-collector.service -n 10
```

Требования на сервере: `zabbix_sender` (`/usr/local/bin/zabbix_sender`), ключ
`/root/.ssh/id_mikrotik_agent` с доступом `chateau-md@` на каждый роутер,
в `known_hosts` — актуальные ключи хостов (иначе ssh откажет).

## 5. Проверка, что мониторинг живой

```bash
# значения доходят
printf '"mt-31-1" vpn.state "0"\n' | zabbix_sender -z 127.0.0.1 -i -

# срабатывание и восстановление (таймер на время проверки остановить,
# иначе он перезапишет значение через 2 минуты)
systemctl stop doh-zabbix-collector.timer
printf '"mt-31-1" vpn.state "2"\n' | zabbix_sender -z 127.0.0.1 -i -
# в Zabbix: проблема «VPN-туннель лежит», сервис mt-31-1 -> авария ->
#           «Микротики» -> «VPN»
printf '"mt-31-1" vpn.state "0"\n' | zabbix_sender -z 127.0.0.1 -i -
systemctl start doh-zabbix-collector.timer
```

Проверено 26.10.2026: событие `ПРОБЛЕМА` в 14:25:23, `закрыто` в 14:25:27;
агрегация ребёнок → «Микротики» → «VPN» подтверждена.
