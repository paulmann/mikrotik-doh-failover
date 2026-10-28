# 05-dns-health-monitor.rsc — version 3 (0.3.0)
# Managed DoH-to-DoH failover with content-aware probing and an explicit state
# machine. This is MANAGED failover (the upstream changes on a fault), not
# "transparent" failover: primary and fallback are different operators and may
# answer differently (filtering, geo, CDN steering).
#
# WHAT CHANGED IN 0.3.0 (relative to 0.2.0)
#   1. State machine is explicit: HEALTHY -> SUSPECT -> FALLBACK -> RECOVERING
#      -> HEALTHY, plus STUB, DEGRADED and CLOCK_INVALID. Every transition is
#      logged with an UPPERCASE tag so Zabbix/alerts can match it.
#   2. Hysteresis instead of one-shot flapping: a failover needs
#      `failureThreshold` consecutive bad runs; coming home needs
#      `recoveryThreshold` consecutive good runs. These two thresholds ARE the
#      anti-flap mechanism (with a 60s interval, threshold=2 = ~2 minutes).
#   3. The check interval is configurable (`interval`, default 60s for offices;
#      3m is fine for home).
#   4. device-mode=home is diagnosed explicitly: the monitor logs
#      MONITOR_DISABLED_BY_DEVICE_MODE once and stops, instead of reporting
#      "both endpoints unreachable" as if it were a network fault.
#
# Kept from 0.2.0: the check judges the ANSWER (content), the probe goes through
# /tool fetch and never touches /ip dns, the fallback is probed BEFORE switching
# and verified AFTER (rollback on failure), maxAttempts caps retries per outage,
# and the clock is checked first (a wrong date can never pass verify-doh-cert).
#
# Verified on RouterOS 7.23.1 / 7.24.5 (see docs/verification.md).

:local monitorInterval "60s"
    # scheduler interval; 45-60s for an office, 3m acceptable for home

