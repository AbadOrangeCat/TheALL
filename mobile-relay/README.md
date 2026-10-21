# TheAll 手机公网中继

这是可自行部署的单 Mac 中继：手机直接用 Safari / Chrome 打开 Web App；Mac 主动建立到服务器的 WSS 连接。手机不需要安装 VPN、Tailscale 或其他联网工具，家庭路由器也不用开入站端口。

当前目录只提供代码和部署文件，尚未部署任何公网服务。同一 Wi-Fi 测试可先用 TheAll 设置中的「局域网直连」，无须部署本中继；见 [手机连接指南](../docs/mobile-access.md)。外网中继正式使用需要一台你可管理、能开放 80/443 的服务器，以及指向它的域名或子域名。Mac 需要保持唤醒并运行 TheAll。没有自己的服务器时，可以先准备这些资源，再按下面步骤部署。

```text
手机 Safari / Chrome ── HTTPS ──┐
                              ├── Caddy ── Node 中继（仅内存）
Mac 上的 TheAll ─────── WSS ───┘              │
    └── 工作空间、聊天历史、API 凭据、AI CLI 均保留在 Mac
```

中继是受信任的基础设施：TLS 在你部署的服务器上终止，服务器管理员可以访问经过它的流量。这不是端到端加密方案。正常实现不记录请求、Cookie、配对码或聊天正文，不保存业务数据；Caddy 只保存 HTTPS 证书和配置。请不要把这份配置放在不可信的公共中继上。

## 部署前准备

1. 一台安装 Docker Engine 和 Docker Compose v2 的 Linux 服务器，建议至少 1 GB 内存。
2. 一个域名，例如 `theall.example.com`，DNS A 记录指向服务器公网 IPv4。只有服务器正确配置了 IPv6 时才添加 AAAA 记录。
3. 服务器防火墙允许 TCP 80/443；UDP 443 可选，用于 HTTP/3。不需要对外开放 8080。
4. 在 Mac 的 TheAll 手机连接设置中选择公网中继，取得「Mac 公钥」。复制 **32 字节 Ed25519 公钥的 Base64**，不是 API Key，也不是私钥。私钥保留在 Mac。

## Docker Compose 部署

把整个 `mobile-relay/` 目录传到服务器，然后在该目录执行：

```sh
cp .env.example .env
chmod 600 .env
```

编辑 `.env`，填写：

```dotenv
PUBLIC_DOMAIN=theall.example.com
THEALL_MAC_PUBLIC_KEY=从Mac界面复制的Base64公钥
```

`PUBLIC_DOMAIN` 只写域名，不写 `https://`、端口或路径。这个部署提供独立域名根路径，不支持放在已有网站的 `/theall` 子路径。公钥不是秘密，但 `.env` 仍被 Git 和 Docker 构建上下文排除。

检查并启动：

```sh
docker compose config --quiet
docker compose up -d --build
docker compose ps
```

Caddy 会为配置的域名申请并续期 HTTPS 证书。Compose 只发布 Caddy 的 80/443；Node 的 8080 在容器网络内可访问。首次申请失败时检查 DNS、80/443 防火墙和是否已有其他服务占用这些端口。

在 Mac 的 TheAll 中填写 `https://theall.example.com` 并连接。Mac 使用 `wss://theall.example.com/host`，通过随机挑战签名证明它拥有部署公钥对应的私钥。连接成功后，在 Mac 上生成手机配对码，扫描二维码或在手机 Web App 中输入配对码。

手机访问 `https://theall.example.com`：

- iOS / iPadOS：Safari → 分享 → 添加到主屏幕。
- Android：Chrome 菜单 → 安装应用 / 添加到主屏幕。
- 如果安装后的独立 Web App 需要再配对，在 Mac 上生成新的一次性配对码。

## 更新、撤销和停止

更新代码后，在服务器重新构建：

```sh
docker compose pull caddy
docker compose up -d --build
```

重新构建中继会断开现有 WSS，Mac 会重新连接；手机界面会显示断连或未确认请求。中继不重试任何用户操作。手机只在用户明确点击重试时使用原 `requestId` 和 `bootID`，Mac 负责幂等检查。

