# Contributing to Peyk-D

We welcome contributions from senior engineers, security researchers, and network specialists.

### Engineering Standards:
* **No Over-engineering:** Keep the DNS payload as small as possible.
* **Stateless Gateway:** The gateway should remain as stateless as possible, delegating persistence to Redis.
* **RFC Compliance:** All DNS responses must be valid `A records` to avoid anomaly detection.

### Current Priority:
We are currently in **Phase 0**. We need volunteers to run `dig` tests from different ISPs and report if the `QNAME` is being normalized or dropped.
