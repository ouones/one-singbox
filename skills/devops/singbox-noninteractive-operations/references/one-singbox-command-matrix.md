# one-singbox Command Matrix

The wrapper is positional-argument based. Use the installed command through the
remote `terminal` call; do not assume GNU-style `--port` flags.

## Core management commands

```text
v | ver | version
ip
pbk
get-port
ss2022 | ssss
h | help | --help
```

## Node lifecycle

```text
add <protocol> [args... | auto]
info [name]
url [name]
qr [name]
change <name> <option> [args... | auto]
del <name>
ddel <name...>
gen <protocol> [args... | auto]
no-auto-tls <protocol> [args... | auto]
debug [name]
```

The most useful protocol forms are:

```text
add reality [port] [uuid] [sni]
add rh2 [port] [uuid] [sni]
add tuic [port] [uuid]
add trojan [port] [password]
add hy | hy2 [port] [password]
add ss [port] [password] [method]
add socks [port] [username] [password]
add tcp | ws | http | quic [port] [uuid]
add wss | h2 | hu [host] [uuid] [/path]
add vws | vh2 | vhu [host] [uuid] [/path]
add tws | th2 | thu [host] [uuid] [/path]
add anytls [port] [password] [domain]
add direct | door [port] [remote-addr] [remote-port]
add snell [port] [psk] [version]
```

Supported full protocol names include TUIC, Trojan, Hysteria2, VMess-WS,
VMess-TCP, VMess-HTTP, VMess-QUIC, Shadowsocks, VMess/VLESS/Trojan H2/WS/
HTTPUpgrade TLS, VLESS-REALITY, VLESS-HTTP2-REALITY, AnyTLS, Socks, Direct,
and Snell. Use the current target's `sing-box help` if the installed script is
newer than this matrix.

`auto` clears the corresponding positional value and lets the script generate a
value. For TLS protocols, the host/domain still needs to be supplied. Snell v6
requires a core version of at least 1.14.0.

## Change options

Canonical form:

```text
change <name> full [...]
change <name> id <uuid|auto>
change <name> host <domain>
change <name> port <port|auto>
change <name> path <path|auto>
change <name> passwd <password|auto>
change <name> key <private-key|auto> [public-key]
change <name> method <method|auto>
change <name> sni <ip|domain>
change <name> new [...]
change <name> web <domain>
change <name> name <new-name>
change <name> psk <psk|auto>
change <name> snell-version <5|6|auto>
change <name> mode <default|unshaped|unsafe-raw|auto>
change <name> obfs <none|http|auto>
```

The wrapper also recognizes direct option aliases such as `id`, `uuid`, `port`,
`passwd`, `password`, `method`, `sni`, `rename`, and `name`. Prefer the canonical
`change <name> <option> ...` form in automation.

`name` changes the share-link label stored under `.quan-meta`; it does not rename
the JSON file. Inventory must display the metadata label when present and fall
back to the JSON basename otherwise.

## Relay lifecycle

```text
relay add <local-port> <remote-addr> <remote-port>
relay list
relay info <local-port>
relay delete <local-port>
```

The source also accepts `relay del` and `relay rm` as deletion aliases. There is
no native `relay change`; the skill must implement modification as a verified
delete-and-recreate transaction with restoration on failure.

## Runtime and maintenance

```text
dns <selector|set> [value]
status
start
stop
restart [caddy]
test
bbr
log [trace|debug|info|warn|error|fatal|panic|none|del]
update [core|sh|caddy] [version]
update.sh
reinstall
uninstall
import
fix [name]
fix-all
fix-caddyfile
fix-config.json
```

Do not include update, reinstall, uninstall, or firewall changes in an ordinary
node operation unless the user explicitly requests them.

## Core pass-through

The wrapper supports `bin ...` for direct core invocation and direct forwarding
of these core command names:

```text
bin
check
completion
format
generate
geoip
geosite
merge
rule-set
run
tools
```

Examples:

```text
sing-box bin help
sing-box generate uuid
sing-box check -c /etc/sing-box/config.json -C /etc/sing-box/conf
```