在 TheAll 中撤销手机设备即可使其 Cookie 失效。更换 Mac 或重置 Mac 私钥后，将新的公钥填入 `.env` 并执行 `docker compose up -d --build`。旧公钥对应的 Mac 将无法连接。每份部署同一时刻只接受一个 Mac；新认证连接会替换旧连接。

停止服务：

```sh
docker compose down
```

保留默认卷可以继续使用原 HTTPS 证书。这里没有聊天数据库需要迁移。不要开启 Caddy access log、`debug`、`log_credentials` 或代理请求日志，否则可能记录原本不落盘的请求元信息。默认配置保留证书/启动诊断，但排除 HTTP 请求错误与访问日志。

## 本地开发与测试

生产环境用 HTTPS。HTTP 仅允许 `localhost`、`127.0.0.1` 或 `[::1]`，用于本机协议测试；手机不能用这个回环地址连接你的 Mac。

```sh
npm ci --ignore-scripts
npm test
```

运行时支持 Node 22 / 24。依赖精确锁定为 `ws@8.22.0`，`package-lock.json` 包含官方 npm 包的完整性校验。Docker 使用 Node 24 Alpine，以非 root 用户运行，不写容器文件系统。请定期更新受支持的 Node 和 Caddy 安全版本并重跑测试。

环境变量：

| 名称 | 用途 | 默认 |
| --- | --- | --- |
| `PUBLIC_ORIGIN` | 精确 HTTPS 根 origin，例如 `https://theall.example.com` | 必填 |
| `THEALL_MAC_PUBLIC_KEY` | 预先登记的 Ed25519 原始 32 字节公钥 Base64 | 必填 |
| `BIND_ADDRESS` | Node 监听地址 | `127.0.0.1` |
| `PORT` | Node 监听端口 | `8080` |

Compose 从 `PUBLIC_DOMAIN` 构造 `PUBLIC_ORIGIN`，并将容器内部监听地址设置为 `0.0.0.0`。不要给 relay 服务添加 `ports` 发布，也不要让另一个代理改写请求的 Host 或 Origin 来绕过检查。Caddy 默认保留原 Host。

`test/swift-fixture.mjs` 是 Swift 集成测试专用入口。它读取 `THEALL_MAC_PUBLIC_KEY`，在 `127.0.0.1` 的空闲端口启动，不读取用户聊天，stdout 仅输出一行 `{"port":12345,"origin":"http://127.0.0.1:12345"}`。收到 SIGTERM/SIGINT 后关闭。

## 故障定位

- `503 Mac offline`：中继可访问，但 Mac 尚未连接、已睡眠或 TheAll 已退出。
- `421 Unexpected host`：请求域名与 `PUBLIC_ORIGIN` 不一致，检查 DNS/代理配置。
- `403 Cross-origin request rejected` / `Same-origin JSON client required`：页面地址或 Origin 不一致，不要跨域调用 API。
- `504 Mac response timed out`：Mac 在 50 秒内没有返回。对于发送等操作，先查看对话状态，再用原请求重试，不要重新生成请求 ID。
- 配对或手机授权错误由 Mac 返回；中继不保存手机会话，不能替代 Mac 授权。
- 没有 Mac 连接时，首次打开页面也会返回离线。已经安装的 Web App 可以显示缓存界面，但不能离线执行任务。

协议、安全边界和限额见 [PROTOCOL.md](PROTOCOL.md)。自动化测试验证真实 WebSocket 挑战签名、重放拒绝、Cookie/正文转发、Host/Origin 检查、断连、超时和资源限额。公网 DNS、真实 ACME 证书申请和手机移动网络仍需在你的部署上验收。

实现参考：[ws 官方文档](https://github.com/websockets/ws)、[Caddy 自动 HTTPS](https://caddyserver.com/docs/automatic-https)、[Caddy reverse_proxy](https://caddyserver.com/docs/caddyfile/directives/reverse_proxy)、[Caddy 日志配置](https://caddyserver.com/docs/caddyfile/options#log)。
