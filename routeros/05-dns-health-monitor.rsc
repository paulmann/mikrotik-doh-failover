# 05-dns-health-monitor.rsc — version 4.1 (0.4.x)
# Managed DoH-to-DoH failover with content-aware probing and an explicit state
# machine. This is MANAGED failover (the upstream changes on a fault), not
# "transparent" failover: primary and fallback are different operators and may
# answer differently (filtering, geo, CDN steering).
#
# CHANGES IN 4.1 (relative to 4.0)
#   1. Every /tool fetch now carries duration=5s, so a hung endpoint cannot block
#      the run past the scheduler interval (verified on 7.23.1).
#   2. The tertiary switch now does the same probe-before + verify-after + rollback
#      as the secondary, and every real switch (secondary, tertiary, plain)
#      increments DNSFailoverAttempts.
#   3. Recovery from the plain fallback climbs back to any DoH endpoint (not only
#      the primary): if the primary is still down but the secondary answers, the
#      monitor leaves plain DNS and returns to DoH.
#
# CHANGES IN 4.0 (relative to 3.1)
#   1. Probe rewritten to `/tool fetch ... as-value output=user`: the response
#      body comes back in memory, so there are no temporary files in /file and no
#      cleanup races. The JSON check also tolerates "Status":0 / "Status": 0.
#   2. Ordered failover chain: primary -> secondary -> tertiary (dohUrlC, optional,
#      empty disables it) -> plain DNS (plainFallback, optional). The plain step is
#      an explicit last resort logged as PRIVACY DEGRADED.
#   3. New state "plain" (on the plain-DNS fallback) and recovery from it back to
#      the primary once the primary endpoint answers again.
#
# CHANGES IN 3.1 (relative to 3.0)
#   1. Concurrency guard: a run that overlaps the previous one is skipped, and
#      the guard flag is cleared in an on-error handler, so a crashed run cannot
#      leave the monitor permanently "locked".
#   2. Failover is now driven by the ENDPOINT probe (probeA) together with the
#      content check, not by the content check alone. In 3.0 a primary that died
#      while the cache still held valid answers looked "healthy", so failover was
#      delayed by the cache TTL. Now "primary unhealthy" = endpoint unreachable
#      OR no usable answers, so the monitor fails over before the cache expires.
#
# Kept from 3.0: the explicit state machine (HEALTHY / SUSPECT / FALLBACK /
# RECOVERING / STUB / DEGRADED / CLOCK_INVALID / MANUAL-ONLY / PLAIN), the
# hysteresis thresholds, the clock range guard, the probe-before-switch and
# verify-after-switch with rollback, maxAttempts, and the narrow policy.

:local monitorInterval "60s"
    # scheduler interval; 45-60s for an office, 3m acceptable for home

