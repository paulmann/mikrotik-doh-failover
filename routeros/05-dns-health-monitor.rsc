# 05-dns-health-monitor.rsc
# Health-check + failover for the single DoH upstream.
#
# Design (RouterOS has no user-defined functions, so the checks are inlined and
# the sections are only separated by comments):
#   [config]  tunables
#   [check]   is DoH answering? is plain DNS answering?
#   [switch]  flip use-doh-server on/off, flush cache, log the transition
#
# Policy is narrowed to read,write,policy,test: the script does not need ftp,
# reboot, password, sniff, sensitive or romon.

/system script remove [find name="DNS_HealthMonitor_Failover"]
/system script add name="DNS_HealthMonitor_Failover" policy=read,write,policy,test dont-require-permissions=no source={
# --- config ---
:local dohUrl "https://family.cloudflare-dns.com/dns-query"
:local plainServers "1.1.1.3,1.0.0.3"
:local testDomain "cloudflare.com"
# --------------
:global DNSCurrentMode
:if ([:typeof $DNSCurrentMode] = "nothing") do={ :set DNSCurrentMode "doh" }

:local ip ""
:local dohOk false
:local plainOk false

:if ($DNSCurrentMode = "doh") do={
    # --- check: does DoH answer through the real resolver path? ---
    :do { :set ip [:resolve $testDomain] } on-error={ :set ip "" }
    :set dohOk ([:typeof $ip] = "ip")
    :if (!($dohOk)) do={
        # --- check: does plain DNS answer? (:resolve server= bypasses DoH) ---
        :do { :local pip [:resolve $testDomain server=1.1.1.3]; :set plainOk ([:typeof $pip] = "ip") } on-error={ :set plainOk false }
        :if ($plainOk) do={
            # --- switch: fall back to plain family DNS ---
            /ip dns set use-doh-server="" servers=$plainServers
            /ip dns cache flush
            :set DNSCurrentMode "plain"
            :log error "DNS Monitor: DoH failed, switched to plain family DNS"
        } else={
            :log critical "DNS Monitor: DoH and plain DNS both failed"
        }
    }
} else={
    # --- check: can we restore DoH? (temporarily enable it and test) ---
    /ip dns set use-doh-server=$dohUrl verify-doh-cert=yes
    :do { :set ip [:resolve $testDomain] } on-error={ :set ip "" }
    :set dohOk ([:typeof $ip] = "ip")
    :if ($dohOk) do={
        # --- switch: back to DoH ---
        /ip dns cache flush
        :set DNSCurrentMode "doh"
        :log warning "DNS Monitor: DoH restored"
    } else={
        /ip dns set use-doh-server=""
        :log info "DNS Monitor: DoH still down, staying on plain"
    }
}
}

/system scheduler add name="Scheduler_DNS_Health_Check" interval=3m start-time=startup on-event="/system script run DNS_HealthMonitor_Failover" comment="DNS/DoH health monitor and failover" disabled=no
