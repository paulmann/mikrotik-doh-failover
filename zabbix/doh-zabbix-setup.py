"""Настройка Zabbix: мониторинг DoH и VPN на микротиках.

Идемпотентно. Использует УЖЕ существующие хосты микротиков (ищет по адресу
интерфейса), поэтому дублей не создаёт. Свои временные хосты mt-hub… (созданные
раньше по ошибке) удаляет.

Сервисы:
  DoH на микротиках            -> по одному ребёнку на устройство
  VPN (было «VPN Гжатская»)    -> Микротики -> по одному ребёнку на устройство
"""
from __future__ import annotations

import json
import ssl
import sys
import urllib.request

API = "https://22877.ru/api_jsonrpc.php"
USER = "md"
PASSWORD = "Glevitumi5"

GROUP = "MikroTik DoH"
DOH_ROOT = "DoH на микротиках"
VPN_ROOT_OLD = "VPN Гжатская"
VPN_ROOT = "VPN"
VPN_GROUP = "Микротики"

# адрес, площадка, ожидается ли туннель
DEVICES = [
    ("192.168.31.1", "офис, шлюз (Chateau PRO ax)", True),
    ("192.168.31.2", "офис, точка доступа (cAP ax)", False),
    ("192.168.31.9", "тестовый стенд (hAP ax²)", False),
    ("192.168.1.1", "площадка Флотская", True),
    ("192.168.3.1", "площадка ILAB", True),
    ("192.168.4.1", "площадка Нарвская", True),
]

# хосты-дубли, созданные ранее этим же скриптом (удаляются)
DUPLICATES = ["mt-hub", "mt-cap", "mt-test", "mt-flotskaya", "mt-ilab", "mt-narvskaya"]

CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE
TOKEN = None
RID = 0


def call(method: str, params):
    global RID
    RID += 1
    payload = {"jsonrpc": "2.0", "method": method, "params": params, "id": RID}
    headers = {"Content-Type": "application/json-rpc"}
    if TOKEN:
        headers["Authorization"] = f"Bearer {TOKEN}"   # Zabbix 8: только заголовок
    req = urllib.request.Request(API, data=json.dumps(payload).encode(), headers=headers)
    with urllib.request.urlopen(req, context=CTX, timeout=30) as resp:
        out = json.loads(resp.read().decode())
    if "error" in out:
        err = out["error"]
        raise RuntimeError(f"{method}: {err.get('data') or err.get('message')}")
    return out["result"]


def login():
    global TOKEN
    TOKEN = call("user.login", {"username": USER, "password": PASSWORD})
    print("вход выполнен")


def ensure_group() -> str:
    found = call("hostgroup.get", {"filter": {"name": GROUP}, "output": ["groupid"]})
    if found:
        return found[0]["groupid"]
    return call("hostgroup.create", {"name": GROUP})["groupids"][0]


def host_by_ip() -> dict[str, tuple[str, str]]:
    hosts = call("host.get", {"output": ["hostid", "host", "name"], "selectInterfaces": ["ip"]})
    out = {}
    for h in hosts:
        for iface in h.get("interfaces", []):
            if iface.get("ip"):
                out.setdefault(iface["ip"], (h["hostid"], h["host"]))
    return out


def drop_duplicates():
    found = call("host.get", {"filter": {"host": DUPLICATES}, "output": ["hostid", "host"]})
    if not found:
        return
    ids = [h["hostid"] for h in found]
    names = ", ".join(h["host"] for h in found)
    call("host.delete", ids)
    print(f"удалены свои дубли: {names}")


ITEMS = [
    ("doh.state", 3, "Состояние DoH, 0 здоров 1 заглушка 2 нет ответа 3 нет данных", ""),
    ("doh.endpoint", 4, "Активный DoH-эндпоинт", ""),
    ("doh.canary", 4, "Ответы на контрольные имена", ""),
    ("doh.monitor", 3, "Скрипт-монитор DoH установлен (1/0)", ""),
    ("vpn.state", 3, "Состояние VPN, 0 ок 1 деградация 2 авария 3 нет данных", ""),
    ("vpn.peers", 3, "Количество wireguard-пиров", ""),
    ("vpn.handshake", 3, "Возраст самого свежего рукопожатия, секунд", "s"),
    ("vpn.detail", 4, "Пояснение состояния VPN", ""),
]


def ensure_item(hostid: str, key: str, vtype: int, descr: str, units: str,
                valuemapid: str | None = None) -> str | None:
    existing = call("item.get", {"hostids": hostid, "filter": {"key_": key}, "output": ["itemid"]})
    if existing:
        # у существующих добираем подпись значений (могли создать раньше без неё)
        if valuemapid:
            call("item.update", {"itemid": existing[0]["itemid"], "valuemapid": valuemapid})
        return existing[0]["itemid"]
    params = {
        "hostid": hostid, "name": descr.split(",")[0][:120], "key_": key,
        "type": 2, "value_type": vtype, "units": units, "description": descr, "delay": "0",
    }
    if valuemapid:
        params["valuemapid"] = valuemapid
    return call("item.create", params)["itemids"][0]


def ensure_valuemap(hostid: str, name: str, pairs: list[tuple[str, str]]) -> str:
    """В Zabbix 8 подписи значений принадлежат хосту, общих нет."""
    found = call("valuemap.get", {"hostids": [hostid], "filter": {"name": name},
                                 "output": ["valuemapid"]})
    if found:
        return found[0]["valuemapid"]
    res = call("valuemap.create", {
        "hostid": hostid,
        "name": name,
        "mappings": [{"value": v, "newvalue": t} for v, t in pairs],
    })
    return res["valuemapids"][0]


