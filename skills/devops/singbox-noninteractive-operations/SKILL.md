---
name: singbox-noninteractive-operations
description: Use when deploying and operating one-singbox over SSH.
version: 0.1.0
author: descend, Hermes Agent
license: GPL-3.0-or-later
platforms: [linux]
metadata:
  hermes:
    tags: [sing-box, one-singbox, SSH, VPS, proxy, relay]
    related_skills: []
---

# Sing-box Non-interactive Operations Skill

Use this skill to inspect a remote VPS, deploy the `ouones/one-singbox` management
script, and operate proxy nodes and direct relays through SSH. It covers node and
relay creation, inventory, querying, renaming, modification, deletion, and bounded
log reading. It does not replace the official sing-box configuration manual or
perform unrelated host hardening.

## When to Use

- A user asks to SSH to a VPS and deploy one-singbox.
- A user asks to create, list, inspect, rename, modify, or delete proxy nodes.
- A user asks to create, list, inspect, modify, or delete one-singbox relays.
- A user asks for recent sing-box logs without an interactive follow session.
- A deployment must work across Debian, Ubuntu, Alpine, systemd, OpenRC, IPv4,
  IPv6-only, or restricted-download environments.

Do not use this skill to guess an SSH target, recover unknown credentials, rewrite
arbitrary sing-box JSON, or silently reinstall an existing deployment.

## Prerequisites

- The user supplied a host alias, address, or an unambiguous server reference.
- SSH access is available through the existing SSH configuration/key path.
- Use `terminal` for all remote commands; use `BatchMode=yes` for non-interactive
  probes when key authentication is expected.
- Read `references/remote-deployment.md` before installation and
  `references/safety-and-rollback.md` before destructive changes.
- Treat `/etc/sing-box`, `/etc/sing-box/conf`, and
  `/var/log/sing-box/access.log` as one-singbox defaults only after checking the
  target host; do not assume another host has the same paths.

## How to Run

1. Resolve the target from the user's input and the local SSH configuration. Do
   not substitute an old IP from memory.
2. Run the remote preflight through `terminal`, recording hostname, OS, version,
   architecture, init system, privilege, package manager, connectivity, and any
   existing sing-box state.
3. Choose standard online installation or the restricted-network fallback from
   `references/remote-deployment.md`.
4. Run one-singbox commands with every required positional argument supplied.
   Use `auto` only where the command documents it; missing arguments can invoke
   prompts.
5. After every write, read the exact remote target back and verify the service,
   configuration, and relevant listening port.

For multiline remote procedures, send a reviewed script over SSH stdin or use a
local temporary file. Never put an SSH password, private key, UUID, PSK, password,
or private key into a command shown in the report.

## Quick Reference

The wrapper commands below run on the target VPS through `terminal`:

```text
sing-box add <protocol> [args... | auto]
sing-box info <name>
sing-box change <name> <option> [args... | auto]
sing-box change <name> name <new-name>
sing-box del <name>
sing-box relay add <local-port> <remote-addr> <remote-port>
sing-box relay list
sing-box relay info <local-port>
sing-box relay delete <local-port>
```

The repository helper is read-only and runs on the target:

```text
bash scripts/singbox_inventory.sh nodes [conf-dir]
bash scripts/singbox_inventory.sh relays [conf-dir]
bash scripts/singbox_inventory.sh logs [lines] [match] [log-file]
```

Send that helper with SSH stdin when the skill package is not already present on
the target. It lists nodes and relays without printing credentials. Do not use
`sing-box log` without an argument for a bounded query: the project implements
that form as a blocking follow operation.

## Procedure

1. **Lock the host.** Verify SSH login and read the remote hostname and OS. The
   completion criterion is a fresh response from the intended target, not merely
   an open TCP port.
2. **Preflight the platform.** Check root, architecture, package manager, bash,
   wget, tar, jq, systemd/OpenRC, DNS, GitHub reachability, and port conflicts.
   The criterion is a selected deployment path with its blocker evidence recorded.
3. **Inspect existing state.** Check for an existing one-singbox installation,
   nodes, relays, Caddy, and service state. Never overwrite an existing install
   without an explicit reinstall or migration request.
4. **Deploy and verify.** Install through the standard script when possible;
   otherwise use the documented offline/IPv6-only or Alpine/OpenRC path. Verify
   the wrapper version, service state, configuration directory, and a valid
   core configuration before creating a node.
5. **Inventory before mutation.** List all proxy nodes and all relays with the
   repository helper. Use the inventory to select an exact target and prevent
   duplicate ports or accidental replacement.
6. **Operate proxy nodes.** Create with `add`; query with `info`/`url`/`qr`;
   rename with `change <name> name <new-name>`; modify with `change`; delete
   only after displaying the exact target and receiving confirmation. Verify
   each result by inventory or an exact query.
7. **Operate relays.** Create with `relay add`; query with `relay info`; list
   with `relay list`; delete with `relay delete`. Since the project has no native
   relay-change command, modify by saving the old tuple, deleting, recreating,
   verifying, and restoring the old tuple if recreation fails.
8. **Read logs safely.** Use the bounded helper with an explicit line limit and
   optional match string. Never start an unbounded follow process. Redact tokens
   or credential-like values before reporting.
9. **Report the business result.** Include target hostname, OS, sing-box version,
   node/relay counts, changed object, service state, verification results, and
   any automatic restart or fallback. Separate verified facts from blockers.

## Pitfalls

- Running `sing-box` without arguments opens the interactive menu.
- Omitting required arguments can invoke `read`; supply them or use `auto`.
- A name matching multiple files is not an acceptable destructive target.
- Node `name` changes the share-link label metadata; it does not rename the JSON
  file. Inventory must prefer the metadata label.
- There is no native `relay change`; relay modification is a delete-and-recreate
  transaction with recovery.
- `sing-box log` without an argument follows the access log and blocks. Use the
  bounded helper instead.
- One-singbox write operations can restart sing-box automatically. Report that
  side effect and verify the service afterward.
- TLS creation can still prompt when a domain is missing or automatic TLS finds a
  port conflict; do not call that path non-interactive unless all conditions are
  satisfied.
- Alpine/OpenRC and IPv6-only hosts may need a separate download and service path;
  do not force a Debian/systemd assumption.
- Do not print passwords, UUIDs, PSKs, private keys, or complete share URLs in an
  inventory or final report.

## Verification

A deployment or operation is complete only when fresh remote evidence confirms:

- SSH reached the intended hostname and the recorded OS/architecture.
- The one-singbox wrapper and core version are readable.
- The service is active through the target's actual init system.
- The configuration passes the core check and the expected port is listening.
- Node inventory and relay inventory contain the expected counts and fields.
- A rename is visible in inventory/URL metadata while the original JSON remains.
- A modification is visible after a new query, not just in command output.
- A deletion is absent after a new inventory/query.
- A relay modification either reaches the new target or has restored the old one.
- Log output is bounded, non-blocking, and contains no exposed credential.

Use the detailed checklists in `references/remote-deployment.md`,
`references/one-singbox-command-matrix.md`, `references/inventory-and-logs.md`,
and `references/safety-and-rollback.md` before claiming completion.
