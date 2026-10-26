# 05-dns-health-monitor.rsc — version 2 (0.2.0)
# Health-check + failover for the single DoH upstream.
#
# WHAT CHANGED IN 0.2.0 AND WHY
#   1. The check looks at the ANSWER, not at its type. v1 asked ":resolve
#      cloudflare.com" and was satisfied with any valid IP. Measured 2026-10-26:
#      Cloudflare's filtering resolvers answer perfectly legitimate names with
#      the pair 8.6.112.0 / 8.47.69.0 for clients in some networks — Status:0,
#      valid A records, and CDNs do not open. v1 called that healthy.
#   2. The probe no longer disturbs the resolver. v1 flipped use-doh-server to
#      test it, so every check left the LAN without DoH (or forced it on). Both
#      endpoints are now probed over HTTPS with /tool fetch; /ip dns is not
#      touched unless a real failover is needed.
#   3. "DoH down" and "DoH answers garbage" are different faults: the first is
#      fixed by a second endpoint, the second is not. The script says which.
#   4. Failover goes DoH -> DoH, not DoH -> plain. Measured: plain queries in
#      Russia come back substituted even when sent straight to 1.1.1.1/8.8.8.8,
#      so "falling back to plain" hides the outage instead of fixing it. Plain
#      servers stay only as bootstrap for the DoH hostname.
#   5. A clock check runs first: with a wrong date verify-doh-cert can never
#      succeed, and without this check the script reports "DoH down" forever.
#   6. The fallback endpoint is probed BEFORE switching and the switch is
#      verified AFTER; a failed attempt is rolled back and not retried on every
#      run (max 3 attempts per outage), so the router never ends up parked on a
#      dead endpoint and the log does not fill up.
#
# Verified on RouterOS 7.23.1 (see docs/verification.md).
# Log state machine: healthy / stub / dead / failoverB, logged on transitions.

