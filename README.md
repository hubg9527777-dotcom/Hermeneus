# Hermeneus 传译者

> 🚀 本地 AI 实时同声传译（macOS）

Hermeneus 基于本地 AI
模型运行，无需云端接口，可实现低延迟实时语音识别、翻译与字幕显示。

------------------------------------------------------------------------

## ✨ 功能特点

-   🎙️ 实时语音识别（ASR）
-   🌍 本地 AI 翻译（Ollama）
-   💬 悬浮字幕实时显示
-   🔒 全程本地运行
-   ⚡ 一条命令启动

------------------------------------------------------------------------

# 🚀 快速开始

首次安装仅需执行一次。

  步骤   说明
  ------ -------------------------
  1      安装 Homebrew 与 Ollama
  2      下载 Qwen 模型
  3      安装 Hermeneus
  4      配置启动脚本
  5      开始使用

------------------------------------------------------------------------

# ① 安装 Homebrew 与 Ollama

``` bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
brew install ollama
```

------------------------------------------------------------------------

# ② 下载翻译模型

启动 Ollama：

``` bash
nohup ollama serve >/dev/null 2>&1 &
sleep 2
```

下载模型：

``` bash
ollama pull qwen2.5:3b
```

> **注意**
>
> Hermeneus 设置中的模型名称必须与 `ollama list` 显示一致（例如
> `qwen2.5:3b`）。

------------------------------------------------------------------------

# ②.5 安装本地运行时

在终端执行：

```bash
brew install ollama ffmpeg
ollama pull qwen2.5:3b
```

`ffmpeg` 仅在对普通单轨混音文件启用“**双人说话**”匿名分离时使用；Hermeneus 自己的双轨会议录音不依赖它。所有音频仍在本机处理。

# ③ 安装 Hermeneus

下载最新版：

    Hermeneus-macOS-vX.X.X-Full.dmg

将 **Hermeneus.app** 拖入 **Applications（应用程序）**。

------------------------------------------------------------------------

# ④ 配置启动脚本

首次安装时，在终端执行启动脚本。

```{=html}
<details>
```
```{=html}
<summary>
```
`<strong>`{=html}点击展开完整启动脚本`</strong>`{=html}
```{=html}
</summary>
```
``` bash
Full DMG 已内置启动器；无需复制脚本。安装后直接执行下面的应用内路径。
```

```{=html}
</details>
```

------------------------------------------------------------------------

# ▶️ 启动（v1.0.6）

以后无需重复安装。打开终端后执行：

```bash
/Applications/Hermeneus.app/Contents/Resources/Hermeneus_start.sh
```

Full DMG 已包含实时 ASR、离线批量转译和匿名说话人分离组件；Lite ZIP 不含这些组件。首次使用前仍需安装本地 Ollama CLI，并执行 `ollama pull qwen2.5:3b` 下载翻译模型。普通单轨匿名双人分离首次还需要在 Hugging Face 接受 pyannote 模型条款并登录；音频不会上传。

程序将自动：

-   ✅ 启动 Ollama
-   ✅ 加载本地模型
-   ✅ 清理 Gatekeeper 隔离
-   ✅ 启动 ASR 服务
-   ✅ 打开 Hermeneus

------------------------------------------------------------------------

# 🎤 使用说明

### 对方讲话

系统自动：

1.  识别语音
2.  翻译内容
3.  实时字幕显示

### 自己讲话

按住 **Option（⌥）** 键说话。

松开按键后将自动：

1.  语音识别
2.  翻译
3.  播放给对方

------------------------------------------------------------------------

# 🔄 更新

下载最新版 DMG。

覆盖到：

    /Applications

即可，无需重新配置启动脚本。

更新后继续执行：

```bash
/Applications/Hermeneus.app/Contents/Resources/Hermeneus_start.sh
```

------------------------------------------------------------------------

# 📋 系统要求

  项目     要求
  -------- ------------------------
  系统     macOS 14+（Apple Silicon）
  处理器   Apple Silicon
  依赖     Homebrew、Ollama、FFmpeg
  模型     qwen2.5:3b
  权限     麦克风、屏幕录制

------------------------------------------------------------------------

# ❓ 常见问题

**模型无法下载？**

确认：

-   Ollama 已启动
-   网络连接正常
-   模型名称填写正确

**启动失败？**

重新执行：

```bash
/Applications/Hermeneus.app/Contents/Resources/Hermeneus_start.sh
```

若仍失败，请检查启动脚本或重新安装 Ollama。

------------------------------------------------------------------------

© Hermeneus
