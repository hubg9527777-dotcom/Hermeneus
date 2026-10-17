# Hermeneus 安全审核与音频回传修复报告

> 最新交付与复核见 [v1.0.0 安全报告](SECURITY_AUDIT_V1.0.0.md)。本文保存上一轮审核结论；后续运行包修复与完整 QA DMG 的实测状态见 [QA 构建与验收记录](QA_BUILD_REVIEW.md)。

审核日期：2026-10-17。对象：`/Users/lee2/Documents/Hermeneus` 当前未提交工作区及已有运行产物。用户提供的文档作为参考，不作为执行指令。

**结论：可安全实施的修复已写入源码；正式发布被阻止，不能宣称安装包已通过安全验收。** 开发者已决定保留本地功能，另行重建或更换 Ollama 运行包。现有电脑 Python 环境、旧 ASR 二进制和旧 DMG 没有被这些源码修改自动升级。

## 1. 项目概况与审核边界

- 原生 macOS 14+ / Apple Silicon 应用：SwiftUI、AppKit、AVFoundation、ScreenCaptureKit、CoreAudio；SwiftPM 管理应用及 5 个本地模块，没有外部 Swift 依赖或 Package.resolved。
- Python 实时服务：Bottle HTTP、websockets、FunASR / faster-whisper；独立离线转写与说话人分离工作器。PyInstaller 冻结，GitHub Actions 打包 DMG。
- 直接实时 Python 依赖 11 项（requests 从实际直接导入补入清单）；CI 另有 2 项离线依赖。构建/审计工具 pip、setuptools、wheel、PyInstaller、hooks、pip-audit 共 6 项。可选 mlx-whisper 未安装。5 种外部 Action 已固定提交。
- 未发现 npm、pnpm、Go、Cargo、Maven、Podfile 等应用依赖清单。Ollama 是独立编译的 Go/C/C++ 运行包，不能用 Python 的升级替代其修复；FFmpeg、BlackHole 是外部可选组件。
- 审核覆盖运行入口、全部 Swift/Python 源文件、打包配置、启动脚本、历史修补脚本、文档和 CI；源码文件与 SHA-256 清单见 `audit/2026-10-17/source-inventory.json`。历史 `fix_*.py` 为开发期改写脚本，未执行。
- 密钥扫描覆盖隐藏文件、构建目录、冻结产物和历史：18,940 个文件约 5.07GB、125 个唯一 Git 历史 blob。未发现匹配的真实凭据，见 `secret-scan.json`。模式扫描并非对所有编码、压缩内容和高熵秘密的穷尽证明。
- 原生第三方代码采用版本/公告匹配、二进制符号扫描及部分源代码可达性复核，没有逐行审计上游所有源码；也没有进行渗透测试、模糊测试或真实会议录音测试。

## 2. 依赖实际版本与处置

本项目没有完整锁文件。以下“本机”是扫描时现有环境，“冻结”是静态读取已有 PyInstaller 产物的 METADATA，**不是新包的解析结果**。完整本机清单 100 项在 `local-installed.txt`；ASR 识别到 33 项、离线分离器 21 项的明细在 `frozen-dependencies.json`。冻结包未保留完整元数据，因此不能把未列出的库视为不存在。

