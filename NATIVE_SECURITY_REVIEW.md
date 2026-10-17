# Hermeneus 原生推理库复核与验收进度

日期：2026-10-17。当前交付安全修订 `0.40.6-hermeneus.3`，应用仍为 Hermeneus v1.0.0。**原生复核、GIF 排除、无账号分离、BlackHole 本机回传和修补分离引擎的最终 DMG 本地验收已通过。未上传 GitHub。**

这是 SECURITY_AUDIT_V1.0.0.md 的后续记录。原始公告 JSON、完整扫描输出和本机测试脚本保留在维护者本地归档；文中的旧 audit 路径是归档来源说明，公开源码仅保留精简构建来源记录。本轮使用修订 .3 重新封装完整 DMG，备份旧修订 .2；安装包状态及最终哈希见 v1.0.0 安全报告和 SHA256SUMS。

## 1. 原生组件与来源

| 组件 | 本轮确认的实际版本 / 提交 | 依据 |
|---|---|---|
| Ollama Go 主程序 | 官方 0.40.6 源码 2476d5ead197abe04629651028f83d48dc75d2b2；修订 .3 | 固定归档、Go 模块锁、程序哈希和真实接口测试 |
| llama.cpp | b11669 / 620d2225cc436ab0b001e3200e590e3b286ef9ab | 原分发程序输出 commit 620d2225c；本轮从完整固定提交重建 |
| 原生重建 | arm64、最低 macOS 14.0、静态库、Metal 开启、RPC 关闭 | CMake 4.4.4、完整构建日志、源码及程序哈希；真实固定文本推理通过 |
| MLX | 动态库实际 0.32.3-96-gbebd642；完整提交 bebd6422f8db88d56e6220520a35bcd146f823f8 | 按官方 const char* 函数声明读取实际动态库；修复 v0.29.4 的祖先关系为 ahead |
| MLX-C | a341b4925024b88b2c593468f16e12f5e17315da，源码默认版本 0.7.0 | 官方基线的固定版本文件及源码归档；无公开官方安全公告命中 |
| XGrammar | 两套 Metal 动态库均返回 v0.2.7 | 官方 C 接口实际读取；固定构建源码标记相同 |
| cpp-httplib | 0.61.0 | 本轮重建的 pinned llama.cpp 源码头文件；23 条公开公告均低于当前版本 |
| nlohmann JSON | llama.cpp 3.12.0；MLX 构建引用 3.11.3 | 两个项目源树分别核对；没有混用版本，官方安全页暂无已发布公告 |
| fmt | MLX 源树固定 12.1.0 | 固定 MLX CMake，官方安全页复核 |
| miniaudio | 0.11.25 | llama.cpp 源树；MA_NO_DEVICE_IO 等宏关闭物理设备 I/O，当前文本推理不调用音频解码 |
| stb_image | 2.30 | 公告未审核；按开发者批准编译排除 GIF 解码，实际库负向测试通过 |

原生源码固定归档 SHA-256：llama.cpp `da36b3375b80d9d237e3787ff04fa72887bce2c8eefb717023205e4e6bbdeaad`。MLX / MLX-C 归档及提交在 mlx-source-provenance.json。原始官方载荷归档仍固定 `b2b55434865a668decb494110d7fd970eed3ecc8837be2872f672ccbb95df974`。重建源码会应用官方 Ollama 携带的兼容补丁；所用 recipe、helper、runner 哈希均记录在 native-build.json。

MLX Metal v4 的最低系统由源码选择器在 macOS 26 以下排除，v3 保留低系统兼容路径；本轮未在 macOS 14 / M1 实机重新验收，不能用构建目标代替实机结论。原生源码重建不代表已对上游所有 C/C++ 代码逐行审计或穷尽模糊测试。

## 2. 新发现及修改

