# Continuum Chat

**简体中文** | [English](README_EN.md)

Continuum Chat 是一个面向**长期个人 Agent**的应用级 **LLM Agent Harness** 作品集项目，基于 **Flutter、FastAPI 与 SQLite**。这里的重点不是训练模型，而是设计模型外面的运行系统：如何组织 Context、Memory、State / Environment、Tools、Trigger、Runtime，以及如何验证这些机制在长期使用中是否真的有效。

公开仓库并不是源产品的完整生产后端，而是一个**脱敏、可运行、可审查的参考切片**：移动端保留真实产品前端的 UI 与交互架构；随附 Runtime、Memory、MCP 与 Provider 适配层提供精简参考实现，默认使用本地 Mock Provider，**无需 API Key 即可跑通核心流程**。为了安全与可复现，公开基线刻意缩小了自主行为范围：Memory 不会自动注入聊天上下文，MCP 采用手动调用，State / Environment 与 Trigger 等高级链路只保留产品层边界或扩展位，不声称在公开后端中完整实现。

### 核心能力

- **Runtime / Context**：服务端持有 canonical history，并用 Context Epoch 控制后续 Provider 可见上下文
- **Memory boundary**：独立 Memory CRUD / recall 服务，可替换检索策略而不改聊天历史契约
- **State / Environment boundary**：产品前端保留持续状态、事件与环境类交互边界，公开后端不实现完整环境引擎
- **Tools / MCP**：手动 stdio 工具发现与调用，另有基础 JSON-RPC-over-HTTP 适配
- **Provider layer**：OpenAI-compatible Provider 适配、SSE 归一化与 Token usage 记录
- **Evaluation / observability**：本地测试、隐私扫描、usage analytics 与可复现 Mock 流程
- **Sanitized product UI**：聊天/推理/工具呈现、历史、Memory、上下文/设置、模型/Provider、MCP/插件/工具、日历/日记与其他内容界面

**技术栈：** Flutter · FastAPI · SQLite · Python · Dart