/system script remove [find name="DNS_HealthMonitor_Failover"]
/system script add name="DNS_HealthMonitor_Failover" policy=read,write,policy,test dont-require-permissions=no source={
# ===== CONFIG =====
:local dohUrlA      "https://cloudflare-dns.com/dns-query"
:local probeUrlA    "https://cloudflare-dns.com/dns-query?name=example.com&type=A"
:local dohUrlB      "https://dns.google/dns-query"
:local probeUrlB    "https://dns.google/resolve?name=example.com&type=A"
:local dohUrlC      ""
:local probeUrlC    ""
:local plainFallback false
:local plainServers "1.1.1.1,1.0.0.1,8.8.8.8,8.8.4.4"
# dohUrlC / probeUrlC: optional tertiary DoH endpoint; leave empty to disable (the probe must speak DNS-JSON)
# plainFallback: switch to plain DNS if ALL DoH endpoints fail (privacy downgrade, logged PRIVACY DEGRADED)
# plainServers: the plain resolvers used when plainFallback is true
:local probeGood    {"example.com";"cdnjs.cloudflare.com";"cdn.tailwindcss.com"}
:local stubPrefixes {"8.6.112.";"8.47.69."}
:local filtering    false
:local applyChanges true
:local failureThreshold 2
:local recoveryThreshold 2
:local maxAttempts  3
# ==================

:global DNSMonitorState
:global DNSFailCount
:global DNSRecoverCount
:global DNSFailoverAttempts
:global DNSMonitorRunning
:if ([:typeof $DNSFailCount] = "nothing") do={ :set DNSFailCount 0 }
:if ([:typeof $DNSRecoverCount] = "nothing") do={ :set DNSRecoverCount 0 }
:if ([:typeof $DNSFailoverAttempts] = "nothing") do={ :set DNSFailoverAttempts 0 }
:if ([:typeof $DNSMonitorState] = "nothing") do={ :set DNSMonitorState "healthy" }
:if ([:typeof $DNSMonitorRunning] = "nothing") do={ :set DNSMonitorRunning false }

# --- 0: concurrency guard ---
:if ($DNSMonitorRunning = true) do={
    :log info "DNS monitor: skipped — a previous run is still active"
}
:if ($DNSMonitorRunning = false) do={
    :set DNSMonitorRunning true
    :do {

        # --- 1: device-mode ---
        :local dm [/system device-mode get mode]
        :if ($dm = "home") do={
            :if ($DNSMonitorState != "manual-only") do={
                :set DNSMonitorState "manual-only"
                :log warning "MONITOR_DISABLED_BY_DEVICE_MODE: device-mode=home — /tool fetch and the scheduler are unavailable; run the monitor by hand and expect no failover"
            }
        } else={

            # --- 2: clock (past AND future both break certificate validation) ---
            :local clock [/system clock get date]
            :local year [:tonum [:pick $clock 0 4]]
            :if (($year < 2025) or ($year > 2035)) do={
                :if ($DNSMonitorState != "clock-invalid") do={
                    :set DNSMonitorState "clock-invalid"
                    :log error ("CLOCK_INVALID: clock looks wrong (" . $clock . ") — certificate validation cannot succeed; enable NTP")
                }
            } else={

                # --- 3: probe the primary endpoint (HTTPS, does not touch /ip dns) ---
                :local probeA "unreachable"
                :do {
                    :local rA [/tool fetch url=$probeUrlA http-header-field="accept: application/dns-json" mode=https as-value output=user duration=5s]
                    :local bodyA ($rA->"data")
                    :if (($rA->"status") = "finished") do={
                        :if (([:find $bodyA "\"Status\":0"] >= 0) or ([:find $bodyA "\"Status\": 0"] >= 0)) do={ :set probeA "ok" } else={ :set probeA "bad-status" }
                    } else={ :set probeA "unreachable" }
                } on-error={ :set probeA "unreachable" }

                # --- 4: content check (answer quality via the live resolver) ---
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

                # --- 5: state machine ---
                :if ($stubSeen = 1) do={
                    :set DNSRecoverCount 0
                    :if ($DNSMonitorState != "stub") do={
                        :set DNSMonitorState "stub"
                        :log warning ("STUB: answers are the stub pair — " . $detail . "If CDNs do not open here the pair is unreachable from this network: confirm from a client with curl --resolve (docs/troubleshooting.md §6.10). Switching the resolver does not help")
                    }
                } else={
                    :if (($DNSMonitorState = "fallback") or ($DNSMonitorState = "recovering") or ($DNSMonitorState = "plain")) do={
                        # ON THE FALLBACK — decide whether to come home
                        :if ($probeA = "ok") do={
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
                            :set DNSRecoverCount 0
                            :if ($DNSMonitorState = "plain") do={
                                :local probeB "unreachable"
                                :do {
                                    :local rB [/tool fetch url=$probeUrlB http-header-field="accept: application/dns-json" mode=https as-value output=user duration=5s]
                                    :local bodyB ($rB->"data")
                                    :if (($rB->"status") = "finished") do={
                                        :if (([:find $bodyB "\"Status\":0"] >= 0) or ([:find $bodyB "\"Status\": 0"] >= 0)) do={ :set probeB "ok" } else={ :set probeB "bad-status" }
                                    } else={ :set probeB "unreachable" }
                                } on-error={ :set probeB "unreachable" }
                                :if ($probeB = "ok") do={
                                    /ip dns set use-doh-server=$dohUrlB verify-doh-cert=yes
                                    /ip dns set servers=""
                                    /ip dns cache flush
                                    :set DNSMonitorState "fallback"
                                    :log warning ("RECOVERY: primary still down — climbed from plain DNS back to fallback DoH (" . $dohUrlB . ")")
                                }
                            } else={
                                :if ($DNSMonitorState != "fallback") do={
                                    :set DNSMonitorState "fallback"
                                    :log info "RECOVERING: primary still unreachable — staying on the fallback"
                                }
                                :local probeB "unreachable"
                                :do {
                                    :local rB [/tool fetch url=$probeUrlB http-header-field="accept: application/dns-json" mode=https as-value output=user duration=5s]
                                    :local bodyB ($rB->"data")
                                    :if (($rB->"status") = "finished") do={
                                        :if (([:find $bodyB "\"Status\":0"] >= 0) or ([:find $bodyB "\"Status\": 0"] >= 0)) do={ :set probeB "ok" } else={ :set probeB "bad-status" }
                                    } else={ :set probeB "unreachable" }
                                } on-error={ :set probeB "unreachable" }
                                :if ($probeB != "ok") do={
                                    :if ($DNSMonitorState != "degraded") do={
                                        :set DNSMonitorState "degraded"
                                        :log error "DEGRADED: primary down and fallback unreachable — keeping the current configuration"
                                    }
                                }
                            }
                        }
                    } else={
                        # ON THE PRIMARY — failover decision
                        :if (($probeA = "ok") and ($good > 0)) do={
                            :set DNSFailCount 0
                            :set DNSFailoverAttempts 0
                            :if ($DNSMonitorState != "healthy") do={
                                :set DNSMonitorState "healthy"
                                :log info ("HEALTHY: answers look sane (" . $good . " of " . ($good + $bad) . ")")
                            }
                        } else={
                            :set DNSFailCount ($DNSFailCount + 1)
                            :if ($DNSFailCount >= $failureThreshold) do={
                                :if (($applyChanges) and ($DNSFailoverAttempts < $maxAttempts)) do={
                                    :local probeB "unreachable"
                                    :do {
                                        :local rB [/tool fetch url=$probeUrlB http-header-field="accept: application/dns-json" mode=https as-value output=user duration=5s]
                                        :local bodyB ($rB->"data")
                                        :if (($rB->"status") = "finished") do={
                                            :if (([:find $bodyB "\"Status\":0"] >= 0) or ([:find $bodyB "\"Status\": 0"] >= 0)) do={ :set probeB "ok" } else={ :set probeB "bad-status" }
                                        } else={ :set probeB "unreachable" }
                                    } on-error={ :set probeB "unreachable" }
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
                                            :log error "DEGRADED: fallback DoH did not resolve either — rolled back to the primary; check the CA for the fallback host"
                                        }
                                    } else={
                                        :local probeC "unreachable"
                                        :if ([:len $dohUrlC] > 0) do={
                                            :do {
                                                :local rC [/tool fetch url=$probeUrlC http-header-field="accept: application/dns-json" mode=https as-value output=user duration=5s]
                                                :local bodyC ($rC->"data")
                                                :if (($rC->"status") = "finished") do={
                                                    :if (([:find $bodyC "\"Status\":0"] >= 0) or ([:find $bodyC "\"Status\": 0"] >= 0)) do={ :set probeC "ok" } else={ :set probeC "bad-status" }
                                                } else={ :set probeC "unreachable" }
                                            } on-error={ :set probeC "unreachable" }
                                        }
                                        :if ($probeC = "ok") do={
                                            :set DNSFailoverAttempts ($DNSFailoverAttempts + 1)
                                            /ip dns set use-doh-server=$dohUrlC verify-doh-cert=yes
                                            /ip dns cache flush
                                            :delay 3s
                                            :local testC ""
                                            :do { :set testC [:tostr [:resolve "example.com"]] } on-error={ :set testC "" }
                                            :if ([:len $testC] > 0) do={
                                                :set DNSMonitorState "fallback"
                                                :set DNSRecoverCount 0
                                                :log warning ("FALLBACK: switched to tertiary DoH (" . $dohUrlC . "), example.com -> " . $testC)
                                            } else={
                                                /ip dns set use-doh-server=$dohUrlA verify-doh-cert=yes
                                                /ip dns cache flush
                                                :set DNSMonitorState "degraded"
                                                :log error "DEGRADED: tertiary DoH did not resolve either — rolled back to the primary; check the CA for the tertiary host"
                                            }
                                        } else={
                                            :if ($plainFallback) do={
                                                :set DNSFailoverAttempts ($DNSFailoverAttempts + 1)
                                                /ip dns set use-doh-server=""
                                                /ip dns set servers=$plainServers
                                                /ip dns cache flush
                                                :set DNSMonitorState "plain"
                                                :set DNSRecoverCount 0
                                                :log error ("PRIVACY DEGRADED: all DoH endpoints unreachable — switched to plain DNS (attempt " . $DNSFailoverAttempts . "); bootstrap statics preserved for recovery")
                                            } else={
                                                :if ($DNSMonitorState != "degraded") do={
                                                    :set DNSMonitorState "degraded"
                                                    :log error ("DEGRADED: all DoH endpoints unreachable (primary " . $probeA . ", fallback " . $probeB . ") — keeping the current configuration")
                                                }
                                            }
                                        }
                                    }
                                } else={
                                    :if ($DNSMonitorState != "suspect") do={
                                        :set DNSMonitorState "suspect"
                                        :log info ("SUSPECT: primary unhealthy (" . $DNSFailCount . "/" . $failureThreshold . ", attempts " . $DNSFailoverAttempts . "/" . $maxAttempts . ")")
                                    }
                                }
                            } else={
                                :if ($DNSMonitorState != "suspect") do={
                                    :set DNSMonitorState "suspect"
                                    :log info ("SUSPECT: primary unhealthy (" . $DNSFailCount . "/" . $failureThreshold . ")")
                                }
                                :if (($probeA = "ok") and ($good = 0)) do={
                                    /ip dns cache flush
                                }
                            }
                        }
                    }
                }
            }
        }

    } on-error={
        :log error "DNS monitor: run aborted by an error — see the log above"
    }
    :set DNSMonitorRunning false
}
}

/system scheduler remove [find name="Scheduler_DNS_Health_Check"]
/system scheduler add name="Scheduler_DNS_Health_Check" interval=$monitorInterval start-time=startup policy=read,write,policy,test on-event="/system script run DNS_HealthMonitor_Failover" comment="DNS/DoH health monitor: content check, non-disruptive probe, DoH-to-DoH failover with hysteresis" disabled=no
