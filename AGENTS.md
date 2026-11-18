# AGENTS.md

## 实现路由（agent 按任务读真源）

- 实现界面以 `design/prototype/` 为准：对照 HTML/CSS/JS 与实物截图验收，不依赖散文复述。
- Token/几何值真源 = `design/prototype/shared.css`（亮暗成对；无 shared.css 的仓 = design/prototype/ 各页样式）；`design/DESIGN.md` 只记语义名、用途与决策。
- 行为边界与跨平台一致性以 `design/DESIGN.md` 的不变式与平台差异节为准。
- 改界面先改原型再改实现（tlai-prototype-flow）；动共享层（design/、shared/）先 issue 声明，同 commit 落契约。

## Current owner decision — 2026-11-18 quality-first

This is a **non-commercial development product**. The previous 2026-10 authorization, pricing, trial, Pro and Permit/Commerce rollout decisions are canceled. Do not implement or restore checkout, activation, subscription, paid feature gates, trial expiry or update-entitlement windows. Keep source licenses, release-signature verification, privacy protections and tested data migration intact. Focus only on real product functionality, native platform parity, recovery, clear bilingual READMEs and honest website status. Read the [current family policy](https://github.com/turlamai/turlamai.github.io/blob/master/PORTFOLIO.md) before every development slice.

HackDigest uses one Racket/Glaze backend in `backend/` and a React/Vite frontend in `apps/desktop/`.
`backend/main.rkt` exports `api` and starts the application only in `module+ main`.
`glaze.rktd` and `glaze-schema.json` own its reviewed application contract.

Before changing routes run `raco glaze schema check --json`; update the baseline only for an intentional reviewed contract change.
Validate with `raco test backend/tests/`, `pnpm test`, `pnpm check`, and `pnpm build`.
Do not replace a failed native WebView with an external browser. All three platforms default to the native transport; `HACKDIGEST_TRANSPORT=http` is the explicit dev adapter (`GLAZE_API_TOKEN` applies to that adapter only). The release pipeline runs a packaged native selftest (`HACKDIGEST_SELFTEST=1`) on every platform before publishing.


## 组合定位（Portfolio placement）

本产品目前是 **2026-11-18 质量与交付优先的非收费开发项目**。不重新引入旧版价格、购买、试用、Pro 或 Permit/Commerce 门禁；保持现行源码许可与更新签名安全。当前权威为 [产品组合策略](https://github.com/turlamai/turlamai.github.io/blob/master/PORTFOLIO.zh-CN.md)，不是已经删除的产品定价文件。

## 产品交付与下一步（2026-11-18）

先完成真实主流程、错误与恢复、原生平台体验、更新验签及完整中英文文档/产品主页验收。不要实施收费功能，不能用网页或单测代替发行包可用性证据。

## Documentation languages

Public default documentation is English; maintain complete Chinese user paths in `*.zh-CN.md`, with reciprocal links. Update both languages when prices, quotas, installation, recovery, privacy or supported platforms change. API/protocol identifiers and commands remain unchanged; do not maintain a second normative protocol or implementation. Follow the [family language policy](https://github.com/turlamai/turlamai.github.io/blob/master/docs/DOCUMENTATION-LANGUAGES.md). Existing internal notes are not a claim that every document is bilingual.

## Public product documentation

The paired `docs/USER-GUIDE.md` / `docs/USER-GUIDE.zh-CN.md` own the public installation, first-use, data/recovery, privacy and availability path. Keep the homepage and both README entry points aligned with them when behavior changes. Detailed technical contracts and the current implementation queue retain their existing owners. Do not publish target prices, a purchase link or a ready/secure/platform claim before its release evidence exists.

## 设计流程（原型先行）

所有 UI 开发与界面改造一律先原型后代码：brief → `design/DESIGN.md`
视觉契约 → HTML 原型 → 按 HIG 基准评审通过才开工；改界面先改原型再改
代码。契约与原型放本仓 `design/`（尚未建立时随首个 UI 切片建立），
实物截图验收后才能作为对外宣传素材。
