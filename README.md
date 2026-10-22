<div align="center">

# 浙江电信 IPTV · 家庭部署实录

**从专网接入，到无线电视。把零散教程，接成一条可以理解和维护的链路。**

`IPoE` · `RTSP over TCP` · `HTTP 单播` · `iStoreOS / OpenWrt` · `爱快`

[看懂架构](ARCHITECTURE.md) · [部署路线](DEPLOYMENT.md) · [故障排查](TROUBLESHOOTING.md) · [参考与致谢](REFERENCES.md)

</div>

---

> **项目状态：v0.2 可运行实验版 · 2026-10-22**  
> 家庭案例的原有实现已完成无线播放验收；本仓库新增参数化接入客户端、路由维护与 HTTP 视频网关。**公开代码已通过本机隔离模拟测试，尚未在空白 OpenWrt / 真实运营商链路完整验收。** 不承诺跨地区直接通用。

**想实际部署？先看 [可运行版本的完整步骤](RUNTIME.md)。**

## 这个仓库解决什么问题？

普通上网正常，IPTV 却不能直接交给电视上的 VLC、Televizo 等播放器使用：接入认证、专网路由、RTSP 兼容性、无线组播和旁路由配置，可能在不同环节造成失败。

本案例最终采用：**先接入运营商 IPTV 专网，取 RTSP 单播源，再通过本地 HTTP 网关交给家庭终端。** 无线电视收到的是 HTTP 单播视频，而不是直接接收运营商原始组播。

```mermaid
flowchart LR
    ISP["运营商 IPTV 专网"] -->|IPoE 接入| GW["iStoreOS / OpenWrt<br/>IPTV 网关"]
    GW -->|RTSP over TCP 取流| HTTP["本地 HTTP 视频入口"]
    HTTP --> LAN["家庭局域网"]
    LAN --> AP["无线 AP"]
    AP --> TV["电视 / 平板 / 播放器"]
    LAN --- MAIN["爱快主路由<br/>普通上网出口"]
```

**三个关键分工：** 专网接口负责接入；路由决定从哪里取流；HTTP 网关解决终端播放入口。Wi-Fi 只负责最后一段普通单播传输。

## 一眼看懂最终结果

| 项目 | 本案例结果 | 边界 |
|---|---|---|
| IPTV 接入 | IPoE 专网接入成功 | 参数来自自己的已开通业务，不提供通用认证数据 |
| 上游视频 | RTSP 单播，TCP interleaved | 运营商必须提供可访问的对应服务 |
| 终端入口 | 本地 HTTP 播放列表和视频流 | HTTP 列表可读，不等于所有视频流均可播放 |
| 无线播放 | 已在家庭 Wi-Fi 终端使用 | 无线质量、客户端解码及并发容量仍有影响 |
| 老电视 | Android 5 / 7 终端有实际使用记录 | 不代表所有同版本固件、所有播放器均兼容 |
| 网络共存 | 爱快主路由、iStoreOS/OpenClash 环境共存 | 不公开真实网段、策略备份或代理配置 |

验收范围与尚未验证事项见 [VERIFICATION.md](VERIFICATION.md)。

## 它与已有项目是什么关系？

这是一份**现有技术的部署整合与维护实录**。IPoE 接入研究来自前人的公开文章；RTSP→HTTP 也已有成熟实现，例如 [rtp2httpd](https://github.com/stackia/rtp2httpd)。本仓库的重点是把接入、路由、转发、终端和故障恢复连起来，而非宣称发明新协议。

特别注意：历史上尝试某个工具的组播路径失败，**不等于这个工具不支持 RTSP 单播**。现用自建网关与 rtp2httpd 的性能、兼容性尚未做同环境对照测试。参考来源与贡献边界逐项列在 [REFERENCES.md](REFERENCES.md)。

## 按你的问题开始阅读

| 你想解决的问题 | 阅读入口 |
|---|---|
| 为什么 IPTV 已经能用 Wi-Fi？ | [架构：专网、单播与无线](ARCHITECTURE.md) |
| 准备在自己的网络复现 | [部署：按阶段验证](DEPLOYMENT.md) |
| 有列表，但频道打不开 | [排查：按故障层定位](TROUBLESHOOTING.md) |
| 想知道哪些是实测，哪些是推测 | [验收记录与局限](VERIFICATION.md) |
| 想提交问题或分享经验 | [隐私与反馈说明](PRIVACY.md) |
| 想了解原作者和相关项目 | [参考资料与致谢](REFERENCES.md) |

## 可以运行的核心代码

| 组件 | 文件 | 说明 |
|---|---|---|
| DHCP / IPoE 接入 | [iptv_dhcp.pl](iptv_dhcp.pl) | 从私有配置读取自己的身份，校验 OFFER/ACK 与租期 |
| 路由维护与回滚 | [iptv_access.pl](iptv_access.pl) | 默认预览；只管理专用接口和自己添加的明确路由 |
| RTSP→HTTP 网关 | [iptv_gateway.pl](iptv_gateway.pl) | 集成重定向处理、TCP interleaved、MPEG-TS 输出与保活 |
| 安装与启动 | [install.sh](install.sh) / [procd 服务](iptv-homelab.init) | 安装不会自动启动；验证后手动启用 |
| 可复现测试 | [test_runtime.py](test_runtime.py) | 模拟 DHCP、RTSP、HTTP 和路由操作，不触碰真实链路 |

```sh
# 本地电脑：模拟测试，不要求 root，不修改网络接口
python3 test_runtime.py
# 网关：查看安装计划，不实际安装
sh install.sh --plan
```

[完整配置、启动与回滚步骤](RUNTIME.md)使用 [iptv.conf.example](iptv.conf.example) 和 [channels.example.m3u](channels.example.m3u)。旧 `config.example.env` 仅保留为早期参数规划说明，运行程序不读取它。

不包含真实账号、Option 60、家庭设备身份、私人配置或可用频道清单。公开实现不提供认证值生成、DRM 绕过或任意公网转发。

## 快速检查工具

在自己的 Linux/OpenWrt 网关上，先阅读脚本再运行：

```sh
sh doctor.sh
# 可选：检查你自己指定的本地 HTTP 播放列表（会发送一次 HTTP 请求）
sh doctor.sh --playlist 'http://YOUR_GATEWAY:8554/playlist.m3u'
```

默认只检查命令、接口数量和默认路由数量；不打印实际地址、不改配置、不触发续租、不下载视频。播放列表检查仅输出格式摘要，不输出频道 URL。使用方法见 [部署文档](DEPLOYMENT.md#辅助检查)。

## 后续方向

- [x] 发布参数化接入、维护、HTTP 网关及独立测试；保留来源与验证边界。
- [ ] 在空白 OpenWrt 上实测公开版，再与 rtp2httpd 做可回滚的对照测试。
- [ ] 补充多终端并发、长时间播放和重启恢复测试。
- [ ] 收集不同地区、设备的脱敏复现记录。

本仓库原创文档与检查工具采用 [MIT License](LICENSE)。外部文章、项目及其代码保留各自权利和许可证。
