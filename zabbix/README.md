# Zabbix monitoring for the DoH and VPN state of a MikroTik fleet

Русская версия: [README.ru.md](README.ru.md).

Layout: a collector on `192.168.31.31` (hp-debian) asks every router over SSH once
every two minutes and pushes the values into Zabbix trapper items. The routers
themselves send nothing — on a `device-mode=home` box that is impossible
(`fetch` and `scheduler` are closed there).

```
192.168.31.31 (hp-debian)
  doh-zabbix-collector.timer  ->  doh-zabbix-collector.service
        |  ssh chateau-md@<router>   (key /root/.ssh/id_mikrotik_agent)
        v
  RouterOS: :resolve of three canaries + /ip dns get use-doh-server
            + /interface wireguard peers last-handshake
        |
        v  zabbix_sender 127.0.0.1:10051
  Zabbix 8.0 trapper items -> triggers -> service trees
```

Measured from the code in this directory: 6 devices, 8 items, 5 triggers,
2 service trees, a 2-minute timer (`OnBootSec=90`, `OnUnitActiveSec=2min`,
`AccuracySec=10s`).

## 1. Devices

| Host | Address | Role | VPN peers expected |
|---|---|---|---|
| `mt-31-1` | 192.168.31.1 | office, gateway (Chateau PRO ax) | yes |
| `mt-31-2` | 192.168.31.2 | office, access point (cAP ax) | no |
| `mt-31-9` | 192.168.31.9 | test bench (hAP ax²) | no |
| `mt-1-1` | 192.168.1.1 | Flotskaya site | yes |
| `mt-3-1` | 192.168.3.1 | ILAB site | yes |
| `mt-4-1` | 192.168.4.1 | Narvskaya site | yes |

The list lives in `DEVICES` in both scripts; the two lists must stay identical.

## 2. What is collected

| Item key | Type | Meaning |
|---|---|---|
| `doh.state` | number | 0 healthy, 1 stub pair, 2 no usable answer, 3 no data |
| `doh.endpoint` | text | the current `/ip dns use-doh-server` value |
| `doh.canary` | text | answers for `example.com`, `cdnjs.cloudflare.com`, `cdn.tailwindcss.com` |
| `doh.monitor` | number | whether the DoH monitor script exists on the device |
| `vpn.state` | number | 0 ok, 1 degraded, 2 down, 3 no data |
| `vpn.peers` | number | number of WireGuard peers |
| `vpn.handshake` | number (s) | age of the freshest handshake, seconds |
| `vpn.detail` | text | the classification in words |

The DoH classification reuses the monitor's own rule: an empty answer,
`0.0.0.0`, or a prefix of `8.6.112.` / `8.47.69.` counts as unusable, and the
answer set is called `stub` when the stub pair is present. The collector does not
invent its own thresholds — it ships the same canary list and the same stub
prefixes as `routeros/05-dns-health-monitor.rsc`.

VPN classification: no peers means down; the freshest handshake older than
900 s (15 min) means down; older than 300 s (5 min) means degraded; otherwise ok.
Devices without tunnels (`mt-31-2`, `mt-31-9`) are always ok — they need none.

## 3. Triggers

| Name | Expression | Severity |
|---|---|---|
| DoH не работает | `last(/{host}/doh.state)=2` | Disaster |
| Нет данных о состоянии DoH | `nodata(/{host}/doh.state,15m)=1` | Warning |
| VPN-туннель лежит | `last(/{host}/vpn.state)=2` | Disaster |
| VPN-туннель нестабилен | `last(/{host}/vpn.state)=1` | Warning |
| Нет данных о состоянии VPN | `nodata(/{host}/vpn.state,15m)=1` | Warning |

Five triggers, all exclusive (`=2`, not `>=2`), so a single incident opens one
problem and a quiet `0` closes it. The expressions are quoted from `TRIGGERS` in
`doh-zabbix-setup.py`.

There is deliberately no trigger for "DoH answers with the stub pair": the
collector reports it as `doh.state=1` and in `doh.canary`, but for some networks
that pair is Cloudflare's normal answer (`docs/troubleshooting.md` §6.10 of the
main repository), and such a trigger would stay open permanently.

## 4. Service trees

```
DoH на микротиках
  ├── DoH на микротиках / mt-31-1     (tags: service=doh, device=mt-31-1)
  ├── … one child per device
VPN                       (formerly «VPN Гжатская», renamed by the script)
  ├── Микротики
        ├── Микротики / mt-31-1       (tags: service=vpn, device=mt-31-1)
        └── … one child per device
```

Two trees: `DoH на микротиках` and `VPN` → `Микротики`, each with one leaf per
router. Leaves carry problem tags; parents aggregate them.

Zabbix 8.0 rules that had to be discovered the hard way:

* a service cannot carry both `problem_tags` and children — a parent aggregates
  children, a leaf takes its status from tags;
* parent aggregation only works with `algorithm=2` ("problem if at least one child
  has a problem"); with `algorithm=1` a child's disaster does not propagate up;
* service status `-1` in the API means **OK**, not "no data"; test for an
  incident with `status>=1`;
* in the API, `parentid` and the `auth` JSON-RPC parameter are gone: the token
  travels in the `Authorization` header, and the hierarchy is passed as a
  `parents` array;
* value maps belong to a host; Zabbix 8 has no shared ones.

## 5. Install from scratch

```bash
# 1. objects in Zabbix (idempotent: existing hosts are found by interface address,
#    its own earlier duplicate hosts are removed)
python3 doh-zabbix-setup.py

# 2. collector and timer on 192.168.31.31
install -m 755 doh-zabbix-collector.py /usr/local/bin/
# units are in the repository: systemd/doh-zabbix-collector.{service,timer}
systemctl daemon-reload && systemctl enable --now doh-zabbix-collector.timer

# 3. check
systemctl list-timers doh-zabbix-collector.timer
journalctl -u doh-zabbix-collector.service -n 10
```

Requirements on the server: `zabbix_sender` (`/usr/local/bin/zabbix_sender`), the
key `/root/.ssh/id_mikrotik_agent` accepted as `chateau-md@` on every router, and
current host keys in `known_hosts` (otherwise ssh refuses).

Credentials are **not** stored in the repository any more: `doh-zabbix-setup.py`
takes the Zabbix API login from the environment (`ZBX_USER`, `ZBX_PASSWORD`) and
stops with a clear message when they are missing. Storing a password as a literal
in this file was a defect — see `SECURITY.md` of the main repository.

## 6. Proving that monitoring is alive

```bash
# values arrive
printf '"mt-31-1" vpn.state "0"\n' | zabbix_sender -z 127.0.0.1 -i -

# trigger opens and closes (stop the timer during the test, otherwise it
# overwrites the value within two minutes)
systemctl stop doh-zabbix-collector.timer
printf '"mt-31-1" vpn.state "2"\n' | zabbix_sender -z 127.0.0.1 -i -
# in Zabbix: problem «VPN-туннель лежит», service mt-31-1 -> disaster ->
#            «Микротики» -> «VPN»
printf '"mt-31-1" vpn.state "0"\n' | zabbix_sender -z 127.0.0.1 -i -
systemctl start doh-zabbix-collector.timer
```

Checked on 2026-10-26: a problem event at 14:25:23 and `resolved` at 14:25:27;
child → «Микротики» → «VPN» aggregation confirmed.
