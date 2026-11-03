# 手把手准备 Nginx SNI 分流

本教程适用于 **Debian 11 及以上或 Ubuntu 24.04，使用 systemd 和对应系统的官方软件源**。安装命令使用系统自带的软件包；实际安装测试范围见文末。请先以 root 用户登录后执行本教程中的命令。需要让多个普通 VLESS-REALITY 节点共用公网 TCP 443 时，按下面步骤操作。不需要共用 443 时，保持关闭即可。

面板只管理 Reality 节点的分流映射，不管理网站、证书或网站反向代理。如果服务器已有网站，请先看下面的第 1 步；不要为了启用分流而直接更改线上网站。

## 1. 查看服务器和 Nginx

复制执行：

```bash
cat /etc/os-release | head -n 2
if command -v nginx >/dev/null 2>&1; then nginx -v; else echo '尚未安装 Nginx'; fi
ss -lntp '( sport = :443 )'
```

按输出选择下一步：

- **显示 Debian 11 或更高版本、Ubuntu 24.04，且尚未安装 Nginx：**继续第 2 步。
- **已经安装 Nginx：**跳过第 2 步，直接到第 3 步。不要运行本教程的安装命令覆盖已有部署。
- **其他系统、其他软件源或不清楚安装来源：**先不要运行第 2 步的命令；请在[项目问题反馈](https://github.com/ouones/one-singbox/issues)中提供系统版本和 Nginx 安装方式。

最后一条命令列出 TCP 443 的监听进程。如果是正在使用的网站，先不要改动：当前功能不会自动迁移直接监听公网 443 的网站。已有 one-singbox 的 443 节点则需要在启用时一并迁移。

## 2. 安装并启动 Nginx

**仅在第 1 步确认未安装 Nginx，且使用对应系统官方软件源时执行。**下面一条命令会安装 Nginx 和 stream 动态模块，并启动 Nginx：

```bash
apt-get update && apt-get install -y nginx libnginx-mod-stream && systemctl start nginx
```

等待命令结束。如果出现错误，先不要继续；把完整错误信息提交到[项目问题反馈](https://github.com/ouones/one-singbox/issues)。安装软件包可能启动或重载系统服务，请在适当的维护时间执行。

## 3. 检查服务和配置

复制执行：

```bash
systemctl is-active nginx
nginx -t
```

第一条输出 `active`、第二条包含 `test is successful`，就继续下一步。如果服务或配置检查失败，先不要启用分流；保存屏幕上的错误，到[项目问题反馈](https://github.com/ouones/one-singbox/issues)寻求帮助。

Nginx 的 `stream` 和 `ssl_preread` 是分流所需能力，可能内置，也可能通过动态模块提供。已有 Nginx 用户不必先猜模块是否齐全；下一步由面板检查。不要混装不同软件源的 Nginx 和模块包。

## 4. 检查环境并启用

1. 运行 `sb`，选择首页的 **443 SNI 前置**。
2. 选择 **检查 Nginx 环境**。看到“检查通过”后，按回车返回菜单。
3. 选择 **启用 Nginx SNI 分流**。
4. 面板询问 IP 地址类型时：只使用 IPv4 选 IPv4；只使用 IPv6 选 IPv6；两种都要使用时选两者。按实际显示的选项编号输入。
5. 如有现有公网 443 节点，按提示输入显示的**全部**节点文件名，以空格分隔；没有旧节点则直接继续。已有节点必须是受支持的普通 VLESS-REALITY。
6. 出现启用成功后，选择 **查看状态**确认。如果绑定节点数为 0，还需要添加符合要求的节点，分流才会有节点可转发。

每个受管理节点需要不同的精确 Reality SNI 域名，不支持通配符或 `sni auto`。同时在防火墙和云安全组中放行所选地址类型的公网 TCP 443，再使用外部客户端测试连接。

启用会检查并重载整个 Nginx 实例，可能同时加载之前编辑但尚未生效的网站配置，并造成短暂断连。面板检查通过不代表公网连接已验证。

## 遇到问题怎么办

### 提示 `modules-enabled/*.conf` 未匹配到文件

这个目录保存动态模块的加载配置；目录为空可能是正常情况，**不代表 Nginx 没有安装**。当前面板可能因为空通配目录停止检查，这是面板的兼容性限制。不要为绕过提示删除配置或随意创建文件。请把提示和下面命令的输出提交到[项目问题反馈](https://github.com/ouones/one-singbox/issues)：

```bash
ls -la /etc/nginx/modules-enabled/
nginx -t
```

### 提示缺少 stream 或 ssl_preread

- 按第 2 步使用系统官方软件源新安装的用户：复制错误提示提交到[项目问题反馈](https://github.com/ouones/one-singbox/issues)。
- 已有 Nginx 的用户：先确认其安装来源及对应模块的安装方式；不要直接执行第 2 步的安装命令替换现有部署。无法确认时，提交错误提示和系统版本寻求帮助。

### 提示 TCP 443 被占用

回到第 1 步查看监听进程。若是 one-singbox 的旧节点，启用时选择全部节点；若是网站或其他服务，不要停止服务或改配置来强行启用。当前功能不会自动迁移已有网站或接管其他服务。

### 需要提供配置排查

```bash
nginx -T
```

此命令会输出完整配置。发送前请隐藏域名、IP、凭据和其他敏感信息。

若网站也要共用公网 443，网站分支、后端和证书必须自行配置，面板不会自动创建网站分流规则。更多限制见[使用说明](usage.md#443-sni-前置)及[验证与支持状态](nginx-reality-frontend-support.md)。

本教程的软件包名称已核对 Debian 11、12、13 的官方软件包列表和 Ubuntu 24.04 软件源；这不代表已在上述所有系统上完成实机安装与公网连接测试。