TRIGGERS = [
    ("DoH не работает", "last(/{host}/doh.state)=2", 4, "service", "doh",
     "Резолвер не отдал ни одного пригодного адреса. Смотреть /log print where message~\"DNS monitor\" на устройстве."),
    ("Нет данных о состоянии DoH", "nodata(/{host}/doh.state,15m)=1", 2, "service", "doh",
     "Коллектор не присылает значения 15 минут: systemctl status doh-zabbix-collector.timer на 192.168.31.31."),
    ("VPN-туннель лежит", "last(/{host}/vpn.state)=2", 4, "service", "vpn",
     "Нет пиров wireguard или рукопожатий нет дольше 15 минут. Проверить /interface wireguard peers print и доступность concentrator'а."),
    ("VPN-туннель нестабилен", "last(/{host}/vpn.state)=1", 2, "service", "vpn",
     "Рукопожатие старше 5 минут: туннель переустанавливается или теряет пакеты."),
    ("Нет данных о состоянии VPN", "nodata(/{host}/vpn.state,15m)=1", 2, "service", "vpn",
     "Коллектор не присылает значения 15 минут: systemctl status doh-zabbix-collector.timer на 192.168.31.31."),
]


def ensure_trigger(host: str, hostid: str, name: str, expr: str, prio: int,
                   tag: str, tagval: str, comment: str) -> None:
    found = call("trigger.get", {"hostids": hostid, "filter": {"description": name}, "output": ["triggerid"]})
    if found:
        return
    call("trigger.create", {
        "description": name,
        "expression": expr.format(host=host),
        "priority": prio,
        "comments": comment,
        "tags": [{"tag": tag, "value": tagval}, {"tag": "device", "value": host}],
    })


def ensure_service(name, parents, tags, algorithm, weight, descr) -> str:
    found = call("service.get", {"filter": {"name": name}, "output": ["serviceid"]})
    if found:
        return found[0]["serviceid"]
    params = {
        "name": name, "algorithm": algorithm, "weight": weight,
        "propagation_rule": 0, "propagation_value": 0, "sortorder": 0,
        "description": descr, "problem_tags": tags,
    }
    if parents:
        params["parents"] = [{"serviceid": p} for p in parents]
    return call("service.create", params)["serviceids"][0]


def rename_vpn_root() -> str | None:
    found = call("service.get", {"filter": {"name": VPN_ROOT_OLD}, "output": ["serviceid"]})
    if found:
        sid = found[0]["serviceid"]
        call("service.update", {"serviceid": sid, "name": VPN_ROOT})
        print(f"сервис «{VPN_ROOT_OLD}» переименован в «{VPN_ROOT}»")
        return sid
    found = call("service.get", {"filter": {"name": VPN_ROOT}, "output": ["serviceid"]})
    return found[0]["serviceid"] if found else None


def main() -> int:
    login()
    ensure_group()
    drop_duplicates()

    by_ip = host_by_ip()
    hosts = []
    for ip, descr, expect_vpn in DEVICES:
        if ip not in by_ip:
            print(f"  ! нет хоста с адресом {ip} — пропуск")
            continue
        hostid, host = by_ip[ip]
        hosts.append((host, hostid, expect_vpn))
        maps = {
            "doh.state": ensure_valuemap(hostid, "DoH state", [
                ("0", "здоров"), ("1", "пара-заглушка"), ("2", "не отвечает"), ("3", "нет данных")]),
            "vpn.state": ensure_valuemap(hostid, "VPN state", [
                ("0", "ок"), ("1", "деградация"), ("2", "авария"), ("3", "нет данных")]),
        }
        for key, vtype, d, units in ITEMS:
            ensure_item(hostid, key, vtype, d, units, maps.get(key))
        for name, expr, prio, tag, tagval, comment in TRIGGERS:
            ensure_trigger(host, hostid, name, expr, prio, tag, tagval, comment)
        print(f"  {host:<10} ({ip}) элементы и триггеры на месте")

    # --- DoH ---
    doh_root = ensure_service(DOH_ROOT, None, [], 1, 1,
                              "DoH на всех микротиках: состояние снимает коллектор на 192.168.31.31.")
    for host, _hid, _exp in hosts:
        ensure_service(f"{DOH_ROOT} / {host}", [doh_root],
                       [{"tag": "service", "value": "doh", "operator": 0},
                        {"tag": "device", "value": host, "operator": 0}],
                       1, 1, f"DoH на {host}")
    print(f"  DoH: корень + {len(hosts)} детей")

    # --- VPN ---
    vpn_root = rename_vpn_root()
    if vpn_root is None:
        vpn_root = ensure_service(VPN_ROOT, None, [], 1, 0,
                                  "VPN: транспорт, туннели, доступность и состояние микротиков.")
        print(f"  создан корневой сервис «{VPN_ROOT}»")
    vpn_group = ensure_service(VPN_GROUP, [vpn_root], [], 1, 0,
                               "Состояние VPN на каждом микротике.")
    for host, _hid, _exp in hosts:
        ensure_service(f"{VPN_GROUP} / {host}", [vpn_group],
                       [{"tag": "service", "value": "vpn", "operator": 0},
                        {"tag": "device", "value": host, "operator": 0}],
                       1, 1, f"VPN на {host}")
    print(f"  VPN: корень «{VPN_ROOT}» → {VPN_GROUP} → {len(hosts)} детей")
    return 0


if __name__ == "__main__":
    sys.exit(main())
