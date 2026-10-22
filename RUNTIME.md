# 可运行实验版：从空白网关到 HTTP 播放

[返回首页](README.md)

> v0.2 / 2026-10-22。这里提供实际运行代码。家庭现网验证过的是原有定制实现；本公开版经过独立整理与本机模拟测试，**尚未在空白 OpenWrt 或真实运营商链路完整验收**。请在备用设备上验证，不直接覆盖正在使用的服务。

## 支持范围

- Linux / OpenWrt / iStoreOS 上一个独立、未桥接、未被其他 DHCP 客户端管理的以太网接口。
- 使用自己的机顶盒 MAC、DHCP Hostname 和 Option 60 原始字节；值只从权限 0600 的本地配置读取，不打印。不是密码破解工具，不提供账号或可通用认证值。
- DHCP DISCOVER/OFFER/REQUEST/ACK、同地址续租；校验事务 ID、MAC、Server Identifier、掩码和租期。REQUEST 使用 DHCP Server Identifier，不把默认网关误当 DHCP 服务器。
- 明确的 IPv4 专网目标路由；不修改默认路由、DNS、NAT、转发或 OpenClash。当前 HTTP 网关自己发起取流，不需要给家庭终端添加专网直连转发。
- RTSP 1.0、IPv4 数字地址、TCP interleaved、单个 MPEG-TS 聚合会话。HTTP 网关自行处理最多 8 次重定向、SETUP/PLAY/OPTIONS/TEARDOWN，剥离 RTP 封装，不转码。
- HTTP `/playlist.m3u` 与 `/channel/N`；只播放本地配置的频道，不接受任意上游 URL。媒体入口限固定频道，重定向目标与端口均须在允许列表内。

暂不支持：UDP 媒体、RTSPS、RTSP Basic/Digest 认证、独立音视频 track 的通用 SDP、H264 裸 RTP 转封装、DRM、IPv6、时移回看、跨频道上游复用、动态生成 Option 60 签名。要求动态认证值的地区需要自己维护身份数据或使用适配的接入实现。不要宣称全国通用。

## 文件分工

| 文件 | 功能 |
|---|---|
| `IptvConfig.pm` | 严格读取本地配置、IPv4/CIDR 校验及状态文件写入 |
| `iptv_dhcp.pl` | 获取与续租，只有显式调用才发送 DHCP；无后台自动接入 |
| `iptv_access.pl` | 预览、接入、按租期维护、移除自己管理的网络配置 |
| `iptv_gateway.pl` | RTSP→HTTP 视频网关，内置重定向处理，无需另一套 RTSP 代理 |
| `iptv-homelab.init` | OpenWrt procd 服务，管理 access 与 gateway 两个进程 |
| `install.sh` | 默认仅预览，显式安装也不会自动启动或开机启用 |
| `test_runtime.py` | 本机回环与替身命令测试，不访问运营商，不改真实接口 |

## 0. 在自己的电脑先跑模拟测试

需要 Python 3 和 Perl；测试只使用回环地址与虚构的文档地址。

```sh
python3 test_runtime.py
sh install.sh --plan
```

测试构造的 MAC、Option 60、视频包、会话和地址都是合成值。`--mock-loopback` 专供模拟 DHCP，不会改为广播或访问 LAN。

## 1. 准备网关与备份

先备份原接口、路由、防火墙及相关服务，保留本地管理入口。选择专用接口；不要选 LAN 桥接成员、WAN 默认路由接口或正在工作的 IPTV 接口。已有标准 DHCP 客户端或原接入维护程序时，应先在备用环境明确停用其中一种，不能两套并行抢租约。

Perl 需要 `Socket`、`Fcntl`、`IO::Socket::INET`、`IO::Select`、`POSIX`。用以下命令检查；缺失时按所用固件的软件包拆分方式安装对应模块。

```sh
perl -MIO::Socket::INET -MIO::Select -MPOSIX -MFcntl -MSocket -e 'print "modules available\n"'
```

网络工具为 `/sbin/ip`，可通过 `IP_BINARY` 指定本机路径。安装器只支持 OpenWrt/iStoreOS；其他 Linux 可手工运行脚本，但启动与防火墙需自行适配。

## 2. 安装代码，不启动

升级已安装的公开实验版时先停止其服务；首次安装或停止后，在网关上的解压目录执行：

```sh
sh install.sh --plan
sh install.sh --apply
```

显式安装只写 `/opt/iptv-homelab/`、示例配置和 `/etc/init.d/iptv-homelab`；旧版包文件按时间保存。不会复制你的账号数据，也不会启动或 enable 服务。

## 3. 填写自己的本地配置

```sh
cp /etc/iptv-homelab/iptv.conf.example /etc/iptv-homelab/iptv.conf
cp /etc/iptv-homelab/channels.example.m3u /etc/iptv-homelab/channels.m3u
chmod 600 /etc/iptv-homelab/iptv.conf /etc/iptv-homelab/channels.m3u
```

