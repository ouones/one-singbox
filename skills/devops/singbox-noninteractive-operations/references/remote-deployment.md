# Remote Deployment

This skill operates `ouones/one-singbox` on a remote VPS. Every command in this
reference is a command to run through Hermes `terminal`; replace `<target>` with
the already-resolved SSH target and do not invent credentials.

## 1. SSH and platform preflight

Run a non-interactive probe first:

```text
terminal(command="ssh -o BatchMode=yes -o ConnectTimeout=8 <target> 'hostname; id -u; uname -m; uname -s; cat /etc/os-release'")
```

Then check the deployment prerequisites in one bounded remote call:

```text
terminal(command="ssh -o BatchMode=yes -o ConnectTimeout=8 <target> 'command -v bash || true; command -v wget || true; command -v tar || true; command -v jq || true; command -v systemctl || true; command -v rc-service || true; command -v apk || true; command -v apt-get || true; command -v ss || true; command -v netstat || true; getent hosts raw.githubusercontent.com || true; getent hosts github.com || true'")
```

Record:

- hostname and `/etc/os-release`;
- root status and CPU architecture;
- systemd versus OpenRC;
- package manager and required tools;
- IPv4/IPv6 and DNS reachability;
- whether GitHub and raw GitHub endpoints resolve and connect;
- existing `/etc/sing-box`, `/etc/sing-box/conf`, service, Caddy, and listening ports.

Do not interpret a successful SSH connection to a port-forwarding endpoint as proof
that the intended VPS was reached; the hostname check is mandatory.

## 2. Existing installation guard

Before installing, run a read-only check:

```text
terminal(command="ssh <target> 'printf \"wrapper=\"; command -v sing-box || true; printf \"root_dir=\"; test -d /etc/sing-box && printf yes || printf no; printf \"service=\"; if command -v systemctl >/dev/null; then systemctl is-active sing-box 2>/dev/null || true; elif command -v rc-service >/dev/null; then rc-service sing-box status 2>/dev/null || true; fi'")
```

If an installation exists, inventory it before any reinstall. A user request to
“deploy” does not authorize silently replacing an existing service or deleting
existing nodes.

## 3. Standard online installation

Use the repository installer only after the preflight confirms root, a supported
64-bit architecture, bash, a usable package manager, a service manager, and a
reachable download path:

```text
terminal(command="ssh <target> 'bash <(wget -qO- -o- https://github.com/ouones/one-singbox/raw/main/install.sh)'")
```

For a user-selected core version, pass the explicit installer option:

```text
terminal(command="ssh <target> 'bash <(wget -qO- -o- https://github.com/ouones/one-singbox/raw/main/install.sh) -v <version>'")
```

Do not pipe guessed answers into prompts. The installer's supported options are
`-f/--core-file`, `-l/--local-install`, `-p/--proxy`, `-v/--core-version`, and
`-h/--help`; `--core-file` and `--core-version` are mutually exclusive.

## 4. Restricted network and IPv6-only path

Use this path when the target cannot reach GitHub releases, has broken DNS, or
is an Alpine/OpenRC host where the standard assumptions do not hold:

1. Download the required release assets on a machine with working connectivity.
2. Verify the downloaded file size and archive contents locally.
3. Transfer it through the existing SSH path using an explicit destination.
4. Install only the required remote dependencies (`bash`, `jq`, `tar`, and the
   target's service tools).
5. Use the installer `-f/--core-file` path when its remaining assumptions hold;
   otherwise follow the host's OpenRC service path and document the deviation.
6. Verify the binary, service, configuration, and listening port on the target.

For Alpine, check `apk`, `rc-service`, and `rc-update`; for systemd hosts, check
`systemctl` and run a configuration test before starting or restarting a service.
Do not assume a GNU binary or a systemd unit works on musl/OpenRC.

## 5. Post-install verification

Run all checks remotely and read back their output:

```text
terminal(command="ssh <target> 'sing-box version; sing-box status; test -d /etc/sing-box/conf; test -f /etc/sing-box/config.json'")
```

When the core is installed, verify the runtime configuration with the project's
supported core pass-through rather than editing JSON blindly:

```text
terminal(command="ssh <target> 'sing-box check -c /etc/sing-box/config.json -C /etc/sing-box/conf'")
```

Then check the actual service manager and listening sockets. A process existing
without a valid configuration or expected listener is not a successful deploy.

## 6. First node

Only after post-install verification, create the requested node with complete
positional arguments. For example:

```text
terminal(command="ssh <target> 'sing-box add reality 443 auto <sni-domain>'")
```

Immediately perform an exact query and a service/listener check. If the request
omits a TLS domain or leaves an ambiguous target, stop for clarification instead
of feeding an interactive prompt.