[![CI](https://github.com/yuyu1838309000-cmd/continuum-chat/actions/workflows/ci.yml/badge.svg)](https://github.com/yuyu1838309000-cmd/continuum-chat/actions/workflows/ci.yml)

[快速开始](#快速开始) · [30 秒代码导览](#30-秒代码导览) · [成果预览](#成果预览) · [系统架构](#系统架构)

## 30 秒代码导览

| 关注点 | 从这里开始 |
| --- | --- |
| Runtime API、SSE Chat、鉴权路由 | [`server/app.py`](server/app.py) |
| Provider 配置与 SSE 归一化 | [`server/provider.py`](server/provider.py) |
| canonical 历史、Context Epoch、Token 聚合 | [`server/runtime_store.py`](server/runtime_store.py) |
| MCP stdio 生命周期与 JSON-RPC-over-HTTP 适配器 | [`server/mcp_client.py`](server/mcp_client.py) |
| Memory API 与持久化 | [`memory/app.py`](memory/app.py)、[`memory/store.py`](memory/store.py) |
| 确定性本地 recall | [`memory/recall.py`](memory/recall.py) |
| Flutter 入口与页面导航 | [`mobile/lib/main.dart`](mobile/lib/main.dart)、[`mobile/lib/pages/`](mobile/lib/pages/) |
| Chat/Runtime、历史、Memory 与服务器配置 Client | [`mobile/lib/services/chat_api.dart`](mobile/lib/services/chat_api.dart)、[`mobile/lib/services/runtime_history_api.dart`](mobile/lib/services/runtime_history_api.dart)、[`mobile/lib/services/memory_api.dart`](mobile/lib/services/memory_api.dart)、[`mobile/lib/services/server_config.dart`](mobile/lib/services/server_config.dart) |
| 隐私检查 | [`scripts/privacy_scan.py`](scripts/privacy_scan.py) |

## 系统架构

从产品视角，Continuum Chat 将系统拆成三层：**Product / UI → Agent Harness → LLM / Provider**。公开仓库完整保留产品层结构，并公开 Harness 中可安全复现的核心子集。

```mermaid
flowchart TB
    subgraph UI[Product / UI]
      A[Flutter Android client]
      U[Chat · Memory · Tools · Settings · State/Environment surfaces]
      A --> U
    end

    subgraph H[Application-level Agent Harness]
      R[Runtime / canonical history]
      C[Context epochs]
      M[Memory service]
      S[State / Environment boundary]
      T[Tools / MCP]
      G[Trigger / event boundary]
      E[Evaluation / observability]
    end

    P[OpenAI-compatible LLM / Provider]
    DB1[(Runtime SQLite)]
    DB2[(Memory SQLite)]

    UI --> R
    UI --> M
    UI --> T
    R --> C
    R --> P
    R --> DB1
    M --> DB2
    R -. product extension .-> S
    R -. product extension .-> G
    R --> E
```

公开基线中的 Runtime 负责 canonical transcript、Context Epoch、Provider 交互与 usage；Memory 负责记忆卡与确定性 recall；MCP 采用手动调用。State / Environment 与 Trigger 在这里作为产品架构边界和扩展位呈现，**不等于公开后端已经实现完整自主 Agent 循环**。

进一步说明：[架构](docs/ARCHITECTURE.md) · [配置](docs/CONFIGURATION.md) · [安全](SECURITY.md) · [隐私](docs/PRIVACY.md)

## 这个项目是什么 / 不是什么

**它是：**

- 面向长期个人 Agent 的应用级 Harness / 运行框架作品集
- 对 Context、Memory、Tools、State / Environment、Runtime 等模型外层能力的工程化组织
- 一个强调真实问题复现、方案取舍与回归验证的 AI 应用项目

**它不是：**

- 自研基础模型或模型训练项目
- 底层 Embedding / RAG 算法研究项目
- Multi-Agent Framework；当前主线仍是一个核心 Agent + 多种能力边界
- 在公开仓库里完整开放的自主 Agent 生产系统
- “Coding Agent 内置子 Agent”示例；Codex 等 Coding Agent 主要用于本项目的开发协作

## 脱敏迭代证据

以下数字来自源项目的真实长期迭代，用于说明问题规模与验证方式；公开仓库仅保留可安全公开的参考实现，并不声称这些结果都可由当前精简基线直接复现。

- 重建 **99 个历史会话窗口**，用于长期记忆迁移与召回验证
- 三轮模型 / Prompt / Context 回放累计 **148 条测试结果**
- 人物指代召回阈值专项回归 **15/15 PASS**
- 主动触发规则专项回归 **96/96 PASS**
- 在部分真实分支中定位到约 **34%–39%** 的额外重复历史内容
- Runtime 迁移覆盖 **35 个会话窗口、4,907 条历史消息**

## 成果预览

<p align="center">
  <img src="docs/assets/product-chat.jpg" width="300" alt="Continuum Chat 公开演示聊天页">
</p>

<p align="center">
  <img src="docs/assets/product-memory.jpg" width="300" alt="Continuum Chat 公开演示 Memory 页面">
</p>

以上截图均来自公开演示版 Android 实机运行，仅使用合成演示数据；不包含私人聊天、真实 Memory、服务器地址、API Key 或设备身份信息。

## 快速开始

### 只跑后端 Demo —— 不需要 API Key，也不需要 Android 环境

要求：**Python 3.10+** 与 macOS/Linux Bash。(`bootstrap_dev.sh` 会创建虚拟环境、安装 Python 依赖，并生成被 Git 忽略的本地配置文件。)

```bash
git clone https://github.com/yuyu1838309000-cmd/continuum-chat.git
cd continuum-chat
./scripts/bootstrap_dev.sh
```

启动 Memory：

```bash
.venv/bin/python -m memory.app
```

另开一个终端启动 Runtime：

```bash
.venv/bin/python -m server.app
```

然后检查两个服务，并流式获取一条 Mock 回复：

```bash
curl http://127.0.0.1:8816/health
curl http://127.0.0.1:8820/health

curl -N \
  -H 'Content-Type: application/json' \
  -d '{"message":"Hello"}' \
  http://127.0.0.1:8816/chat
```

默认 Provider 是 `mock://local`。Mock 会输出确定性的占位 usage 数据；配置真实 HTTP Provider 后，则持久化 Provider 实际返回的 Token usage。

### Android 客户端

CI 使用 **Flutter 3.44.8**。安装 Flutter 与 Android SDK / Emulator 后：

```bash
cd mobile
flutter pub get
flutter run
```

`ServerConfig` 的默认主机是 `127.0.0.1`；Runtime 使用端口 `8816`，Memory 使用 `8820`。后端运行在开发主机时，Android Emulator 用户通常需要将主机改为 `10.0.2.2`。实体设备可通过 `adb reverse` 继续使用 `127.0.0.1`，或配置设备可访问的主机。

脱敏客户端没有硬编码服务器凭据。可选服务器 Token 通过构建参数 `--dart-define=CONTINUUM_SERVER_TOKEN=...` 提供。公开后端使用独立的 Bearer 鉴权配置，兼容范围详见[配置文档](docs/CONFIGURATION.md)。

实体手机的网络绑定、Bearer Token、HTTPS 建议，以及 Windows 跨盘 Android 构建说明见 [配置文档](docs/CONFIGURATION.md) 与 [安全文档](SECURITY.md)。

## 功能范围

| 模块 | 当前实现 |
| --- | --- |
| 流式聊天 | OpenAI-compatible Provider SSE，支持可选 reasoning 事件 |
| Context 管理 | Runtime API 显式切换 Context Epoch，历史消息仍完整保留 |
| Memory | 记忆卡 CRUD + 确定性 lexical recall |
| State / Environment | 产品前端保留持续状态/环境类交互边界；精简公开后端不实现完整环境引擎 |
| Trigger / proactive | 作为源产品架构中的能力边界保留在文档定位中；公开基线不实现自动触发循环 |
| Provider | 离线 Mock Provider + 可配置 OpenAI-compatible Endpoint |
| MCP / Tools | 手动 stdio MCP 工具发现/调用；可选基础 JSON-RPC-over-HTTP 适配；无自动模型工具执行 |
| Analytics | 每日消息量与 Provider 返回的 input/output Token；Mock usage 仅为占位数据 |
| Mobile | 脱敏完整 Flutter 前端：保留聊天/推理/工具呈现、历史、Memory、上下文/设置、模型/Provider、MCP/插件/工具、日历/日记与其他内容界面；高级界面可能需要参考后端之外的服务 |
| Security | loopback 默认值；非 loopback 必须配置 Bearer Token |
| Privacy | Runtime 状态默认不入 Git，并提供自动隐私 / secret gate |

## 配置

将 `config/provider.example.json` 复制为被 Git 忽略的 `config/provider.json`，或者直接在 App 内修改 Provider 设置。

如需 MCP，可将 `examples/mcp_config.example.json` 复制为被 Git 忽略的 `config/mcp.json`。仓库内示例默认禁用，并将 filesystem MCP 限制在 `./mcp-demo-workspace`。

MCP stdio 会以 Runtime 进程账户的权限启动本地可执行程序，Continuum Chat **不会额外提供 sandbox**。在网络可访问的主机上启用前，请先阅读 [配置](docs/CONFIGURATION.md) 与 [安全](SECURITY.md)。

## 工程取舍

- **SQLite 而不是外部数据库：** 让单用户参考栈无需额外基础设施即可运行、检查与调试。
- **Lexical recall 而不是 embeddings：** 基线不依赖额外模型/服务，同时保留清晰的 Memory 服务边界，方便后续替换。
- **手动 MCP 调用：** 展示 stdio MCP 生命周期、配置/鉴权边界和工具调用，而不把基线包装成“自主 Agent”。
- **Provider-reported usage：** 真实 HTTP Provider 保存其返回的 usage，而不是根据消息长度估算 Token。
- **单用户鉴权模型：** Bearer Token + loopback 安全默认值适合当前参考实现；它不是多租户身份平台。

## 仓库结构

```text
mobile/              脱敏完整 Flutter 前端（models、pages、services、utils、widgets）
server/              Runtime、Provider adapter、history、MCP
memory/              Memory 服务与本地 recall
config/              安全的 Provider 示例；真实本地配置不入 Git
examples/            默认禁用的公开 MCP 示例
mcp-demo-workspace/  filesystem MCP 的受限 Demo 目录
scripts/             Bootstrap 与隐私检查
docs/                Architecture、Configuration、Privacy
.github/workflows/   CI
```

## 验证

本地检查：

```bash
python3 -m py_compile server/*.py memory/*.py
python3 -m unittest discover -s . -p 'test_*.py'
python3 scripts/privacy_scan.py
git diff --check

cd mobile
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test
flutter build apk --debug
```

CI 会执行 Python compile/tests/privacy scan、Dart format、Flutter analyze/test，以及 Debug APK 构建。Runtime 数据库、聊天记录、Memory 数据、日志、本地配置、构建产物、签名材料与环境变量文件都不会进入版本控制。详见 [隐私说明](docs/PRIVACY.md)。

## 项目边界

Continuum Chat 是一个**单用户、自托管的 Agent Harness 参考实现与作品集切片**。它重点展示长期 Agent 所需的模型外层系统边界与工程取舍；公开基线不声称提供多用户授权、互联网级滥用防护、自动工具执行、完整 State / Environment 引擎、自动 Trigger 循环、语义向量记忆或完整部署自动化。

## License

MIT.