用本地编辑器填写参数；配置为普通 `KEY=value`，不加引号、不支持变量展开，不会作为 shell 脚本执行。

| 参数 | 需要填写什么 |
|---|---|
| `IPTV_INTERFACE` | 自己确认的独立 IPTV 接入接口 |
| `STB_MAC_HEX` | 自己机顶盒 MAC 的 12 位十六进制，不带冒号；不是光猫 MAC |
| `DHCP_HOSTNAME` | 自己业务需要的 Hostname；可留空 |
| `OPTION60_HEX` | 自己业务的 Option 60 值，不含选项编号和长度字节；不得使用示例假值 |
| `IPTV_PREFIXES` | 已确认要走专网的目标网段，逗号分隔；不包含默认路由 |
| `UPSTREAM_CIDRS` / `UPSTREAM_PORTS` | RTSP 入口与可能重定向到的服务器范围及端口；按实际最小范围填写 |
| `HTTP_BIND` | 默认回环；供电视使用时改成自己的家庭 LAN IPv4，不允许通配监听或公网地址 |
| `HTTP_BASE` | 与家庭入口一致的 `http://家庭网关地址:端口`，用于生成绝对播放地址；不会反射请求 Host |
| `CLIENT_CIDRS` | 允许播放的家庭终端范围；默认仅回环 |
| `SOURCE_M3U` | 本地实际频道表路径；RTSP 地址要在允许范围内 |
| `STATE_FILE` | 专用运行状态路径；其目录必须私有，不能与其他服务复用 |

`channels.example.m3u` 全是文档占位地址，没有可播放频道。使用自己有权使用的源，只保留 `#EXTINF` 和其后的 `rtsp://数字地址:端口/路径`。网关不会接受用户密码 URL、主机名或任意外部媒体地址。

本地使用防火墙限制入口来源，不配置 WAN 端口映射。HTTP 服务不含用户认证或 TLS，因此不能当成公网服务使用。

## 4. 分步接入和播放

先预览，再显式改变专用接口。以下 `--apply` 会改变该专用接口的 MAC、启用接口、获取租约，并添加所需地址和明确目标路由。

```sh
perl /opt/iptv-homelab/iptv_access.pl --plan /etc/iptv-homelab/iptv.conf
perl /opt/iptv-homelab/iptv_access.pl --apply /etc/iptv-homelab/iptv.conf
```

预期输出 `access_ready`；它只表示接入/路由阶段完成，尚未验证视频。冲突时会拒绝接管已有地址/路由，初次失败会尝试撤销本次新增项并恢复接口 MAC/启用状态；仍需本地检查恢复结果，不能替代整机备份。

再在前台运行网关：

```sh
perl /opt/iptv-homelab/iptv_gateway.pl /etc/iptv-homelab/iptv.conf
```

预期输出 `gateway_ready`。打开自己的 HTTP 播放列表，选择实际频道播放；正常画面与声音是本阶段验收。前台 Ctrl-C 停止网关。

## 5. 验证后才启用服务

先停止前台网关，再启动 procd。服务里的 access 每 30 秒检查状态；在 T1 到来前不重复续租。租约仍有效时，失败重试保留旧地址与旧路由；租约已过期且续租失败时，会尝试移除自己管理的接入状态，下一轮重新获取，避免长期占用过期地址。

```sh
/etc/init.d/iptv-homelab start
# 实际播放与重启恢复验收通过后，再决定开机启用：
/etc/init.d/iptv-homelab enable
```

若 ACK 的地址/网关发生变化，实验版会保留旧状态并拒绝自动迁移。发生 NAK、长期无响应或租约变化时，按下一节先停止服务、移除自己的配置后重新接入；它尚不包含所有 DHCP 状态机和故障恢复策略。

## 6. 停止和回滚

```sh
/etc/init.d/iptv-homelab stop
/etc/init.d/iptv-homelab disable
perl /opt/iptv-homelab/iptv_access.pl --remove /etc/iptv-homelab/iptv.conf
```

`stop` 本身保留网络配置；`--remove` 才按私有状态文件移除自己添加的地址/目标路由，并恢复原 MAC/启用状态。存在未管理地址、外部变更或路由冲突时拒绝删除，需人工核对。不要为了强行回滚去清空接口或删除其他服务的配置。

如需恢复原网关软件，使用安装前备份；包文件的时间备份只覆盖此前本包代码，不包含完整系统配置。也没有自动还原 OpenClash、防火墙或主路由的能力，因为本程序未修改它们。

## 错误处理

日志输出错误类别，不打印账户、Option 60、MAC、上游 URL 或会话参数。`502` 可能来自上游地址不在允许列表、超时、RTSP 状态错误、CSeq 不一致或媒体格式不支持。先在本地逐层排查，不公开原始请求/应答。
