"""mikrotik-doh-failover — tools that go with the RouterOS DoH failover scheme.

The RouterOS side lives in the repository as ``.rsc`` scripts: they are copied to the
router by hand and are not part of this package. This package carries the Zabbix-side
tools, so they can be installed and upgraded like any other Python program:

    pip install mikrotik-doh-failover
    doh-zabbix-setup --help
    doh-zabbix-collector --help
"""

from __future__ import annotations

__version__ = "0.4.3"
__all__ = ["__version__"]
