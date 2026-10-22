<div align="center">

# 浙江电信 IPTV · 家庭部署实录

**让家里的老电视和平板，通过 Wi-Fi 使用已开通的 IPTV，同时保留原有上网与设备管控。**

`IPoE` · `RTSP over TCP` · `HTTP 单播` · `iStoreOS / OpenWrt` · `爱快`

[作者 X：@totally2024](https://x.com/totally2024)

[看懂架构](ARCHITECTURE.md) · [部署路线](DEPLOYMENT.md) · [故障排查](TROUBLESHOOTING.md) · [参考与致谢](REFERENCES.md)

</div>

---

> **项目状态：v0.2 可运行实验版 · 2026-10-22**  
> 家庭案例的原有实现已完成无线播放验收；本仓库新增参数化接入客户端、路由维护与 HTTP 视频网关。**公开代码已通过本机隔离模拟测试，尚未在空白 OpenWrt / 真实运营商链路完整验收。** 不承诺跨地区直接通用。

**想实际部署？先看 [可运行版本的完整步骤](RUNTIME.md)。**

## 先用半分钟了解这个项目

这是我把家里的浙江电信 IPTV，从运营商机顶盒的专用接入，整理为**家庭局域网内可供 VLC、Televizo 等播放器使用的 HTTP 单播入口**的实践记录，并附上可配置的实验代码。

我想解决的不是“再搭一套网络”，而是让已有设备更好用：几台 Android 5 / 7 老电视和平板能够无线看直播；普通上网、YouTube 和爱快上的设备管控还能共存；以后换设备、重装软路由时，也能知道每一步为什么要这样配。

## 我家的网络是什么样的？

核心是一台 **J6412 虚拟化主机**，分别运行爱快和 iStoreOS / OpenClash；再通过支持 VLAN 的管理型交换机和华为 AP，连接家里的电视、平板等设备。**N4020 上的飞牛 NAS**是独立的家庭存储模块，不是 IPTV 取流的必要组件。

下面是省略真实 IP、VLAN 编号、端口与账号的**逻辑拓扑**。连线表达职责和业务路径，不是可以照抄的物理接线图。

```mermaid
flowchart TB
    ISP["运营商 / 光猫"]
    SW["支持 VLAN 的管理型交换机"]
    ISP -->|普通上网与 IPTV 业务隔离承载| SW
    subgraph HOST["J6412 · 虚拟化主机"]
        MAIN["爱快<br/>主路由 / 设备与流量管控"]
        SIDE["iStoreOS / OpenClash<br/>DNS / 指定流量代理 / IPTV 网关"]
    end
    SW --- MAIN
    SW --- SIDE
    SW --- AP["华为 AP"]
    AP --- TV["Android 5 / 7 电视"]
    AP --- PAD["平板 / 其他无线终端"]
    SW --- NAS["N4020 · 飞牛 NAS<br/>家庭媒体与存储"]
```

| 组件 | 在这个家庭案例中的职责 |
|---|---|
| 爱快 | 普通上网出口，按设备、时间和应用进行精细管控 |
| iStoreOS / OpenClash | 提供 DNS 与指定流量的代理路径；同机承担 IPTV 专网接入和 HTTP 视频服务，IPTV 不以代理为前提 |
| VLAN 交换机 | 在有线侧隔离和承载不同业务；具体 VLAN 与端口配置需按自己的接线核对 |
| AP 与播放器 | 承担无线接入和视频播放，不要求电视直接处理运营商 IPTV VLAN |

部分受管终端采用**默认网关指向爱快、DNS 指向 iStoreOS**的设置。两者职责不同：DNS 负责名称解析，网关决定普通流量第一跳；只有明确分流的目标才交给旁路由，不能把“DNS 指过去”理解为“所有流量自动经过代理”。相关下一跳与两层专网路由见 [架构说明](ARCHITECTURE.md)。

## 为什么要这样折腾？

- **让已有老电视继续使用。** 希望用电视上的播放器无线看 IPTV，不把每个播放终端都绑定在运营商机顶盒的接线方式上。
- **保留已有网络的分工。** 爱快继续负责设备与应用管控，特定流量按规则交给旁路由，IPTV 则沿专网取流。
- **减少下一次排障和迁移的成本。** 早期资料散在文章、聊天和实验记录中；现在把接入身份、租约、路由、取流、播放与恢复连成完整流程。

最终的视频路径是：

```mermaid
flowchart LR
    IPTV["运营商 IPTV 专网"] -->|RTSP 单播 / TCP interleaved| GW["本地 IPTV 网关"]
    GW -->|HTTP 单播| AP["家庭局域网 / 无线 AP"]
    AP --> PLAYER["电视或平板上的播放器"]
```

**关键区别：无线终端收到的是普通 HTTP 单播视频，不是直接把运营商原始组播铺到 Wi-Fi。** 网关负责接入、路由和转发，不负责视频转码；网络通畅以后，老电视的解码能力仍然会影响播放体验。

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

## 作者与交流

这是我的第一个 GitHub 项目，来自一次真实家庭网络的持续折腾。欢迎通过 [GitHub Issues](https://github.com/bitcoinwizard2013/zhejiang-telecom-iptv-homelab/issues) 分享脱敏后的复现结果，也可以在 X 找到我：**[@totally2024](https://x.com/totally2024)**。

引用过的文章、项目和贡献边界均列在 [参考与致谢](REFERENCES.md)。反馈时请勿附上真实账号、机顶盒身份、认证参数或完整私人配置。
