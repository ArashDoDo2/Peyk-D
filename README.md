Peyk-D is a lightweight, high-latency, and resilient communication tool designed for emergency situations where standard internet protocols (HTTP/TCP) are restricted, but DNS resolution remains functional.

Project Codename: Peyk-D (Messenger over DNS)
Primary Goal: Resilience in white-listed / severely restricted network environments
Scope: Short, text-only emergency messages

📖 Overview

In crisis scenarios, DNS often remains the last standing bridge between a restricted network and the global internet.
Peyk-D leverages DNS not as a tunneling mechanism, but as a minimal data carrier to transmit short, end-to-end encrypted text messages between:

a user inside a restricted zone, and

a recipient outside the restricted network.

Peyk-D is intentionally constrained and prioritizes survivability and simplicity over performance or convenience.

🎯 Core Mission

Peyk-D is designed to provide a minimalist communication lifeline when international connectivity is heavily restricted and DNS resolution is the only remaining service.

Design principles:

Focus on short text messages (status updates, emergency alerts)

One-to-one communication

Asynchronous (store-and-forward)

Priority on resilience, predictability, and ease of use for non-technical users

🗺️ Execution Roadmap (8-Phase Model)
🔹 Phase 0 — Validation of the Wire

Objective: Prove that DNS queries reliably reach the authoritative server.

Observe incoming DNS traffic on UDP/53

Test queries via multiple Iranian ISPs (e.g. mobile and fixed-line)

Identify:

Case normalization behavior (uppercase/lowercase handling)

Practical character limits per DNS label

Outcome: Informed decision on encoding strategy

🔹 Phase 1 — Minimal Semantics & Observability

Objective: Introduce minimal structure without processing message content.

Define a Pair ID concept to separate user traffic

Observe request rates and timing patterns

Monitor network instability and resolver behavior

No payload decoding at this stage

🔹 Phase 2 — Message Lifecycle & State Machine

Objective: Define message flow and reliability model.

Define message states (e.g. Created, Pending, Sent)

Address UDP characteristics:

Duplicate packets

Reordered delivery

Enforce idempotency so retries do not create duplicate messages

Store messages in a queue (e.g. Redis) with controlled TTL

🔹 Phase 3 — Security Hardening (E2EE)

Objective: Secure message content under strict size constraints.

End-to-end encryption required

Authenticated encryption to detect tampering

Optimize cryptographic overhead for DNS payload limits

Ensure replay protection via message ordering or identifiers

🔹 Phase 4 — Client UX & Intelligent Polling

Objective: Ensure usability and survivability under unstable networks.

Minimal UI:

Message input

Send action

Clear delivery status indicators

Polling behavior:

Non-deterministic timing (jitter)

Adaptive frequency based on network conditions

Backoff when no messages are available

Battery and data usage must remain minimal

🔹 Phase 5 — DNS Compatibility & Fragmentation

Objective: Maintain protocol correctness and resolver compatibility.

Handle message fragmentation within DNS label constraints

Maintain RFC-compliant responses

Ensure responses remain indistinguishable from standard DNS traffic

Avoid reliance on non-standard resolver behavior

🔹 Phase 6 — Operational Readiness

Objective: Prepare the system for real-world deployment.

Harden authoritative DNS against abuse

Prevent DNS amplification risks

Automatic cleanup of stored messages after a fixed retention window

Minimize logs and sensitive metadata retention

🔹 Phase 7 — Documentation & Handover

Objective: Enable safe use and long-term maintainability.

End-user guide for non-technical users

Finalized threat model based on real observations

Clear documentation of limitations and expected behavior

Handover materials for operators and maintainers

🛡️ Threat Model (High-Level)

Adversary:

Advanced packet inspection and traffic analysis systems

Defensive Strategy:

Strong content encryption

Minimal metadata exposure

Timing variability to reduce deterministic patterns

Survivability Measures:

Support for domain rotation or fallback namespaces

Graceful degradation under partial network failure

⚠️ Limitations

Extremely low throughput

High and variable latency

Not suitable for real-time chat

No anonymity guarantees

Intended strictly for emergency and humanitarian use

📜 License

To be determined.
Recommended options:

AGPL-3.0 for strong copyleft deployments

Apache-2.0 for broader integration flexibility
