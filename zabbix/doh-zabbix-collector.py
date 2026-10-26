#!/usr/bin/env python3
"""Сбор состояния DoH и VPN с микротиков и отправка в Zabbix.

Запускается по таймеру на 192.168.31.31 под root. Опрашивает каждый роутер по
SSH (ключ id_mikrotik_agent) и отправляет значения trapper-элементам Zabbix
через zabbix_sender.

На роутерах ничего не меняет: только чтение и три :resolve.
"""
from __future__ import annotations

import re
import subprocess
import sys
import tempfile
import time

SSH = "/usr/bin/ssh"
KEY = "/root/.ssh/id_mikrotik_agent"
USER = "chateau-md"
SENDER = "/usr/local/bin/zabbix_sender"
ZBX_HOST = "127.0.0.1"
ZBX_PORT = "10051"

# Zabbix-хост, адрес, площадка, ожидается ли VPN-туннель с пирами
DEVICES = [
    ("mt-31-1", "192.168.31.1", "офис, шлюз (Chateau PRO ax)", True),
    ("mt-31-2", "192.168.31.2", "офис, точка доступа (cAP ax)", False),
    ("mt-31-9", "192.168.31.9", "тестовый стенд (hAP ax²)", False),
    ("mt-1-1", "192.168.1.1", "площадка Флотская", True),
    ("mt-3-1", "192.168.3.1", "площадка ILAB", True),
    ("mt-4-1", "192.168.4.1", "площадка Нарвская", True),
]

CANARIES = ["example.com", "cdnjs.cloudflare.com", "cdn.tailwindcss.com"]
STUB_PREFIXES = ("8.6.112.", "8.47.69.")

# Одна команда роутеру: DoH (EP/MON/CAN/CLK) и VPN (PEERS/HS/GW).
# Передаётся ssh как единственный аргумент — без промежуточного шелла.
CMD = (
    ':local r ""; '
    ':foreach d in={"example.com";"cdnjs.cloudflare.com";"cdn.tailwindcss.com"} do={'
    ':local ip ""; '
    ':do {:set ip [:tostr [:resolve $d]]} on-error={:set ip ""}; '
    ':set r ($r . $d . "=" . $ip . ";")}; '
    ':put ("EP=" . [/ip dns get use-doh-server]); '
    ':put ("MON=" . [:len [/system scheduler find name="Scheduler_DNS_Health_Check"]]); '
    ':put ("CAN=" . $r); '
    ':put ("CLK=" . [/system clock get date]); '
    ':local n 0; :local m 999999; '
    ':foreach p in=[/interface wireguard peers find] do={'
    ':set n ($n + 1); :local hs [/interface wireguard peers get $p last-handshake]; '
    ':if (($hs != "") and ($hs > 0) and ($hs < $m)) do={:set m $hs}}; '
    ':put ("PEERS=" . $n); :put ("HS=" . $m); '
    ':put ("GW=" . [:len [/ip route find where routing-table="gw535" and active=yes and dst-address="0.0.0.0/0"]])'
)

STATE_CODES = {"healthy": 0, "stub": 1, "dead": 2, "unknown": 3}


def query(ip: str) -> dict:
    cmd = [SSH, "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=accept-new",
           "-o", "ConnectTimeout=8", "-o", "ServerAliveInterval=5",
           "-i", KEY, f"{USER}@{ip}", CMD]
    try:
        res = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
    except subprocess.TimeoutExpired:
        return {"error": "ssh timeout"}
    if res.returncode != 0:
        err = (res.stderr or "").strip().splitlines()
        return {"error": (err[-1][:120] if err else f"ssh rc={res.returncode}")}
    out = {}
    for line in res.stdout.splitlines():
        line = line.strip()
        for key in ("EP", "MON", "CAN", "CLK", "PEERS", "HS", "GW"):
            if line.startswith(key + "="):
                out[key] = line[len(key) + 1:]
                break
    if "CAN" not in out:
        return {"error": "нет ответа от скрипта"}
    return out


