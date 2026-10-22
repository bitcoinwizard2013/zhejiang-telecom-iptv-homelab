# 参考资料与致谢

[返回首页](README.md)

本方案建立在已有的公开研究和工具之上。下表说明具体借鉴范围；本文档不是这些文章的转载，仓库没有复制其代码、完整教程或频道清单。

| 来源 | 作者 / 项目 | 与本仓库的关系 |
|---|---|---|
| [浙江杭州电信 ITV 抓包研究 Part 1 · #44](https://github.com/luckyyyyy/blog/issues/44) | luckyyyyy | 早期直接参考：IPTV 接入、DHCP 参数、Option 60 与接口配置研究 |
| [浙江杭州电信 IPTV 融合教程（2024版）· #75](https://github.com/luckyyyyy/blog/issues/75) | luckyyyyy | 早期直接参考：IPoE 接入、业务融合及 RTSP 源线索；参数需按地区核实 |
| [rtp2httpd](https://github.com/stackia/rtp2httpd) | stackia 与贡献者 | 相关现成实现，支持组播/RTSP/HTTP 转发；早期探索过组播路径。当前项目功能不能按旧印象判断 |
| [rtp2httpd URL 格式说明](https://rtp2httpd.com/guide/url-formats) | rtp2httpd 项目 | 当前 RTSP→HTTP 及播放器入口的官方说明；是后续对照与复现的候选工具 |
| [Multicast Considerations over IEEE 802 Wireless Media · RFC 9119](https://datatracker.ietf.org/doc/rfc9119/) | IETF | 用于解释原生无线组播限制与单播替代思路，不作为本案例接入参数来源 |

## 本仓库整理的内容

家庭部署链路与职责划分、不同尝试的结果与证据边界、代理/路由共存提醒、终端兼容经验，以及脱敏维护流程。定制运行脚本尚未作为公开代码发布。

## 如何继续引用

引用本仓库的整理内容时，建议同时保留所依赖的上游资料链接。若以后引入上游代码，必须单独核对具体文件许可证，保留其版权与许可要求；不能因为附上链接，就将别人的代码改用本仓库许可证。

## 链接维护

外部项目会更新，页面也可能失效。请注明你实际使用的版本和访问日期，不把本仓库的案例结果当作上游作者承诺。
