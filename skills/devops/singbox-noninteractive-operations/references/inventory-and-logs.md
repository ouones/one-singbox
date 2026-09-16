# Inventory and Logs

## Inventory goals

The repository's wrapper has `relay list` but no dedicated proxy-node list. The
skill therefore uses the included read-only helper for deterministic summaries:

```text
bash scripts/singbox_inventory.sh nodes [conf-dir]
bash scripts/singbox_inventory.sh relays [conf-dir]
```

When the helper is not installed on the target, send it over SSH stdin:

```text
terminal(command="ssh <target> 'bash -s -- nodes /etc/sing-box/conf' < scripts/singbox_inventory.sh")
terminal(command="ssh <target> 'bash -s -- relays /etc/sing-box/conf' < scripts/singbox_inventory.sh")
```

The helper:

- scans only the requested one-singbox configuration directory;
- excludes `relay-*.json` from the node list;
- skips dynamic-port and invalid JSON entries with a warning;
- reads `.quan-meta/<config>.meta.json.node_name` when available;
- falls back to the JSON basename without `.json`;
- prints protocol, listen address/port, host or SNI, network, method, and direct
  relay target when applicable;
- never prints UUIDs, passwords, PSKs, private keys, or complete URLs.

A node list reports configuration presence, not end-to-end client reachability.
Use the service, listener, core-check, and protocol-specific checks for stronger
claims.

## Expected node display

```text
代理节点（共 N 个）

1. <display-name>
   协议：<protocol>
   监听：<address>:<port>
   域名/SNI：<host-or-sni>
   传输：<network>
```

Omit fields that do not exist. For Direct entries, show the target instead of
credential fields.

## Expected relay display

```text
中转列表（共 N 个）

1. <local-port> -> <remote-addr>:<remote-port>
   类型：direct
   网络：tcp,udp
```

The project stores relay entries as `relay-<local-port>.json`. The native
`relay list` command is also valid; use the helper when a stable, minimal format
or machine-readable verification is needed.

## Bounded log queries

The project's no-argument `sing-box log` follows the access log and blocks. Use
the helper instead:

```text
bash scripts/singbox_inventory.sh logs 100 '' /var/log/sing-box/access.log
bash scripts/singbox_inventory.sh logs 200 error /var/log/sing-box/access.log
```

Rules:

- default to 100 lines and cap a user-supplied limit at 1000;
- filter only the bounded tail when a match string is supplied;
- fail clearly if the log file is absent;
- never start `tail -f` or wait for Ctrl-C;
- treat log lines as potentially sensitive and redact before sending them to the
  user when they contain tokens, credentials, or full share links.

Log level changes such as `sing-box log info`, `none`, or `del` are configuration
changes, not read-only queries. They require a separate explicit request.