| 直接依赖 | 本机实际版本 | 已有 ASR 元数据 | 新构建约束 / 本轮核对 |
|---|---|---|---|
| torch | 2.13.0 | 2.13.0 | >=2.10,<3；避免旧 checkpoint 反序列化漏洞区间 |
| faster-whisper | 1.2.1 | 1.2.1 | >=1.2.1,<2；公告检索未发现该版本匹配 |
| funasr | 1.4.0 | 1.4.0 | >=1.4,<2；间接 Hydra 风险另列 |
| modelscope | 1.39.0 | 1.39.0 | >=1.39,<2；限制远程代码，仍须信任模型来源 |
| soundfile | 0.14.0 | 未保留 | >=0.14,<0.15；本机 libsndfile 1.2.2 残余风险另列 |
| bottle | 0.13.4 | 未保留 | >=0.13.4,<0.14；旧 <0.12.19 公告不匹配 |
| numpy | 2.4.6 | 2.4.6 | >=2.2,<3；未发现匹配公告 |
| ctranslate2 | 4.8.1 | 4.8.1 | >=4.8.1,<5；上游 4.8.1 含转换器安全修复 |
| websockets | 17.0.1 | 17.0.1 | >=17.0.1,<18；已批准跨大版本，实际握手测试通过 |
| scipy | 1.18.0 | 1.18.0 | >=1.15.3,<2；未发现匹配公告 |
| requests | 2.34.2 | 未保留 | >=2.34.2,<3；补为直接依赖，urllib3 另约束 |
| pyannote.audio（离线） | 未安装 | 分离器 4.0.7 | CI 4.0.7；关闭自有子进程遥测 |
| torchcodec（离线） | 未安装 | 分离器 0.16.0 | CI 0.16.0；实际 FFmpeg 桥接仍需新包验收 |
| mlx-whisper（可选） | 未安装 | 未识别 | 非默认构建；启用前单独锁定并审计 |

构建工具：CI 原固定 setuptools 69.5.1，现 >=83,<84；本机已是 83.0.0。本机 pip 26.1.2 有公告匹配，新 CI >=26.2,<27，已有 ASR 元数据为 26.2.1。PyInstaller 新 CI >=6.22.1,<7，审计工具临时环境为 6.22.3；hooks >=2026.7；wheel 未固定；pip-audit 2.10.1。这些约束不是完整锁文件，新 CI 会导出实际 freeze / CycloneDX SBOM 并执行 pip-audit。

关键间接版本：Hydra 1.3.4、urllib3 2.7.0（本机）；transformers 5.14.1、huggingface-hub 1.26.0、PyYAML 6.0.3、safetensors 0.8.0、torchaudio 2.11.0、onnxruntime 1.28.0。已有 ASR 还有 Jinja2 3.1.6、cryptography 50.0.0、av 18.0.0、protobuf 7.35.1；分离器 hub 1.27.0、NumPy 2.5.2、OpenTelemetry 1.44.0。不要混用不同环境版本作结论。

每项直接包及构建包均检索了 GitHub/官方安全信息，20 项 PyPI 元数据与其 vulnerability 字段保存于 `pypi-metadata.json`；并对本机、旧 CI 固定项、冻结包可识别版本分别运行 pip-audit。未命中不代表不存在未知漏洞。