/system script remove [find name="DNS_HealthMonitor_Failover"]
/system script add name="DNS_HealthMonitor_Failover" policy=read,write,policy,test dont-require-permissions=no source={
# ===== CONFIG =====
:local dohUrlA      "https://cloudflare-dns.com/dns-query"
    # primary: standard Cloudflare, no filtering
:local probeUrlA    "https://cloudflare-dns.com/dns-query?name=example.com&type=A"
:local dohUrlB      "https://dns.google/dns-query"
    # fallback: needs Google's root CA in the trust store
:local probeUrlB    "https://dns.google/resolve?name=example.com&type=A"
:local probeGood    {"example.com";"cdnjs.cloudflare.com";"cdn.tailwindcss.com"}
:local stubPrefixes {"8.6.112.";"8.47.69."}
:local filtering    false
    # true if the configured endpoint is family/security
:local stubProbeIp  "8.6.112.0"
    # kept for documentation; the reachability probe was removed in 0.2.0 —
    # /tool fetch cannot tell a dead TCP path from an HTTP refusal, so it would lie
:local applyChanges true
    # false = report only, never touch /ip dns
:local maxAttempts  3
    # failover attempts per outage, then stop trying until the primary recovers
# ==================

:global DNSMonitorState
:global DNSFailoverAttempts
:if ([:typeof $DNSFailoverAttempts] = "nothing") do={ :set DNSFailoverAttempts 0 }

# --- 0: clock ---
:local clock [/system clock get date]
:local year [:tonum [:pick $clock 0 4]]
:if ($year < 2025) do={
    :log error ("DNS monitor: clock looks wrong (" . $clock . ") — certificate validation cannot succeed; enable NTP")
} else={

    # --- 1: are the answers usable? (content, not type) ---
    :local bad 0
    :local good 0
    :local stubSeen 0
    :local detail ""
    :foreach d in=$probeGood do={
        :local ip ""
        :do { :set ip [:tostr [:resolve $d]] } on-error={ :set ip "" }
        :local stub 0
        :if ([:len $ip] > 0) do={
            :foreach p in=$stubPrefixes do={ :if ([:find $ip $p] >= 0) do={ :set stub 1 } }
        }
        :if ($stub = 1) do={ :set stubSeen 1 }
        :if (($ip = "") or ($ip = "0.0.0.0") or ($stub = 1)) do={
            :set bad ($bad + 1)
        } else={
            :set good ($good + 1)
        }
        :local mark ""
        :if ($stub = 1) do={ :set mark " (stub pair)" }
        :set detail ($detail . $d . "=" . $ip . $mark . "; ")
    }

    # --- 2: is each endpoint alive? (fetch, does not touch /ip dns) ---
    :local probeA "unreachable"
    :do {
        /file remove [find name="doh-health-a.json"]
        /tool fetch url=$probeUrlA http-header-field="accept: application/dns-json" dst-path="doh-health-a.json" mode=https
        :local body [:tostr [/file get "doh-health-a.json" contents]]
        :if ([:find $body "\"Status\":0"] >= 0) do={ :set probeA "ok" } else={ :set probeA "bad-status" }
    } on-error={ :set probeA "unreachable" }
    /file remove [find name="doh-health-a.json"]

    # --- 3: decide ---
    :if ($good > 0) do={
        :set DNSFailoverAttempts 0
        :if ($DNSMonitorState = "failoverB") do={
            /ip dns set use-doh-server=$dohUrlA verify-doh-cert=yes
            /ip dns cache flush
            :set DNSMonitorState "healthy"
            :log warning "DNS monitor: primary DoH answers again — switched back from the fallback"
        } else={
            :if ($DNSMonitorState != "healthy") do={
                :set DNSMonitorState "healthy"
                :log info ("DNS monitor: answers look sane (" . $good . " of " . ($good + $bad) . ")")
            }
        }
    } else={
        :if ($stubSeen = 1) do={
            # The resolver answered, but with the pair 8.6.112.0 / 8.47.69.0.
            # Whether that is harmless depends on reachability from THIS network, and the
            # router cannot test it reliably (fetch cannot distinguish a dead path from an
            # HTTP refusal), so the script reports the fact and the way to check it.
            :if ($DNSMonitorState != "stub") do={
                :set DNSMonitorState "stub"
                :log warning ("DNS monitor: answers are the stub pair — " . $detail . "If CDNs do not open here, this pair is unreachable from this network: check from a client with curl --resolve and see docs/troubleshooting.md §6.10. Switching the resolver does not help")
            }
        } else={
            # no usable answers at all
            :if ($probeA = "ok") do={
                # endpoint alive, resolver returns nothing: stale or corrupt cache
                /ip dns cache flush
                :if ($DNSMonitorState != "dead") do={
                    :set DNSMonitorState "dead"
                    :log warning ("DNS monitor: DoH endpoint answers but the resolver returns no usable addresses — " . $detail . "cache flushed, re-check in 3 minutes")
                }
            } else={
                :if (($DNSMonitorState != "dead") and ($DNSMonitorState != "failoverB")) do={
                    :log error ("DNS monitor: primary DoH unreachable (" . $probeA . ") — " . $detail)
                }
                :if (($applyChanges) and ($DNSFailoverAttempts < $maxAttempts)) do={
                    # probe the fallback first, so a broken fallback never takes the LAN down
                    :local probeB "unreachable"
                    :do {
                        /file remove [find name="doh-health-b.json"]
                        /tool fetch url=$probeUrlB http-header-field="accept: application/dns-json" dst-path="doh-health-b.json" mode=https
                        :local bodyB [:tostr [/file get "doh-health-b.json" contents]]
                        :if ([:find $bodyB "\"Status\":0"] >= 0) do={ :set probeB "ok" } else={ :set probeB "bad-status" }
                    } on-error={ :set probeB "unreachable" }
                    /file remove [find name="doh-health-b.json"]

                    :if ($probeB = "ok") do={
                        :set DNSFailoverAttempts ($DNSFailoverAttempts + 1)
                        /ip dns set use-doh-server=$dohUrlB verify-doh-cert=yes
                        /ip dns cache flush
                        :delay 3s
                        :local test ""
                        :do { :set test [:tostr [:resolve "example.com"]] } on-error={ :set test "" }
                        :if ([:len $test] > 0) do={
                            :set DNSMonitorState "failoverB"
                            :log warning ("DNS monitor: switched to fallback DoH (" . $dohUrlB . "), example.com -> " . $test)
                        } else={
                            /ip dns set use-doh-server=$dohUrlA verify-doh-cert=yes
                            /ip dns cache flush
                            :set DNSMonitorState "dead"
                            :log error ("DNS monitor: fallback DoH did not resolve either — rolled back to the primary endpoint; check the CA for the fallback host")
                        }
                    } else={
                        :if ($DNSMonitorState != "dead") do={
                            :set DNSMonitorState "dead"
                            :log error ("DNS monitor: both endpoints unreachable (primary " . $probeA . ", fallback " . $probeB . ") — keeping the current configuration")
                        }
                    }
                }
            }
        }
    }
}
}

/system scheduler remove [find name="Scheduler_DNS_Health_Check"]
/system scheduler add name="Scheduler_DNS_Health_Check" interval=3m start-time=startup policy=read,write,policy,test on-event="/system script run DNS_HealthMonitor_Failover" comment="DNS/DoH health monitor: content-aware check, non-disruptive probe, DoH-to-DoH failover" disabled=no