| 编号 | 类别 | 严重级别 | 位置 | 状态 |
|---|---|---|---|---|
| N01 | 代码 | Medium | scripts/ollama_patches.py；上游 llm/llama_server.go:210、mlxrunner/runner.go:332 | 已修复并实测：主接口保护没有覆盖原生子进程监听器 |
| N02 | 代码 | Medium | runtime/ollama/hermeneus_access.go | 已修复：原生 HTTP 客户端凭据与重定向边界 |
| N03 | 依赖 | Medium（公告未审核） | pinned llama.cpp tools/mtmd/mtmd-helper.cpp:35 / vendor/stb/stb_image.h | 已修复暴露：按批准关闭 GIF 并重建，不声称上游 2.30 已修复 |
| N04 | 代码 | Low | scripts/rebuild_native_ollama.py、scripts/vendor_ollama.py | 已修复构建来源边界；拒绝未校验或启用 RPC 的运行包 |

N01 的利用条件：本机其他程序或能够访问环回端口的网页绕过主 Ollama 端口，直接联系原生推理子进程，执行分词/推理、消耗资源；原生端口不是固定 11434，但随机端口本身不构成鉴权。修订 .3 将能力凭据经环境变量传入 llama-server 的 LLAMA_API_KEY，不写入命令行；MLX 原生监听器增加独立鉴权和 Origin/环回限制。原生健康状态接口按上游保留公开，但计算接口不能无凭据调用。实际源构建程序 `/tokenize` 缺失或错误凭据返回 401，正确凭据正常返回；主接口仍拒绝缺失凭据和网页 Origin。

N02：原生客户端只访问字面地址 127.0.0.1，关闭环境代理，向私有后端附带凭据；只允许同一 scheme/host/port 内的重定向，保留 MLX 的合法 health→status 跳转，拒绝跳往其他端点，避免令牌跨域泄露。能力凭据不写入程序参数或内容日志。该边界不防御已控制同一用户账户、能读取该用户进程环境的恶意程序。

