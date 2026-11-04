# HackDigest

把 Hacker News 读成中文 —— 为「看得懂英文、但读不痛快」的开发者做的 HN 阅读器。

[![CI](https://github.com/turlamai/hackdigest/actions/workflows/ci.yml/badge.svg)](https://github.com/turlamai/hackdigest/actions/workflows/ci.yml) [![License](https://img.shields.io/badge/license-AGPL--3.0-blue)](LICENSE)

[English](README.md) · **中文**

Hacker News 大概是互联网上最好的技术首页 —— 但对数以百万计的开发者来说，它也是一堵英文墙。HackDigest 拆掉这堵墙：每一条新闻、每一篇原文、每一个评论楼，按需翻译、按需总结。

## 开始使用

全部客户端功能可免费使用自己的模型密钥，模型费用另计。托管翻译尚未开放购买。 基于 Glaze 的 macOS、Windows、Linux 桌面预览。原生传输、打包行为和密钥存储一致性仍需发行验收。

[安装、首次使用、隐私与备份恢复](docs/USER-GUIDE.zh-CN.md) · [English](docs/USER-GUIDE.md)

## 下载

到 [GitHub Releases](https://github.com/turlamai/hackdigest/releases/latest) 取最新版本 —— 所有产物由 GitHub CI 从源码构建，并在三平台上通过打包原生自检（生产 transport）与 HTTP 适配器冒烟验证：

| 平台 | 产物 |
|---|---|
| macOS（Apple Silicon / Intel） | `hackdigest-<version>-macos-<arch>.dmg` + 便携 `.zip`（双架构齐备） |
| Linux（x64 / arm64） | `hackdigest-<version>-linux-<arch>`：`.tar.gz` + `.deb` + `.rpm` + `.AppImage` + 便携 `.zip` —— 每种格式双架构都有 |
| Windows 10/11（x64） | `hackdigest-<version>-windows-x64.msi` + 便携 `.zip` |

每个二进制产物都附带同名的 `.sha256` 校验文件，并汇总为 `SHA256SUMS`。

> macOS 构建为 ad-hoc 签名、未公证：首次启动请右键 → 打开。Windows MSI 未签名，首次安装时 SmartScreen 可能告警 —— 选择「仍要运行」。

翻译与 Digest 需要一个大模型 API Key —— 在设置里填一个（GLM、DeepSeek、通义、Kimi、OpenAI，或本地 Ollama，均为 OpenAI 兼容接口）。

应用内更新自 v0.3.0 起内置：启动时从 GitHub Releases 拉取 Ed25519 签名清单，macOS 与 Windows 的便携安装原地换装（自动重启）；Linux 下载归档后在文件管理器中呈现，手动解压覆盖 —— 这是家族对归档安装的统一规则。安装器渠道（DMG / MSI / deb / rpm）则引导你前往 Releases 页 —— 这类安装没有提权无法自我改写。

## 键盘优先

HN 老用户的肌肉记忆全部保留：**j/k** 上下移动选中，**Enter/o** 打开，**s** 收藏，**t** 快翻选中标题，**r** 刷新，**1–6** 切换信息流，**/** 搜索。详情页：**←/u** 返回，**t** 翻译本帖，**Shift+T** 翻译全部评论，**d** AI 摘要。随时按 **?** 呼出速查表。

## 三层 Digest

1. **文章 Digest** —— HN 链接的原文动辄五千词英文，压缩成几段中文摘要。
2. **评论区 Digest** —— HN 的精华在评论区。八百条回复提炼成「正反双方的核心论点、谁说了什么、社区的最终倾向」。
3. **每日 Digest** —— 今早的首页变成两分钟中文晨读，再决定哪条值得点开。

## 免费与托管计划

客户端全部能力可自带模型 key 免费使用，服务商自身费用与限额适用。托管翻译/摘要为有配额的订阅规划，尚未开售；不再出售终身托管、不按设备发永久试用，首发不包含移动端或跨设备同步。目标价格、账户配额、长度边界和成本门禁见 [PRICING.md](PRICING.zh-CN.md)。应用内的托管配置面（设备试用、桌面激活）已在托管未开售期间移除，旧托管设置会自动映射为可用的自定义端点；当前先完成密钥安全存储；手机不是前置门禁。

## 技术栈

**Glaze（Racket 后端）+ React + TypeScript**，单仓库，`backend/` + `apps/desktop/` + `packages/core`（HackDigest 是内容型应用：文章页、富文本评论树、排版，而内容渲染，web 引擎就是最好的文本引擎；应用壳、存储、LLM 代理与更新检查住在 [Glaze](https://github.com/turlamai/glaze) 驱动的 Racket 后端里）。

- `packages/core` —— 纯 TypeScript，全端复用：HN API 客户端（官方 Firebase API + Algolia 搜索）、任意 OpenAI 兼容端点的 BYOK 预置（GLM、DeepSeek、通义、Kimi、OpenAI、Claude……，国内用户可直连国产 API），以及组件依赖的存储/设置层。
- 前端 —— React + Vite + zustand + Tailwind 4，渐进加载的评论树与信息流，深浅色；应用内经原生 GLZ1 消息通道与后端通信（不走 TCP 端口），`HACKDIGEST_TRANSPORT=http` 保留为显式开发适配器，纯浏览器 dev 保留 IndexedDB 兜底。
- 后端 —— Racket：SQLite 存储（kv、翻译缓存、HN 条目缓存 —— 同一帖子的翻译绝不重复翻译）+ settings/library JSON 文件。翻译/Digest 管线（提示词构建、30 条标题批、评论自愈二分）在这里跑，BYOK 的 API Key 只存在后端、页面碰不到；LLM 调用经后端代理流式返回，带重试与 60 秒超时。
- 网络 —— HN 数据直接来自官方 [Hacker News API](https://github.com/HackerNews/API) 与 Algolia 搜索 API —— 不爬虫。
- 更新 —— 后端启动时拉取 Ed25519 签名更新清单，按签名清单校验产物，macOS 与 Windows 的便携安装原地换装；Linux 安装呈现下载好的归档，安装器安装（DMG / MSI）则引导前往发布页。

## 仓库结构

```
hackdigest/
├── backend/          Racket 后端（Glaze）：存储、LLM 代理、应用壳
├── apps/desktop/     React 前端（构建到 dist/，由后端托管）
├── apps/mobile/      Phase 3
├── packages/core/    共享 TypeScript 核心：HN API、存储、BYOK 预置
└── docs/
```

## 许可与商业模式

AGPL-3.0 —— 客户端永久开源。托管翻译与 Digest 算力规划为有配额的订阅，跨设备同步不包含在首发方案。源代码可供审阅，用户也可以使用自己配置的模型密钥。
