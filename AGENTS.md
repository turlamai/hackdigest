# AGENTS.md

## Authorization decision before implementation

Decision `2026-10-auth-1`: Online hosted-service entitlement, verified on the server with current account state and atomic quotas; no desktop activation lease. Read the complete [local authorization decision](PRICING.md#authorization-decision-for-implementation) and its Chinese counterpart before commercial, trial, update-eligibility or credential work. Record this decision revision and the source/policy SHAs actually read in the PR/handoff. Refresh at each bounded slice; existing agent conversations do not receive this change automatically. Follow the existing product contract and implementation issue; do not activate a payment gate merely because a plan exists.

HackDigest uses one Racket/Glaze backend in `backend/` and a React/Vite frontend in `apps/desktop/`.
`backend/main.rkt` exports `api` and starts the application only in `module+ main`.
`glaze.rktd` and `glaze-schema.json` own its reviewed application contract.

Before changing routes run `raco glaze schema check --json`; update the baseline only for an intentional reviewed contract change.
Validate with `raco test backend/tests/`, `pnpm test`, `pnpm check`, and `pnpm build`.
Do not replace a failed native WebView with an external browser. All three platforms default to the native transport; `HACKDIGEST_TRANSPORT=http` is the explicit dev adapter (`GLAZE_API_TOKEN` applies to that adapter only). The release pipeline runs a packaged native selftest (`HACKDIGEST_SELFTEST=1`) on every platform before publishing.


## 组合定位（Portfolio placement）

- 当前决策（2026-10-v2）：免费 BYOK + 限额托管订阅。具体价格、免费/付费边界和开卖门禁以本仓 [PRICING.md](PRICING.md) 为唯一权威；旧版收费候选与早鸟方案已被替代。
- 组合归属：[PORTFOLIO](https://github.com/turlamai/turlamai.github.io/blob/master/PORTFOLIO.md)。当前全部产品开发中、没有实际用户；目标定价不表示已经开卖，不因此立即给开发版加收费墙。
- 免费产品不接商业激活；付费层先实现可验证价值，再接 Commerce/Permit。优先完成本仓既有产品审查 issue；不修改现行源码 LICENSE。

## 产品交付与下一步（2026-10-23）

- 家族[交付标准](https://github.com/turlamai/turlamai.github.io/blob/master/docs/PRODUCT-STANDARD.md)与[组合策略](https://github.com/turlamai/turlamai.github.io/blob/master/PORTFOLIO.md)是共用政策；本仓具体行为以 `README.md` 为准，不复制五库依赖图。
- 当前执行入口：[产品审查 issue](https://github.com/turlamai/hackdigest/issues/2)。真实 API schema 基线与 CI 检查已接入；三平台 native transport 与打包自检已落地（0.4 周期，发行 CI 对每平台跑打包原生自检）；下一步做密钥安全存储（系统 secure storage）。BYOK 免费；托管层明确配额、停止行为和成本预算后再开卖。
- 开工先检查干净工作树与远端，以 fast-forward-only 更新并记录 SHA；共享文件一次一个写入者，保留其他 checkout 的未提交工作。
- 每次只完成一个可验收切片，记录 owned files、依赖 pin、命令/平台/产物证据和回滚。已实现、已发布、实机验收分别陈述；不修改 requirements 或复用旧证据来制造通过。

## Documentation languages

Public default documentation is English; maintain complete Chinese user paths in `*.zh-CN.md`, with reciprocal links. Update both languages when prices, quotas, installation, recovery, privacy or supported platforms change. API/protocol identifiers and commands remain unchanged; do not maintain a second normative protocol or implementation. Follow the [family language policy](https://github.com/turlamai/turlamai.github.io/blob/master/docs/DOCUMENTATION-LANGUAGES.md). Existing internal notes are not a claim that every document is bilingual.

## Public product documentation

The paired `docs/USER-GUIDE.md` / `docs/USER-GUIDE.zh-CN.md` own the public installation, first-use, data/recovery, privacy and availability path. Keep the homepage and both README entry points aligned with them when behavior changes. Detailed technical contracts and the current implementation queue retain their existing owners. Do not publish target prices, a purchase link or a ready/secure/platform claim before its release evidence exists.

## 设计流程（原型先行）

所有 UI 开发与界面改造一律先原型后代码：brief → `design/DESIGN.md`
视觉契约 → HTML 原型 → 按 HIG 基准评审通过才开工；改界面先改原型再改
代码。契约与原型放本仓 `design/`（尚未建立时随首个 UI 切片建立），
实物截图验收后才能作为对外宣传素材。
