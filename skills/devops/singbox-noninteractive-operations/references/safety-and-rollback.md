# Safety and Rollback

## Operation classes

### Read-only

- SSH and platform preflight;
- existing installation inspection;
- node and relay inventory;
- `info`, `url`, `qr`, `status`, `relay list`, `relay info`;
- bounded log reading.

Read-only operations can run without confirmation, but still need a precise host
and bounded output.

### Mutating

- installation;
- node creation, rename, or modification;
- relay creation or modification;
- service restart caused by one-singbox;
- log-level changes.

For an explicit user request, execute the requested mutation after preflight and a
scope preview. If the target, port, protocol, or replacement value is ambiguous,
stop rather than choosing.

### Destructive

- node deletion;
- relay deletion;
- reinstall or uninstall;
- deleting log files.

Always show the exact target and request confirmation immediately before a
 destructive action. Never turn a fuzzy name match into a delete operation.

## Node create and modify

Before `add`:

1. inventory existing nodes;
2. check the requested port and protocol;
3. detect a same-port or same-file collision;
4. show the exact positional command with secrets masked;
5. execute only after the scope is unambiguous.

After `add` or `change`:

1. query the exact node again;
2. run the core configuration check;
3. verify the service and relevant listener;
4. inventory again and compare the expected count and fields.

The wrapper may restart sing-box automatically. A successful command exit code is
not enough; the service and configuration must be read back.

## Node rename

Use:

```text
sing-box change <name> name <new-name>
```

Verify both of these facts:

- the custom label is now returned by inventory and URL metadata;
- the original JSON filename still exists.

Do not describe this operation as a filesystem rename.

## Relay modification transaction

The project has no native relay-change operation. Use this transaction:

1. `relay info <local-port>` and save the old address/port in the current task;
2. check the new target and display old versus new;
3. confirm the mutation;
4. `relay delete <local-port>`;
5. `relay add <local-port> <new-addr> <new-port>`;
6. `relay info <local-port>` and `relay list`;
7. if creation or validation fails, recreate the old tuple;
8. verify the restored tuple and service state.

Never claim the new target is active until the post-add query and core/service
checks pass.

## Secrets and output

Mask these values in reports and inventories:

```text
UUID
password
PSK
Private key
Public key when paired with a private key
complete vless://, vmess://, trojan://, ss://, snell://, or socks:// URL
```

A user can explicitly request a credential value, but do not copy a redacted or
truncated value back into a command. Do not put SSH passwords or private keys in
shell history, process arguments, or generated skill output.

## Failure reporting

Report the verified state, not the intended state:

```text
目标：<hostname>
动作：<operation>
结果：成功 / 失败 / 已回滚
变更：<non-sensitive fields>
验证：<fresh checks>
副作用：<automatic restart or service change>
阻塞：<exact evidence, if any>
```
