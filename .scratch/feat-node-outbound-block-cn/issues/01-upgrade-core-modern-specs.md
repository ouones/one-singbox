## Parent

#76

## What to build

消除 sing-box 1.14+ 现代内核下的语法弃用警告，使核心配置生成规范与官方最新路由模型完全对齐：
- 在公共配置顶层受管注入 `http_clients` 规范（指定直连分流），替代已在 1.14 弃用的 `download_detour: "direct"`。
- 淘汰旧式 `{tag: "block", type: "block"}` 受管出站对象，中国路由及私网拦截动作全面演进为现代路由动作 `action: "reject"`。
- 清理所有相关生成逻辑中对已淘汰字段与出站的依赖。
- 配套提供测试验证，断言配置检查通过且无弃用告警。

## Acceptance criteria

- [ ] 生成的公共配置中不再出现 `download_detour` 字段，改由顶层 `http_clients` 受管分流提供规则集下载
- [ ] 生成的公共配置中不再出现 `type: "block"` 的受管出站对象
- [ ] 中国路由（geosite-cn / geoip-cn）及私网拦截规则均采用 `action: "reject"` 形式声明
- [ ] 执行 `sing-box check` 能够通过 1.14.x 内核的严格校验，且控制台不输出弃用警告
- [ ] 现有测试套件持续通过，并补充针对现代化配置语法的单元测试

## Blocked by

- None (can start immediately)