N03：[GHSA-ccf6-mw22-wphc](https://github.com/advisories/GHSA-ccf6-mw22-wphc) / [NVD](https://nvd.nist.gov/vuln/detail/CVE-2026-5185) 描述 stb_image <=2.30 多帧 GIF 越界，GitHub 标记 Unreviewed，未确认修复版本。用户批准后，本轮在实际 mtmd-helper.cpp 编译单元中定义 STBI_NO_GIF 并从固定源码重建；native-build.json 记录 gif_disabled=true，供应与验证入口强制要求该属性。直接链接实际 libmtmd.a 的测试拒绝合法 GIF，同时 PNM 图像解码正常；最终 runner 中未发现 GIF 解码符号。中西文字推理及鉴权复测通过。不是声称上游版本已修复或已复现公告。

N04：新增可重复的原生构建脚本，固定完整提交和两个源码归档哈希；明确 macOS 14、arm64、Metal 与 RPC=OFF。打包必须提供匹配的原生程序及元数据，验证 recipe/source/hash/架构和 RPC 属性；CLI 补丁集合也进入构建记录。签名后的原生程序另存 packaged_runner_sha256，保留签名前的来源哈希。CI 不会自动发布。

## 3. 公告逐项核对

官方安全公告原文与 GitHub 比较 API 证据在维护者本地 audit/2026-10-17-native 归档。llama.cpp 12 项修复参考与固定提交比较均为 ahead、behind_by=0；RPC 公告单独依据启用条件及构建属性判断。GHSA-g4cc-763q-h9h6 的受影响/修复字段使用同一短提交，不能单凭表格作结论；当前词表 scores/toktypes 数量边界检查与修复提交包含关系一并核对。实际 GGUF 回归不等于所有恶意模型都安全，仍只应使用可信模型。

| 公告 | 组件 | 公告级别 | 上游给出的修复参考 | 本轮处置 |
|---|---|---|---|---|
| [GHSA-3p4r-fq3f-q74v](https://github.com/ggml-org/llama.cpp/security/advisories/GHSA-3p4r-fq3f-q74v) | llama | high | >= b8146 | 固定提交在修复参考之后；结合当前代码与 GGUF 回归复核 |
| [GHSA-j8rj-fmpv-wcxw](https://github.com/ggml-org/llama.cpp/security/advisories/GHSA-j8rj-fmpv-wcxw) | llama | critical | 未指定 | 要求显式 RPC 后端；本构建 RPC=OFF，无 RPC 监听 |
| [GHSA-96jg-mvhq-q7q7](https://github.com/ggml-org/llama.cpp/security/advisories/GHSA-96jg-mvhq-q7q7) | llama | high | b7824 | 固定提交在修复参考之后；结合当前代码与 GGUF 回归复核 |
| [GHSA-8947-pfff-2f3c](https://github.com/ggml-org/llama.cpp/security/advisories/GHSA-8947-pfff-2f3c) | llama | low | >= c78fb90 | 固定提交在修复参考之后；结合当前代码与 GGUF 回归复核 |
| [GHSA-vgg9-87g3-85w8](https://github.com/ggml-org/llama.cpp/security/advisories/GHSA-vgg9-87g3-85w8) | llama | high | 26a48ad | 固定提交在修复参考之后；结合当前代码与 GGUF 回归复核 |
| [GHSA-7rxv-5jhh-j6xx](https://github.com/ggml-org/llama.cpp/security/advisories/GHSA-7rxv-5jhh-j6xx) | llama | high | b5721 | 固定提交在修复参考之后；结合当前代码与 GGUF 回归复核 |
| [GHSA-g4cc-763q-h9h6](https://github.com/ggml-org/llama.cpp/security/advisories/GHSA-g4cc-763q-h9h6) | llama | medium | c33fe8b8 | 固定提交在修复参考之后；结合当前代码与 GGUF 回归复核 |
| [GHSA-8wwf-w4qm-gpqr](https://github.com/ggml-org/llama.cpp/security/advisories/GHSA-8wwf-w4qm-gpqr) | llama | high | >= b5662 | 固定提交在修复参考之后；结合当前代码与 GGUF 回归复核 |
| [GHSA-wcr5-566p-9cwj](https://github.com/ggml-org/llama.cpp/security/advisories/GHSA-wcr5-566p-9cwj) | llama | critical | >= b3561 | 固定提交在修复参考之后；结合当前代码与 GGUF 回归复核 |
| [GHSA-5vm9-p64x-gqw9](https://github.com/ggml-org/llama.cpp/security/advisories/GHSA-5vm9-p64x-gqw9) | llama | medium | >= b3561 | 固定提交在修复参考之后；结合当前代码与 GGUF 回归复核 |
| [GHSA-mqp6-7pv6-fqjf](https://github.com/ggml-org/llama.cpp/security/advisories/GHSA-mqp6-7pv6-fqjf) | llama | medium | >= b3561 | 固定提交在修复参考之后；结合当前代码与 GGUF 回归复核 |
| [GHSA-49q7-2jmh-92fp](https://github.com/ggml-org/llama.cpp/security/advisories/GHSA-49q7-2jmh-92fp) | llama | medium | b3427 | 固定提交在修复参考之后；结合当前代码与 GGUF 回归复核 |
| [GHSA-p5mv-gjc5-mwqv](https://github.com/ggml-org/llama.cpp/security/advisories/GHSA-p5mv-gjc5-mwqv) | llama | high | b2740 | 固定提交在修复参考之后；结合当前代码与 GGUF 回归复核 |
| [GHSA-w6vg-jg77-2qg6](https://github.com/ml-explore/mlx/security/advisories/GHSA-w6vg-jg77-2qg6) | mlx | low | 0.29.4 | 实际提交包含 0.29.4，版本/祖先关系确认 |
| [GHSA-j842-xgm4-wf88](https://github.com/ml-explore/mlx/security/advisories/GHSA-j842-xgm4-wf88) | mlx | low | 0.29.4 | 实际提交包含 0.29.4，版本/祖先关系确认 |
| [GHSA-3gmq-qh92-5grm](https://github.com/mlc-ai/xgrammar/security/advisories/GHSA-3gmq-qh92-5grm) | xgrammar | medium | 0.2.6 | 实际 v0.2.7，高于所列修复版 |
| [GHSA-m5hf-r6jr-m4q6](https://github.com/mlc-ai/xgrammar/security/advisories/GHSA-m5hf-r6jr-m4q6) | xgrammar | high | 0.2.6 | 实际 v0.2.7，高于所列修复版 |
| [GHSA-ggf7-2pq3-j6pv](https://github.com/mlc-ai/xgrammar/security/advisories/GHSA-ggf7-2pq3-j6pv) | xgrammar | high | 0.2.6 | 实际 v0.2.7，高于所列修复版 |
| [GHSA-7rgv-gqhr-fxg3](https://github.com/mlc-ai/xgrammar/security/advisories/GHSA-7rgv-gqhr-fxg3) | xgrammar | high | 0.1.32 | 实际 v0.2.7，高于所列修复版 |
| [GHSA-9q5r-wfvf-rr7f](https://github.com/mlc-ai/xgrammar/security/advisories/GHSA-9q5r-wfvf-rr7f) | xgrammar | medium | 0.1.24 | 实际 v0.2.7，高于所列修复版 |
| [GHSA-5cmr-4px5-23pc](https://github.com/mlc-ai/xgrammar/security/advisories/GHSA-5cmr-4px5-23pc) | xgrammar | high | 0.1.21 | 实际 v0.2.7，高于所列修复版 |
| [GHSA-389x-67px-mjg3](https://github.com/mlc-ai/xgrammar/security/advisories/GHSA-389x-67px-mjg3) | xgrammar | medium | 0.1.18 | 实际 v0.2.7，高于所列修复版 |
| [GHSA-vq69-f637-8fhr](https://github.com/yhirose/cpp-httplib/security/advisories/GHSA-vq69-f637-8fhr) | httplib | low | 0.51.0 | 源码 0.61.0，高于所列修复版；原生 TLS/客户端下载关闭 |
| [GHSA-22mf-w2v3-r2jv](https://github.com/yhirose/cpp-httplib/security/advisories/GHSA-22mf-w2v3-r2jv) | httplib | high | v0.51.0 | 源码 0.61.0，高于所列修复版；原生 TLS/客户端下载关闭 |
| [GHSA-w7p7-f35j-mw7q](https://github.com/yhirose/cpp-httplib/security/advisories/GHSA-w7p7-f35j-mw7q) | httplib | medium | v0.50.1 | 源码 0.61.0，高于所列修复版；原生 TLS/客户端下载关闭 |
| [GHSA-2r2h-jc8w-w66c](https://github.com/yhirose/cpp-httplib/security/advisories/GHSA-2r2h-jc8w-w66c) | httplib | medium | v0.50.0 | 源码 0.61.0，高于所列修复版；原生 TLS/客户端下载关闭 |
| [GHSA-8ffh-4p95-g3p2](https://github.com/yhirose/cpp-httplib/security/advisories/GHSA-8ffh-4p95-g3p2) | httplib | high | 0.47.0 | 源码 0.61.0，高于所列修复版；原生 TLS/客户端下载关闭 |
| [GHSA-hg3g-vrg8-578g](https://github.com/yhirose/cpp-httplib/security/advisories/GHSA-hg3g-vrg8-578g) | httplib | high | 0.44.0 | 源码 0.61.0，高于所列修复版；原生 TLS/客户端下载关闭 |
| [GHSA-xjxg-64p4-vj4m](https://github.com/yhirose/cpp-httplib/security/advisories/GHSA-xjxg-64p4-vj4m) | httplib | high | 0.44.0 | 源码 0.61.0，高于所列修复版；原生 TLS/客户端下载关闭 |
| [GHSA-h6wq-j5mv-f3q8](https://github.com/yhirose/cpp-httplib/security/advisories/GHSA-h6wq-j5mv-f3q8) | httplib | medium | 0.43.4 | 源码 0.61.0，高于所列修复版；原生 TLS/客户端下载关闭 |
| [GHSA-jv63-rm9j-6jwc](https://github.com/yhirose/cpp-httplib/security/advisories/GHSA-jv63-rm9j-6jwc) | httplib | medium | 0.40.0 | 源码 0.61.0，高于所列修复版；原生 TLS/客户端下载关闭 |
| [GHSA-6hrp-7fq9-3qv2](https://github.com/yhirose/cpp-httplib/security/advisories/GHSA-6hrp-7fq9-3qv2) | httplib | high | 0.39.0 | 源码 0.61.0，高于所列修复版；原生 TLS/客户端下载关闭 |
| [GHSA-c3h8-fqq4-xm4g](https://github.com/yhirose/cpp-httplib/security/advisories/GHSA-c3h8-fqq4-xm4g) | httplib | high | 0.37.2 | 源码 0.61.0，高于所列修复版；原生 TLS/客户端下载关闭 |
| [GHSA-39q5-hh6x-jpxx](https://github.com/yhirose/cpp-httplib/security/advisories/GHSA-39q5-hh6x-jpxx) | httplib | high | 0.37.1 | 源码 0.61.0，高于所列修复版；原生 TLS/客户端下载关闭 |
| [GHSA-qq6v-r583-3h69](https://github.com/yhirose/cpp-httplib/security/advisories/GHSA-qq6v-r583-3h69) | httplib | medium | 0.37.0 | 源码 0.61.0，高于所列修复版；原生 TLS/客户端下载关闭 |
| [GHSA-8mpw-r4gc-xm7q](https://github.com/yhirose/cpp-httplib/security/advisories/GHSA-8mpw-r4gc-xm7q) | httplib | medium | 0.35.0 | 源码 0.61.0，高于所列修复版；原生 TLS/客户端下载关闭 |
| [GHSA-xvfx-w463-6fpp](https://github.com/yhirose/cpp-httplib/security/advisories/GHSA-xvfx-w463-6fpp) | httplib | high | 0.35.0 | 源码 0.61.0，高于所列修复版；原生 TLS/客户端下载关闭 |
| [GHSA-h934-98h4-j43q](https://github.com/yhirose/cpp-httplib/security/advisories/GHSA-h934-98h4-j43q) | httplib | high | 0.30.1 | 源码 0.61.0，高于所列修复版；原生 TLS/客户端下载关闭 |
| [GHSA-wpc6-j37r-jcx7](https://github.com/yhirose/cpp-httplib/security/advisories/GHSA-wpc6-j37r-jcx7) | httplib | critical | 0.30.0 | 源码 0.61.0，高于所列修复版；原生 TLS/客户端下载关闭 |
| [GHSA-gfpf-r66f-5mh2](https://github.com/yhirose/cpp-httplib/security/advisories/GHSA-gfpf-r66f-5mh2) | httplib | medium | 0.27.0 | 源码 0.61.0，高于所列修复版；原生 TLS/客户端下载关闭 |
| [GHSA-xm2j-vfr9-mg9m](https://github.com/yhirose/cpp-httplib/security/advisories/GHSA-xm2j-vfr9-mg9m) | httplib | critical | 0.27.0 | 源码 0.61.0，高于所列修复版；原生 TLS/客户端下载关闭 |
| [GHSA-j6p8-779x-p5pw](https://github.com/yhirose/cpp-httplib/security/advisories/GHSA-j6p8-779x-p5pw) | httplib | medium | 0.23.0 | 源码 0.61.0，高于所列修复版；原生 TLS/客户端下载关闭 |
| [GHSA-qjmq-h3cc-qv6w](https://github.com/yhirose/cpp-httplib/security/advisories/GHSA-qjmq-h3cc-qv6w) | httplib | high | 0.23.0 | 源码 0.61.0，高于所列修复版；原生 TLS/客户端下载关闭 |
| [GHSA-xjhg-gf59-p92h](https://github.com/yhirose/cpp-httplib/security/advisories/GHSA-xjhg-gf59-p92h) | httplib | high | 0.22.0 | 源码 0.61.0，高于所列修复版；原生 TLS/客户端下载关闭 |
| [GHSA-px83-72rx-v57c](https://github.com/yhirose/cpp-httplib/security/advisories/GHSA-px83-72rx-v57c) | httplib | high | 0.20.1 | 源码 0.61.0，高于所列修复版；原生 TLS/客户端下载关闭 |

### Ollama 本体的 9 条原始 OSV 匹配

OSV 部分记录只有 introduced=0、没有 fixed 上界，因此不能把所有 v0.40.6 匹配都当作已证实未修复，也不能依靠自建模块标为 (devel) 把它们忽略。

| 原始记录 | 核对结论 |
|---|---|
| GO-2025-3557 | 旧 GGUF 无界预分配路径已改为懒解析、有界数组；实际超大声明/畸形元数据回归通过 |
| GO-2025-3558 | 当前张量维度/类型/元素数量和溢出校验，错误输入回归通过，未沿用旧数组索引实现 |
| GO-2025-3559 | 当前 alignment=0 被拒绝，不进入取模；对应现有回归通过 |
| GO-2025-3582 | 当前元数据类型/缺失值显式检查，懒解析错误保留；畸形文件回归通过 |
| GO-2025-3689 | 旧 block_count 类型断言/除零路径已改写；当前 UintOK/默认值与 HeadCount>0 保护已检查 |
| GO-2025-3695 | 当前下载分片日志索引在 len(Parts)>0 内；未沿用旧空数组路径 |
| GO-2025-3824 | getAuthorizationToken 比较 realm.Host 与原始 host，拒绝跨域；已有安全测试通过 |
| GO-2025-4251 | 所有主接口已有原生应用能力鉴权，本轮进一步保护原生计算后端；无凭据请求实测拒绝 |
| GO-2026-5750 | 当前固定源码不存在所指 x/imagegen/transfer/digestToPath 包，未链接该入口；不能据此给其他版本背书 |

修订 .3 的 govulncheck 仍仅报告 GO-2026-5932 OpenPGP 模块提示；当前入口未调用 OpenPGP。不得把此结果解释为全部原生库都已自动扫描或不存在未知漏洞。

## 4. 已完成测试

- 固定源码、兼容补丁、CMake 4.4.4 的完整原生构建与重复构建成功；arm64、最低 macOS 14.0，运行依赖仅系统 Framework/库。
- 将上游 test-gguf 直接链接到本次实际构建的静态库，固定种子 20261017：**189/189 通过**，涵盖恶意长度/维度/类型/对齐/偏移/内存大小溢出及 Metal/CPU/BLAS 往返。保存的工具输出有截断提示，但末尾计数与退出码已确认。
- Go 原生接口/重定向安全测试、GGUF、跨域认证回归与 llm 包已有测试通过。
- Python **26 项通过**，Swift Release 构建通过，真实 Swift 客户端使用 .3 的私有端口完成鉴权、精确版本校验和中译西流式请求。
- 原生后端固定文字翻译正常，缺失/错误凭据分词请求被拒绝。全部模型为先前缓存的公开 Qwen；未使用私人文字或音频。

## 5. 本轮功能验收与范围

- 用户没有 Hugging Face 账号，并明确要求改为无需注册方案。未使用本机残留 HF 凭据，未代替接受 gated 条款。已移除 Community-1 加载器，改为官方公开 ONNX 分段模型和 TitaNet Small，固定大小/SHA-256、私有快照、无动态 YAML/pickle；保留 MIT / Apache 2.0 全文。
- 空缓存首次匿名下载成功。源码及冻结程序在禁止联网的沙盒中均完成 36.47 秒西语双声线 A/B/A/B 分离，各段与预期语音区间重叠超过 90%；官方公开中文四人样本得到 10 段、4 人及预期重现关系。冻结程序同时禁止读取 Homebrew，未使用物理麦克风。
- 用户确认无会议并允许虚拟输入测试。当前正式 TTSKit/AudioReturnProbe 编译的测试程序在 BlackHole 2ch 上测得 baseline RMS=0、speech RMS=0.07933、48kHz、220800 帧、2.9 秒有效语音，完整回传通过；仅统计、不存音频、不更改系统默认设备。首次运行旧测试二进制触发已修复缓冲错误，替换为当前正式代码后通过，不隐去失败记录。
- 用户接受不使用 Developer ID/公证。该项转为明确接受的分发限制，不再作为强制证书阻塞；安装遵循 Apple 单应用“仍要打开”，不关闭系统安全功能。
- 当前 Apple M4 实测不代表 macOS 14/M1 或第二台全新机器验收；BlackHole 本机回传不代表远端会议已确认。

分离引擎已固定源码应用越界补丁并重建为 1.13.8+hermeneus.1，正常、恶意元数据及地址检测回归通过；最终 DMG 完整任务通过。详见 SECURITY_AUDIT_V1.0.0.md。已准备正式发布命令但未执行。

## 6. 最终修补交付

分离引擎 patch、wheel 和冻结程序来源见 audit/2026-10-17-final/final-diarization-build.json。最终离线模型列表预检漏带鉴权的问题已修复并重建 ASR，26 项回归、只读镜像完整任务通过。最终哈希以 SHA256SUMS 为准；前面的旧阶段记录不再是发布阻塞结论。