def doh_state(data: dict) -> tuple[str, str]:
    if "error" in data:
        return "unknown", data["error"]
    good = bad = 0
    stub = False
    detail = []
    for item in (data.get("CAN") or "").split(";"):
        item = item.strip()
        if not item or "=" not in item:
            continue
        name, _, ip = item.partition("=")
        ip = ip.strip()
        is_stub = any(ip.startswith(p) for p in STUB_PREFIXES)
        stub = stub or is_stub
        if not ip or ip == "0.0.0.0" or is_stub:
            bad += 1
        else:
            good += 1
        detail.append(f"{name}={ip or '-'}{' (stub)' if is_stub else ''}")
    text = "; ".join(detail)
    if good > 0:
        return "healthy", text
    if stub:
        return "stub", text
    return "dead", text


def parse_duration(text: str) -> int:
    """RouterOS отдаёт длительность: 00:01:00, 1d02:03:04, 5s, 3m20s.

    Возвращает секунды; при неразборе — 999999 (считаем «очень давно»).
    """
    text = (text or "").strip()
    if not text:
        return 999999
    if re.fullmatch(r"\d+", text):
        return int(text)
    m = re.fullmatch(r"(?:(\d+)w)?(?:(\d+)d)?(?:(\d+):(\d+):(\d+))", text)
    if m:
        w, d, h, mi, s = (int(x or 0) for x in m.groups())
        return ((w * 7 + d) * 24 + h) * 3600 + mi * 60 + s
    if re.fullmatch(r"(?:\d+[wdhms])+", text):
        units = {"w": 604800, "d": 86400, "h": 3600, "m": 60, "s": 1}
        return sum(int(n) * units[u] for n, u in re.findall(r"(\d+)([wdhms])", text))
    return 999999


def vpn_state(data: dict, expect_vpn: bool) -> tuple[int, str]:
    """0 ок, 1 деградация, 2 авария, 3 нет данных."""
    if "error" in data:
        return 3, data["error"]
    if not expect_vpn:
        return 0, "туннели не требуются"
    try:
        peers = int((data.get("PEERS") or "0").strip())
    except ValueError:
        return 3, "не разобран счётчик пиров"
    hs = parse_duration(data.get("HS", ""))
    if peers == 0:
        return 2, "нет пиров wireguard"
    if hs >= 900:
        return 2, f"рукопожатий нет {hs} с"
    if hs >= 300:
        return 1, f"рукопожатие устарело ({hs} с)"
    return 0, f"пиров {peers}, рукопожатие {hs} с"


def send(host: str, values: list[tuple[str, str]]) -> bool:
    """Отправить пачку значений. zabbix_sender принимает много ключей только файлом."""
    cmd = [SENDER, "-z", ZBX_HOST, "-p", ZBX_PORT, "-i", "-"]
    payload = "".join(f'"{host}" {key} "{val}"\n' for key, val in values)
    try:
        res = subprocess.run(cmd, input=payload, capture_output=True, text=True, timeout=30)
    except subprocess.TimeoutExpired:
        return False
    ok = res.returncode == 0 and "failed: 0" in (res.stdout or "")
    if not ok:
        print(f"  ! {host}: sender rc={res.returncode} {(res.stdout or '').strip()} {(res.stderr or '').strip()[:120]}")
    return ok


def main() -> int:
    print(f"[{time.strftime('%H:%M:%S')}] сбор DoH и VPN")
    sent = 0
    for host, ip, site, expect_vpn in DEVICES:
        data = query(ip)
        dstate, ddetail = doh_state(data)
        vstate, vdetail = vpn_state(data, expect_vpn)
        endpoint = (data.get("EP") or "").strip() or "-"
        monitor = data.get("MON", "0").strip()
        values = [
            ("doh.state", str(STATE_CODES[dstate])),
            ("doh.endpoint", endpoint[:255]),
            ("doh.canary", (ddetail or "-")[:1000]),
            ("doh.monitor", monitor if monitor in ("0", "1") else "0"),
            ("vpn.state", str(vstate)),
            ("vpn.peers", (data.get("PEERS") or "0").strip()[:10] or "0"),
            ("vpn.handshake", str(parse_duration(data.get("HS", "")))),
            ("vpn.detail", (vdetail or "-")[:255]),
        ]
        ok = send(host, values)
        sent += 1 if ok else 0
        print(f"  {host:<10} doh={dstate:<7} vpn={vstate} ({vdetail[:44]})")
    print(f"отправлено {sent} из {len(DEVICES)}")
    return 0 if sent == len(DEVICES) else 1


if __name__ == "__main__":
    sys.exit(main())
