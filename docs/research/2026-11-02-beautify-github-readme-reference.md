# beautify-github-readme 作为 README 改写参考

调研日期：2026-11-02

范围：对照 oil-oil/beautify-github-readme 的 README 与 skill 指南，以及本仓库 README 和命令实现；未改项目 README，未运行测试。

## 结论

**适合作为信息组织和事实核对的参考，不适合照搬它的页面模板。** 上游建议先读真实仓库、提炼价值与证据，再决定阅读顺序；命令、说明和链接留在可搜索、可复制的 Markdown 中。[上游 README](https://github.com/oil-oil/beautify-github-readme/blob/main/README.md#L58-L73) 它给出的结构是：一句话价值、真实证明、项目说明、机制差异、工作方式、安装与首条命令、相关限制；还建议把示例放在长解释之前，并删掉重复承诺和无助于采用的内部细节。[上游 skill 指南](https://github.com/oil-oil/beautify-github-readme/blob/main/skills/beautify-github-readme/SKILL.md#L74-L83)

## 可借鉴之处与不适用之处

- **可借鉴：** 用实际菜单、命令或输出证明功能；按“是什么、怎样开始、有哪些重要限制”组织内容；功能和兼容性只写源码能支持的事实。上游强调项目事实先行、不能虚构功能，并把说明和命令留在 Markdown，而非把整份 README 变成不可搜索的图片。[上游 skill 指南](https://github.com/oil-oil/beautify-github-readme/blob/main/skills/beautify-github-readme/SKILL.md#L24-L29) [上游 README](https://github.com/oil-oil/beautify-github-readme/blob/main/README.md#L66-L73)
- **不宜照搬：** 上游本身是 README 设计 skill，首页围绕视觉案例、主题墙和安装 skill 的 `npx skills add` 展开。[上游 README](https://github.com/oil-oil/beautify-github-readme/blob/main/README.md#L1-L30) [安装方式和模式](https://github.com/oil-oil/beautify-github-readme/blob/main/README.md#L90-L105) 本项目是面向 Linux 服务器的 sing-box 安装与管理 CLI；大幅展示墙、营销式首图或 skill 安装路径会偏离用户首先要找的兼容要求和可复制命令。轻量的终端示例或菜单截图可以考虑，但应以真实操作为证据。

## 当前 README 的主要问题

- 开篇和特点清单使用“最好用”“无敌好用”“零学习成本”“不到 1 秒”等无来源承诺（README 第 3–45 行）；协议和功能列表（第 7–31 行）又在后面的帮助全文中重复。
- “帮助”下把服务状态、二维码补装、日志轮转和出站参数限制塞进几个超长段落（第 59–67 行），随后再粘贴完整命令参考（第 71–148 行）。读者难以先找到安装要求或第一条可运行命令。
- 内嵌帮助快照和源码不一致：README 显示 `script v1.0`，而当前入口声明 `v1.37`；README 写导入 `sing-box/v2ray`，源码帮助及导入实现指向 `xray/v2ray`。[README](https://github.com/ouones/one-singbox/blob/9c0fa219159c542b1345917181fda4d31e56716c/README.md?plain=1#L72) [当前入口版本](https://github.com/ouones/one-singbox/blob/9c0fa219159c542b1345917181fda4d31e56716c/sing-box.sh#L4) [README 导入说明](https://github.com/ouones/one-singbox/blob/9c0fa219159c542b1345917181fda4d31e56716c/README.md?plain=1#L116) [运行时帮助](../../src/help.sh#L55-L56) [导入实现](../../src/import.sh#L1-L4) 完整帮助块适合从单一来源维护，避免复制文本逐渐过期。
- 安装前置要求没有清楚呈现：安装脚本要求 root、apt-get/yum/zypper/apk 系列包管理器、systemd 或 OpenRC，以及 amd64/arm64 64 位系统。[install.sh](../../install.sh#L34-L62)

## 建议的 README 顺序

1. **项目是什么：** 一句话说明它安装并管理 sing-box，提供交互菜单和命令行；避免无法核实的最高级宣传。
2. **快速开始：** 先列 root、支持发行版/包管理器、init 系统和架构要求，再放现有安装命令；给出 `sing-box`、`sing-box help` 和一两个常见流程作为入口。[安装前置条件](../../install.sh#L34-L62)
3. **常用功能：** 按工作流归类节点新增/修改/查看/删除与分享、节点出站方式、TCP/UDP 端口中转、服务维护；以 `add snell`、`c <name> outbound`、`relay add/list/info/delete` 等当前帮助中的语法作示例。[常用命令](../../src/help.sh#L18-L28) [中转命令与限制](../../src/help.sh#L57-L64) [命令分发](../../src/core.sh#L4665-L4684)
4. **协议与边界：** 用简短表格归类节点协议；单列 Snell 分享格式、二维码行为、日志上限、中转无内置认证等用户确实需要知道的边界。复杂的代理参数兼容矩阵留给外部详细文档或可折叠参考；服务状态不代表外网连通性。[README 中的二维码、日志和出站说明](https://github.com/ouones/one-singbox/blob/9c0fa219159c542b1345917181fda4d31e56716c/README.md?plain=1#L59-L67) [中转安全提示](../../src/help.sh#L63-L64)
5. **完整命令、文档与支持：** README 保留常用命令，把完整 `help` 和细节指向在线文档；附问题反馈和许可证入口。执行操作的示例应先于长篇解释，图片无法加载时正文仍需自足。[上游结构建议](https://github.com/oil-oil/beautify-github-readme/blob/main/skills/beautify-github-readme/SKILL.md#L93-L103) [上游预览检查建议](https://github.com/oil-oil/beautify-github-readme/blob/main/skills/beautify-github-readme/SKILL.md#L131-L144)