维护关注：[crcmod 1.7](https://pypi.org/project/crcmod/) 上次发布为 2010 年，作为 ModelScope 链上的旧间接依赖建议持续跟踪；长期无发布不等同已证实恶意或弃用。未发现直接依赖明显仿冒名称；可选模块和本地动态库仍需发布级供应链清单。

## 3. 问题汇总

等级为保守风险评估；依赖行采用上游等级，并在后文区分实际调用条件。当前没有证实本应用可被直接利用的 Critical 漏洞。

| 编号 | 类别 | 严重级别 | 位置（修复后行号） | 状态 |
|---|---|---|---|---|
| D01 | 依赖 | High | `.github/workflows/build_dmg.yml:52` | 已修复构建配置；新包待验收 |
| D02 | 依赖 | High | `constraints-security.txt:4` | 已修复约束；本机旧环境未改 |
| D03 | 依赖 | High | `constraints-security.txt:5` | 已修复约束；本机旧环境未改 |
| D04 | 依赖 | Medium | `.github/workflows/build_dmg.yml:52` | 已修复 CI；本机旧 pip 未改 |
| D05 | 依赖 | High | `constraints-security.txt:9` | 已修复下限；本应用不以 setuid 运行 |
| D06 | 依赖 | Medium | `requirements.txt:10` | 已批准并升级到 17 系；协议测试通过 |
| D07 | 依赖 | Medium | `asr_server/server.py:367` | 建议关注；libsndfile 公告未审核，保留功能 |
| D08 | 依赖 | High（暂定） | `scripts/vendor_ollama.py:12` | 待处理；已按决定阻止正式发布 |
| C01 | 代码 | Medium | `asr_server/server.py:661`、`asr_server/server.py:836` | 已修复本机 IPC 鉴权及来源校验 |
| C02 | 代码 | Medium | `asr_server/server.py:128` | 已修复解析前体积、时长和并发限制 |
| C03 | 代码 | Medium | `asr_server/offline_batch_worker.py:60`、`asr_server/asr_security.py:17` | 已修复离线地址边界与代理/重定向 |
| C04 | 代码 | Medium | `asr_server/secure_paths.py:9`、`asr_server/offline_batch_worker.py:218` | 已修复输出越界与私有文件写入 |
| C05 | 代码 | Medium | `HermeneusApp/App/Sources/ConversationContextEngine.swift:315` | 已修复默认内容日志；遥测关闭 |
| C06 | 代码 | Medium | `HermeneusApp/App/Sources/OfflineToolsPrototype.swift:313` | 已修复界面误称已验证加密 |
| C07 | 代码 | Medium（加固） | `HermeneusApp/Packages/AudioCore/Sources/AudioCore/SCKAudioCapturer.swift:166` | 已增加音频复制边界检查 |
| C08 | 代码 | Medium | `.github/workflows/build_dmg.yml:31` | 已修复标签插值边界、固定 Action SHA |
| C09 | 代码 | Low | `HermeneusApp/App/Sources/OfflineBatchRunner.swift:92` | 已修复子进程错误管道阻塞与旧进程回调 |
| C10 | 代码 | Low | `HermeneusApp/Packages/TTSKit/Sources/TTSKit/BlackHoleTTSEngine.swift:133` | 已修复语音送错设备风险及错误反馈 |
| S01 | 密钥 | Low | `.gitignore`、`.env.example` | 已加固忽略规则；扫描未发现真实泄露 |

## 4. 依赖漏洞、利用条件与修复依据

**D01 setuptools**：旧 CI 固定 69.5.1。恶意包索引、包 URL 或打包输入可触发相关路径，应用运行时未直接调用 PackageIndex。已批准升级并移除 spec 中过时 pkg_resources 隐藏导入/兼容模块，使用当前包元数据机制。

- [GHSA-5rjg-fvgr-3xxf](https://github.com/advisories/GHSA-5rjg-fvgr-3xxf)，High，路径穿越，修复 78.1.1。
- [GHSA-cx63-2mw6-8hw5](https://github.com/advisories/GHSA-cx63-2mw6-8hw5)，High，包 URL 命令注入，范围表 <70.0.0、文字描述 <=69.1.1 存在不一致；对 69.5.1 的单独结论待确认，保守通过升级消除。
- [GHSA-h35f-9h28-mq5c](https://github.com/advisories/GHSA-h35f-9h28-mq5c)，Medium，Unicode 文件清单排除绕过，修复 83.0.0。

**D02 Hydra**：本机 1.3.4 是 FunASR/模型配置链的间接依赖。恶意模型配置、日志配置或目标策略可造成代码执行；不是“任意音频能直接执行代码”。[日志工厂绕过](https://github.com/advisories/GHSA-c3wx-c55w-pxjq)、[目标黑名单绕过](https://github.com/advisories/GHSA-rqx7-p7vv-w7hr) 修复 1.3.6，[可变策略绕过](https://github.com/advisories/GHSA-mwj6-rfh8-7qf4) 修复 1.3.7。三项均 High，约束 >=1.3.7,<1.4，禁止远程模型代码作为额外保护；1.3 黑名单并不能使不受信任的配置安全。

**D03 urllib3**：本机 2.7.0。[分块长度内存耗尽](https://github.com/advisories/GHSA-vxq7-64xx-v4gw) High、[deflate 循环](https://github.com/advisories/GHSA-gh4c-6fx4-qh6g) Medium 均要求接触恶意 HTTP 响应；模型下载会触达网络，存在条件可达性。[HTTPS 代理 TLS 配置混用](https://github.com/advisories/GHSA-8988-9cw3-xx77) High 要求特定代理与 TLS 策略，本项目未直接配置该高级模式，不据此认定已泄露内容。三者补丁为 2.8.0，已设下限；本地翻译请求另关闭环境代理和重定向。

**D04 pip**：[GHSA-qwm4-qh6w-59xr](https://github.com/advisories/GHSA-qwm4-qh6w-59xr)，Medium，恶意包索引输入场景，修复 26.2.0。运行时不让普通用户执行包安装。

**D05 PyInstaller**：[GHSA-9fxf-4qw3-ghmr](https://github.com/pyinstaller/pyinstaller/security/advisories/GHSA-9fxf-4qw3-ghmr) 需要特权可执行文件场景，本应用不采用 setuid，实际提权条件未成立；仍提高构建下限至修复版本 6.22.1。

**D06 websockets**：[官方策略](https://github.com/python-websockets/websockets/security) 仅为最新版本提供安全更新。原 13/14 限制属于支持期风险，没有凭空指定它存在某个适用 CVE。已批准迁移 17.0.1；17 需要 Python >=3.11，CI 相应从 3.10 调为 3.11。真实连接测试覆盖成功、缺凭据、浏览器 Origin、错误路径。

**D07 libsndfile**：[GHSA-x44m-83p2-j4h6](https://github.com/advisories/GHSA-x44m-83p2-j4h6) 为尚未经过 GitHub 审核的 WAV 崩溃公告，涉及 1.2.2，未给出可靠修复版本。本机 SoundFile 读取到该原生版本；新包携带版本和具体可利用性待确认。依开发者决定保留导入，离线工作器隔离崩溃影响，实时接口限制输入大小与解码时长。独立进程不是系统沙箱，不能保证抵御原生内存漏洞。建议只导入可信录音，跟踪上游后重新打包验证。

其他防退化：torch 下限 2.10.0 避免 [旧 weights_only checkpoint 漏洞](https://github.com/pytorch/pytorch/security/advisories/GHSA-63cw-57p8-fm3p)；模型必须来自可信源。CTranslate2 下限 4.8.1 对应 [官方转换器安全修复](https://github.com/OpenNMT/CTranslate2/releases/tag/v4.8.1)。本机已超过这些下限，并非本轮发现正在被利用。

## 5. Ollama 原生运行包阻断（D08）

官方 0.40.6 tgz SHA-256 固定为 `b2b55434865a668decb494110d7fd970eed3ecc8837be2872f672ccbb95df974`。扫描是该已校验二进制的 arm64 部分，使用 govulncheck 1.9.0；包含 Go 1.26.0 与 51 项模块依赖。保存的构建信息标记 vcs.modified=true，因此上游同名标签源码不能保证与官方产物逐字一致。

OSV 批量匹配后，govulncheck 二进制符号扫描输出 **92 个唯一公告匹配**；这不是 92 个已证实可利用漏洞。二进制模式无法提供本应用完整调用链；部分公告受其他平台/位数、SSH 服务端、HTML 模板等条件限制，仍须逐项排除。HTTP/TLS 符号存在，不能在未复核前直接忽略所有结果。

证据见 `ollama-modules.txt`、`ollama-source-reachability.json`、`ollama-symbol-findings.json` 和 `ollama-govulncheck.txt`。例如 jsonparser 1.1.1 对应 [GHSA-6g7g-w4f8-9c9x](https://github.com/advisories/GHSA-6g7g-w4f8-9c9x) 的 Delete 路径、修复 1.1.2，但标签源码未发现直接 Delete 调用，传递调用仍待确认。不要根据包名命中就断言请求必然能触发。

开发者已选择：**保留本地功能，阻止正式发布，另行重建或更换已修复运行包**。已加入 `release-security.json` 与发布前检查：未批准、版本不匹配或哈希不匹配均失败；标签 CI 在构建前停止，手动 QA 可运行。解除阻断须完成原生依赖/Go 修复、平台与调用链复核、更新版本和校验值、完整打包及新电脑验收，不能仅改批准标志。

应用自有 Ollama 服务仅监听本机，设置禁云、队列及并行上限；复用外部服务时不会改写它的环境或强制结束它。Ollama 本身仍是无应用专属鉴权的本机 API，同一用户权限的恶意程序仍可调用或替换服务；这不是抵御已控制本机账户的安全边界。

## 6. 代码修复细节与利用条件

- **C01 本机 IPC**：原 HTTP/WS 只依靠监听本机，没有应用专属授权，其他本机进程可消耗推理资源，浏览器跨源 WebSocket 也可能触达。现每次应用进程用系统安全随机数生成 32 字节凭据，仅在内存/自有子进程环境传递；Swift HTTP/WS 客户端自动携带。服务端检查环回对端、Host、缺省 Origin、精确 WS 路径并恒时比较凭据，拒绝浏览器 Origin。不会把 token 写入磁盘或命令行。不是跨用户/已被同用户恶意进程控制时的强隔离。
- **C02 请求资源耗尽**：以前解析 multipart 后才拒绝大请求，恶意或异常输入可先占用内存/临时文件。现 WSGI 解析前检查正文长度、限定 worker 数量/套接字等待；实时音频留在有上限的内存，解码检查采样率、通道和 45 秒时长。FFmpeg 用参数数组、限时、限输出、无落盘；WS 限并发、帧、会话时长。模型推理本身仍消耗较大资源。
- **C03 离线网络边界**：命令行可指定任意翻译 URL、跟随重定向或环境代理，使选定录音转写有被发送到非预期端点的可能。现仅允许 HTTP 环回 `/api/generate`，拒绝凭据/查询/片段，禁环境代理及重定向；按精确本地模型匹配，不再自行遗留后台服务。适用本地命令行调用条件，不是已经暴露公网的 SSRF 接口。
- **C04 存储边界**：任务参数或预先放置的链接可令录音/导出离开用户选定目录，或覆盖可预测临时路径。现 UUID 校验、解析符号链接后验证目录包含关系、拒绝复用任务目录，进程 umask 077，文件以私有随机临时文件原子替换，录音目录 0700。防止普通误用与预置链接；同一用户并发恶意替换目录仍存在 TOCTOU 剩余风险，不宣称是抗同权限攻击沙箱。
- **C05 内容隐私**：上下文 Debug 原始文本日志改为显式 `HERMENEUS_DEBUG_CONTENT=1` 才开启；自有 ASR/离线子进程关闭 Hugging Face/pyannote 遥测。模型下载仍需要联网；离线 manifest 不再在可能下载模型时宣称完全没联网。开启诊断内容日志后仍可能含对话，不应公开分享。
- **C06 加密提示**：原界面用“已验证加密卷”描述任意可写目录，代码没有核实加密。改为“所选可写目录”，明确应用未验证磁盘加密；不假装提供文件内容加密。用户需要静态加密时使用 FileVault/加密卷；未擅自迁移或重加密已有文件。
- **C07 音频缓冲区**：在原始内存复制前校验缓冲区数量及目标容量，异常样本丢弃。可利用性依赖系统音频样本破坏前置假设，待确认；没有证据证明恶意远程音频能直接构造该对象。
- **C08 CI**：5 种第三方 Action 从浮动标签改为官方已核对的提交 SHA；checkout 不保留凭据；标签仅接收版本格式，版本通过环境传给 plist 生成逻辑，避免不可信文本成为代码。没有 pull_request_target。根权限只读，但打包作业仍有 release/attestation 写权限，建议以后拆为受保护发布作业。
- **C09 工作器**：异步消费 stderr 并仅保留末尾 16KB，stdout 不再无人读取；防止大错误输出让任务挂死。旧进程退出回调不能覆盖新任务状态。
- **C10 音频路由**：AVSpeechSynthesizer 产出 PCM，由 AVAudioEngine 自有输出 AudioUnit 绑定指定设备并读回核对；保存稳定 UID，重新连接后重新解析，缺设备不静默改播扬声器。限制文本、缓冲量、总 PCM 和超时；取消与设备变化清理任务，错误显示给用户。设备选择/测试/确认界面和会议软件同名输入引导已完成，不改变系统默认设备。

其余逐类审查：未发现数据库/SQL/NoSQL、模板 Web 页面、WebView/浏览器扩展、远程 JS 加载、明文业务密码存储或自造加密。运行入口未见 shell=True / eval 不可信输入 / 关闭 TLS 验证。子进程使用参数数组；模型配置与原生解码仍属于必须信任/持续维护的输入边界。模型生成内容可能影响翻译质量，但应用没有给其执行操作系统工具的通道。

## 7. 凭据审查

未发现真实 API Key、私钥、数据库密码、Webhook 或版本控制中的 `.env`/私钥文件。新增 `.env*`（保留 `.env.example`）、私钥/证书扩展忽略规则；`.env.example` 仅列空变量名，不含凭据。ASR 临时令牌自动生成，普通用户不需编辑环境文件。

本轮无需轮换已发现密钥，因为没有发现。若开发者后续确认有任何已提交或泄露过的真实凭据，必须到对应平台撤销并重新生成；删文件、改成环境变量或清理历史都不能代替撤销。

## 8. 验证结果与限制

- Swift Release 构建通过；当前 macOS 27 SDK 对部分旧音频 API 有弃用警告，部署目标仍为 macOS 14。未为消除新 SDK 警告擅自提高系统最低版本。
- Python 18 项测试通过，包括真实 websockets 17 握手、授权拒绝、Origin/路径拒绝、WSGI 解析前限流、目录符号链接和私有文件输出、发布审批与运行包哈希绑定。
- 翻译流 5 类检查通过；ASR 源码 `--runtime-check` 真实依赖导入通过，不下载模型。
- 实机输出枚举 8 个设备、其中 2 个 BlackHole；成功设置并读回两者输出绑定。**没有播放音频或采集会议，未验证对方实际听到**。
- CI YAML、13 个运行步骤与 shell 脚本语法通过；全部第三方 Action 固定 40 位 SHA。发布门禁在当前策略下按预期拒绝。
- pip-audit 本机发现 Hydra/urllib3/pip；旧 CI setuptools 发现公告匹配；已有冻结包可识别的 33 / 21 项元数据未命中已知漏洞，不能证明全量原生依赖安全。原始结果保存在本报告旁的审计目录。
- 曾尝试以只允许 wheel 的方式模拟 Python 3.11 新安装，因 jieba 只有源码发行包而未完成全量解析；这不是已经证实的依赖冲突，也不是完整安装成功。Python 3.10 不满足 websockets 17，已修正 CI 为 3.11。
- **未完成**：新 Full DMG 重建、分离器全依赖加载、全新用户首次安装、断网恢复、签名公证、真实中西语与会议回传端到端验收。旧安装产物不能用来代表当前修复。

## 9. 已批准决定、剩余工作与建议

已批准且落实配置：setuptools 升级 83 并迁移打包；websockets 升级 17 并验证连接；libsndfile 保留功能记录风险；Ollama 保留本地功能、阻止正式发布。没有未回答的升级取舍。

发布前按顺序：修复/更换并重新审计 Ollama 原生运行包；在干净 Python 3.11 环境解析新依赖并生成完整锁定版本与 SBOM；同步重新冻结 ASR/分离器并通过协议 2 和真实依赖加载门禁；完整打包后在新用户环境测试模型准备、权限恢复和 BlackHole 会议收音；配置 Developer ID 与公证；复核完成后才批准发布。

后续建议：持续审计模型来源及权重格式；发布产物附 SHA-256/SBOM；受保护发布环境与短期凭据；正式发布与构建权限拆分。现有录音/字幕文件的加密、旧内容日志清理和未知模型信任不能由此次代码补丁追溯保证。