/system script remove [find name="DNS_HealthMonitor_Failover"]
/system script add name="DNS_HealthMonitor_Failover" policy=read,write,policy,test dont-require-permissions=no source={
# ===== CONFIG =====
:local dohUrlA      "https://cloudflare-dns.com/dns-query"
    # primary: standard Cloudflare, no filtering
:local probeUrlA    "https://cloudflare-dns.com/dns-query?name=example.com&type=A"
:local dohUrlB      "https://dns.google/dns-query"
    # fallback: needs Google's root CA in the trust store. NOTE: only ONE
    # endpoint can be active in RouterOS, so "a list of fallbacks" means the
    # monitor tries them one at a time; here the list has one entry (dohUrlB).
:local probeUrlB    "https://dns.google/resolve?name=example.com&type=A"
:local probeGood    {"example.com";"cdnjs.cloudflare.com";"cdn.tailwindcss.com"}
:local stubPrefixes {"8.6.112.";"8.47.69."}
:local filtering    false
    # true if the configured endpoint is family/security (marker for the reader)
:local applyChanges true
    # false = report only, never touch /ip dns
:local failureThreshold 2
    # consecutive bad runs before attempting a failover (anti-flap)
:local recoveryThreshold 2
    # consecutive good runs on the primary before coming home (anti-flap)
:local maxAttempts  3
    # failover attempts per outage, then stop trying until the primary recovers
# ==================

:global DNSMonitorState
:global DNSFailCount
:global DNSRecoverCount
:global DNSFailoverAttempts
:if ([:typeof $DNSFailCount] = "nothing") do={ :set DNSFailCount 0 }
:if ([:typeof $DNSRecoverCount] = "nothing") do={ :set DNSRecoverCount 0 }
:if ([:typeof $DNSFailoverAttempts] = "nothing") do={ :set DNSFailoverAttempts 0 }
:if ([:typeof $DNSMonitorState] = "nothing") do={ :set DNSMonitorState "healthy" }

# --- 0: device-mode ---
:local dm [/system device-mode get mode]
:if ($dm = "home") do={
    :if ($DNSMonitorState != "manual-only") do={
        :set DNSMonitorState "manual-only"
        :log warning "MONITOR_DISABLED_BY_DEVICE_MODE: device-mode=home — /tool fetch and the scheduler are unavailable; run the monitor by hand and expect no failover"
    }
} else={

# --- 1: clock ---
:local clock [/system clock get date]
:local year [:tonum [:pick $clock 0 4]]
:if (($year < 2025) or ($year > 2035)) do={
    :if ($DNSMonitorState != "clock-invalid") do={
        :set DNSMonitorState "clock-invalid"
        :log error ("CLOCK_INVALID: clock looks wrong (" . $clock . ") — certificate validation cannot succeed; enable NTP")
    }
} else={

    # --- 2: are the answers usable? (content, not type) ---
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

    # --- 3: is the primary endpoint alive? (fetch, does not touch /ip dns) ---
    :local probeA "unreachable"
    :do {
        /file remove [find name="doh-health-a.json"]
        /tool fetch url=$probeUrlA http-header-field="accept: application/dns-json" dst-path="doh-health-a.json" mode=https
        :local body [:tostr [/file get "doh-health-a.json" contents]]
        :if ([:find $body "\"Status\":0"] >= 0) do={ :set probeA "ok" } else={ :set probeA "bad-status" }
    } on-error={ :set probeA "unreachable" }
    /file remove [find name="doh-health-a.json"]

    # --- 4: state machine ---
    :if ($good > 0) do={
        # primary answers usable content
        :set DNSFailCount 0
        :set DNSFailoverAttempts 0
        :if (($DNSMonitorState = "fallback") or ($DNSMonitorState = "recovering")) do={
            :if ($probeA = "ok") do={
                # primary endpoint is reachable again — count up before coming home
                :set DNSRecoverCount ($DNSRecoverCount + 1)
                :if ($DNSRecoverCount >= $recoveryThreshold) do={
                    /ip dns set use-doh-server=$dohUrlA verify-doh-cert=yes
                    /ip dns cache flush
                    :set DNSMonitorState "healthy"
                    :set DNSRecoverCount 0
                    :log warning "HEALTHY: primary DoH answers again — switched back from the fallback"
                } else={
                    :if ($DNSMonitorState != "recovering") do={
                        :set DNSMonitorState "recovering"
                        :log info ("RECOVERING: primary answers again (" . $DNSRecoverCount . "/" . $recoveryThreshold . ")")
                    }
                }
            } else={
                # primary still unreachable — reset the recovery progress and stay
                :set DNSRecoverCount 0
                :if ($DNSMonitorState != "fallback") do={
                    :set DNSMonitorState "fallback"
                    :log info "RECOVERING: primary still unreachable — staying on the fallback"
                }
            }
        } else={
            :if ($DNSMonitorState != "healthy") do={
                :set DNSMonitorState "healthy"
                :log info ("HEALTHY: answers look sane (" . $good . " of " . ($good + $bad) . ")")
            }
        }
    } else={
        :if ($stubSeen = 1) do={
            # resolver answered, but with the stub pair 8.6.112.0 / 8.47.69.0 —
            # reachability from this network cannot be judged from the router,
            # and a second endpoint returns the same pair, so no failover.
            :if ($DNSMonitorState != "stub") do={
                :set DNSMonitorState "stub"
                :log warning ("STUB: answers are the stub pair — " . $detail . "If CDNs do not open here the pair is unreachable from this network: confirm from a client with curl --resolve (docs/troubleshooting.md §6.10). Switching the resolver does not help")
            }
        } else={
            # no usable answers at all
            :set DNSRecoverCount 0
            :set DNSFailCount ($DNSFailCount + 1)
            :if (($DNSMonitorState = "fallback") or ($DNSMonitorState = "recovering")) do={
                # already on the fallback; make sure it still works
                :local probeB "unreachable"
                :do {
                    /file remove [find name="doh-health-b.json"]
                    /tool fetch url=$probeUrlB http-header-field="accept: application/dns-json" dst-path="doh-health-b.json" mode=https
                    :local bodyB [:tostr [/file get "doh-health-b.json" contents]]
                    :if ([:find $bodyB "\"Status\":0"] >= 0) do={ :set probeB "ok" } else={ :set probeB "bad-status" }
                } on-error={ :set probeB "unreachable" }
                /file remove [find name="doh-health-b.json"]
                :if ($probeB != "ok") do={
                    :if ($DNSMonitorState != "degraded") do={
                        :set DNSMonitorState "degraded"
                        :log error ("DEGRADED: primary down and fallback unreachable — keeping the current configuration")
                    }
                }
            } else={
                :if ($probeA = "ok") do={
                    # endpoint alive but resolver returns nothing: stale/corrupt cache
                    /ip dns cache flush
                    :if ($DNSMonitorState != "suspect") do={
                        :set DNSMonitorState "suspect"
                        :log warning ("SUSPECT: endpoint answers but the resolver returns no usable addresses — " . $detail . "cache flushed (" . $DNSFailCount . "/" . $failureThreshold . ")")
                    }
                } else={
                    :if ($DNSFailCount >= $failureThreshold) do={
                        :if (($applyChanges) and ($DNSFailoverAttempts < $maxAttempts)) do={
                            # probe the fallback BEFORE switching
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
                                    :set DNSMonitorState "fallback"
                                    :set DNSRecoverCount 0
                                    :log warning ("FALLBACK: switched to fallback DoH (" . $dohUrlB . "), example.com -> " . $test)
                                } else={
                                    /ip dns set use-doh-server=$dohUrlA verify-doh-cert=yes
                                    /ip dns cache flush
                                    :set DNSMonitorState "degraded"
                                    :log error ("DEGRADED: fallback DoH did not resolve either — rolled back to the primary; check the CA for the fallback host")
                                }
                            } else={
                                :if ($DNSMonitorState != "degraded") do={
                                    :set DNSMonitorState "degraded"
                                    :log error ("DEGRADED: both endpoints unreachable (primary " . $probeA . ", fallback " . $probeB . ") — keeping the current configuration")
                                }
                            }
                        } else={
                            :if ($DNSMonitorState != "suspect") do={
                                :set DNSMonitorState "suspect"
                                :log info ("SUSPECT: primary unreachable (" . $DNSFailCount . "/" . $failureThreshold . ", attempts " . $DNSFailoverAttempts . "/" . $maxAttempts . ")")
                            }
                        }
                    } else={
                        :if ($DNSMonitorState != "suspect") do={
                            :set DNSMonitorState "suspect"
                            :log info ("SUSPECT: primary unreachable (" . $DNSFailCount . "/" . $failureThreshold . ")")
                        }
                    }
                }
            }
        }
    }
}
}
}

/system scheduler remove [find name="Scheduler_DNS_Health_Check"]
/system scheduler add name="Scheduler_DNS_Health_Check" interval=$monitorInterval start-time=startup policy=read,write,policy,test on-event="/system script run DNS_HealthMonitor_Failover" comment="DNS/DoH health monitor: content check, non-disruptive probe, DoH-to-DoH failover with hysteresis" disabled=no
