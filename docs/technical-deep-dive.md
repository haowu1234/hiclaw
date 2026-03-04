# HiClaw 技术深度分析文档

本文档深入分析 HiClaw 系统中 Claw Agent 之间的交互机制、人类操控 Agent 的通信架构，以及核心技术实现细节。

---

## 目录

1. [系统架构概览](#1-系统架构概览)
2. [通信协议与消息传递](#2-通信协议与消息传递)
3. [Agent 角色与交互模式](#3-agent-角色与交互模式)
4. [人类监督与介入机制](#4-人类监督与介入机制)
5. [凭证管理与安全模型](#5-凭证管理与安全模型)
6. [文件系统与状态同步](#6-文件系统与状态同步)
7. [生命周期管理](#7-生命周期管理)
8. [关键技术实现](#8-关键技术实现)

---

## 1. 系统架构概览

### 1.1 核心组件

HiClaw 采用 **Manager-Worker** 架构，所有组件通过 **Matrix 协议** 进行实时通信：

```
┌─────────────────────────────────────────────────────────────────┐
│                    Manager Container (All-in-One)               │
├─────────────────────────────────────────────────────────────────┤
│  ┌─────────────┐  ┌──────────────┐  ┌─────────────┐             │
│  │   Higress   │  │   Tuwunel    │  │    MinIO    │             │
│  │ AI Gateway  │  │Matrix Server │  │ File System │             │
│  │   :8080     │  │    :6167     │  │ :9000/:9001 │             │
│  └──────┬──────┘  └──────┬───────┘  └──────┬──────┘             │
│         │                │                  │                    │
│         └────────────────┼──────────────────┘                    │
│                          │                                       │
│  ┌───────────────────────┴───────────────────────┐              │
│  │          Manager Agent (OpenClaw)              │              │
│  │    协调者：创建 Worker、分配任务、监控进度      │              │
│  └────────────────────────────────────────────────┘              │
│                                                                  │
│  ┌──────────────┐                                                │
│  │ Element Web  │ ← 人类通过浏览器访问                           │
│  │    :8088     │                                                │
│  └──────────────┘                                                │
└─────────────────────────────────────────────────────────────────┘
                              │
                    Matrix + HTTP Files
                              │
        ┌─────────────────────┼─────────────────────┐
        │                     │                     │
        ▼                     ▼                     ▼
┌───────────────┐     ┌───────────────┐     ┌───────────────┐
│Worker: Alice  │     │ Worker: Bob   │     │ Worker: ...   │
│  (OpenClaw)   │     │  (OpenClaw)   │     │  (OpenClaw)   │
│ + mc + mcporter     │ + mc + mcporter     │ + mc + mcporter
└───────────────┘     └───────────────┘     └───────────────┘
```

### 1.2 技术栈对照表

| 组件 | 技术 | 端口 | 职责 |
|------|------|------|------|
| AI Gateway | Higress | 8080 (Gateway) / 8001 (Console) | LLM 代理、MCP Server 托管、消费者认证、路由管理 |
| Matrix Server | Tuwunel (conduwuit fork) | 6167 | Agent 与人类之间的 IM 通信 |
| Matrix Client | Element Web | 8088 | 浏览器端 IM 界面 |
| File System | MinIO + mc mirror | 9000 (API) / 9001 (Console) | 集中式 HTTP 文件存储，双向实时同步 |
| Agent Runtime | OpenClaw | 18799 (Manager) / 18800 (Worker) | 带 Matrix 插件和技能系统的 Agent 运行时 |
| MCP CLI | mcporter | - | Worker 调用 MCP Server 工具的命令行接口 |

---

## 2. 通信协议与消息传递

### 2.1 Matrix 协议核心

HiClaw 选择 **Matrix** 作为 Agent 间通信协议，而非传统的 MCP 直接调用，原因如下：

| 对比维度 | MCP (Model Context Protocol) | Matrix |
|----------|------------------------------|--------|
| **设计目的** | LLM 调用工具/获取上下文 | 实时通信/IM |
| **通信模式** | 请求-响应（同步） | 持久连接 + 消息推送（异步） |
| **多方参与** | 单一 Client-Server | 多人群聊，联邦互通 |
| **人工介入** | 难以实现 | 原生支持（Human-in-the-Loop） |
| **消息历史** | 无 | 完整保留 |
| **移动端** | ❌ | ✅ Element、FluffyChat 等多客户端 |

### 2.2 Tuwunel 服务器配置

Tuwunel 是 conduwuit 的分支，使用 `CONDUWUIT_` 环境变量前缀：

```bash
# 核心配置
export CONDUWUIT_SERVER_NAME="${HICLAW_MATRIX_DOMAIN:-matrix-local.hiclaw.io:8080}"
export CONDUWUIT_DATABASE_PATH="/data/tuwunel"
export CONDUWUIT_PORT=6167
export CONDUWUIT_ALLOW_REGISTRATION=true
export CONDUWUIT_REGISTRATION_TOKEN="${HICLAW_REGISTRATION_TOKEN}"
```

**关键特性**：
- 运行在端口 6167（Manager 内部直连）
- 使用 **单步注册 token**（不是复杂的 UIAA 流程）
- 轻量高性能（Rust 编写）

### 2.3 消息格式与 @Mention 机制

**这是最关键的技术点**：Workers 配置了 `requireMention: true`，意味着它们只响应被正确 @ 提及的消息。

#### 正确的消息格式（Worker 会响应）

```bash
curl -X PUT "http://127.0.0.1:6167/_matrix/client/v3/rooms/${ROOM_ID}/send/m.room.message/${TXN_ID}" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H 'Content-Type: application/json' \
  -d '{
    "msgtype": "m.text",
    "body": "@alice:matrix-local.hiclaw.io:8080 请实现登录页面",
    "m.mentions": {
      "user_ids": ["@alice:matrix-local.hiclaw.io:8080"]
    }
  }'
```

#### 错误的消息格式（Worker 会忽略）

```bash
# 缺少 m.mentions 字段，Worker 收到但不会处理！
curl -X PUT "http://127.0.0.1:6167/_matrix/client/v3/rooms/${ROOM_ID}/send/m.room.message/${TXN_ID}" \
  -H "Authorization: Bearer ${TOKEN}" \
  -d '{"msgtype": "m.text", "body": "@alice 请实现登录页面"}'
```

#### @mention 规则

1. `m.mentions.user_ids` 数组必须包含完整的 Matrix 用户 ID（如 `@alice:matrix-local.hiclaw.io:8080`）
2. body 文本中的 @ 和 `m.mentions.user_ids` 必须完全匹配
3. 这遵循 Matrix MSC3952 (Intentional Mentions) 规范

### 2.4 OpenClaw Matrix 通道配置

#### Manager 配置（manager-openclaw.json.tmpl）

```json
{
  "channels": {
    "matrix": {
      "enabled": true,
      "homeserver": "http://127.0.0.1:6167",
      "accessToken": "${MANAGER_MATRIX_TOKEN}",
      "dm": {
        "policy": "allowlist",
        "allowFrom": ["@${HICLAW_ADMIN_USER}:${HICLAW_MATRIX_DOMAIN}"]
      },
      "groupPolicy": "allowlist",
      "groupAllowFrom": ["@${HICLAW_ADMIN_USER}:${HICLAW_MATRIX_DOMAIN}"],
      "groups": {
        "*": { "allow": true, "requireMention": true }
      }
    }
  }
}
```

#### Worker 配置（worker-openclaw.json.tmpl）

```json
{
  "channels": {
    "matrix": {
      "enabled": true,
      "homeserver": "${HICLAW_MATRIX_SERVER}",
      "accessToken": "${WORKER_MATRIX_TOKEN}",
      "dm": {
        "policy": "allowlist",
        "allowFrom": []  // Worker 不接受私信
      },
      "groupPolicy": "allowlist",
      "groupAllowFrom": [
        "@manager:${HICLAW_MATRIX_DOMAIN}",
        "@${HICLAW_ADMIN_USER}:${HICLAW_MATRIX_DOMAIN}"
      ],
      "groups": {
        "*": { "allow": true, "requireMention": true }
      }
    }
  }
}
```

**关键差异**：
- Manager 可以接受 Admin 的私信（DM）
- Worker 只在群聊中响应，且必须被 @ 提及
- 两者都只响应白名单用户的消息

---

## 3. Agent 角色与交互模式

### 3.1 角色定义

| 角色 | 职责 | 通信方式 |
|------|------|----------|
| **Human Admin** | 决策者，下达任务，监督执行 | Element Web / 手机 Matrix 客户端 |
| **Manager Agent** | 协调者，创建 Worker、分配任务、监控进度 | Matrix DM (与 Admin) + 群聊 (与 Worker) |
| **Worker Agent** | 执行者，完成具体任务，汇报进度 | 群聊 (被 @ 时响应) |

### 3.2 三方房间模型

每个 Worker 创建时，Manager 会创建一个包含三方的 Matrix 房间：

```
Room: "Worker: Alice"
├── 成员: @admin, @manager, @alice
├── Manager 分配任务 → 所有人可见
├── Alice 汇报进度 → 所有人可见
├── Human 随时可介入 → 所有人可见
└── 没有隐藏的 Agent 间通信
```

**创建房间 API**：

```bash
curl -X POST http://127.0.0.1:6167/_matrix/client/v3/createRoom \
  -H "Authorization: Bearer ${MANAGER_TOKEN}" \
  -H 'Content-Type: application/json' \
  -d '{
    "name": "Worker: Alice",
    "topic": "Communication channel for alice",
    "invite": [
      "@admin:matrix-local.hiclaw.io:8080",
      "@alice:matrix-local.hiclaw.io:8080"
    ],
    "preset": "trusted_private_chat"
  }'
```

### 3.3 消息流示例

```
┌────────────────────────────────────────────────────────────────┐
│                   Matrix Room: "Worker: Alice"                  │
├────────────────────────────────────────────────────────────────┤
│                                                                 │
│  @admin: @alice 帮我用 React 实现一个登录页面                   │
│                     │                                           │
│                     ▼ [m.mentions 触发 Worker]                  │
│  @alice: 收到！正在分析需求...                                  │
│                                                                 │
│  @alice: 登录页面实现完成，包含以下功能：                       │
│          - 用户名/密码输入                                      │
│          - 表单验证                                             │
│          - 错误提示                                             │
│          PR 已提交: https://github.com/xxx/pull/1               │
│                                                                 │
│  @manager: Alice 的任务已完成，用时 15 分钟                     │
│                                                                 │
│  @admin: @alice 等等，密码规则改成至少 8 位                     │
│                     │                                           │
│                     ▼ [Human-in-the-Loop 介入]                  │
│  @alice: 好的，正在修改...已更新密码校验规则。                  │
│                                                                 │
└────────────────────────────────────────────────────────────────┘
```

### 3.4 多 Worker 协作

当任务需要多个 Worker 协作时：

```
Human Admin → Manager (DM)
    │
    │ "Alice 和 Bob 协作：Alice 做前端，Bob 做后端"
    │
    ▼
Manager → Alice's Room
    │ "@alice 请实现前端登录页面，与 Bob 的后端 API 对接"
    │
Manager → Bob's Room
    │ "@bob 请实现后端登录 API，返回格式为 {token, user}"
    │
    ▼
Alice 和 Bob 通过 MinIO 共享文件进行协调：
    - shared/tasks/task-xxx/alice-output.json
    - shared/tasks/task-xxx/bob-api-spec.md
```

---

## 4. 人类监督与介入机制

### 4.1 Human-in-the-Loop 设计原则

HiClaw 的核心设计理念是 **"所有通信都在 Matrix 房间里，人类看得到一切，随时可以介入"**。

```
┌─────────────────────────────────────────────────────────────────┐
│                     Human-in-the-Loop 架构                       │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│    ┌──────────────────────────────────────────────────────┐     │
│    │              Matrix Room (3-party)                    │     │
│    │                                                       │     │
│    │   Human ◄──────────► Manager ◄──────────► Worker     │     │
│    │     │                   │                    │        │     │
│    │     │    [所有消息对所有成员可见]             │        │     │
│    │     │                   │                    │        │     │
│    │     └───────────────────┼────────────────────┘        │     │
│    │                         │                             │     │
│    │            [人类可随时 @ 任何人介入]                  │     │
│    │                                                       │     │
│    └──────────────────────────────────────────────────────┘     │
│                                                                  │
│    特点：                                                        │
│    ✓ 没有黑盒                                                   │
│    ✓ 没有隐藏的 Agent 间调用                                    │
│    ✓ 完整的审计追踪                                             │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### 4.2 介入方式

| 介入类型 | 操作方式 | 示例 |
|----------|----------|------|
| **直接指令** | @ 特定 Worker | `@alice 停止当前工作，先做登录页` |
| **补充说明** | 在进行中的任务房间发消息 | `补充需求：密码需要至少 8 位` |
| **任务调整** | 与 Manager DM | `把 Alice 的任务重新分配给 Bob` |
| **紧急停止** | @ 所有相关方 | `@alice @bob 立即停止，等待我的进一步指示` |

### 4.3 多渠道通信

Manager 支持多种通信渠道，Admin 可以从任意渠道联系 Manager：

```
┌─────────────────────────────────────────────────────────────────┐
│                     Multi-Channel Architecture                   │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ┌─────────┐   ┌─────────┐   ┌─────────┐   ┌─────────┐         │
│  │ Matrix  │   │ Discord │   │ Feishu  │   │Telegram │         │
│  │  DM     │   │         │   │         │   │         │         │
│  └────┬────┘   └────┬────┘   └────┬────┘   └────┬────┘         │
│       │             │             │             │                │
│       └─────────────┴──────┬──────┴─────────────┘                │
│                            │                                     │
│                            ▼                                     │
│                    ┌──────────────┐                              │
│                    │   Manager    │                              │
│                    │   Agent      │                              │
│                    └──────┬───────┘                              │
│                           │                                      │
│              Primary Channel (可配置)                            │
│                           │                                      │
│              ┌────────────┼────────────┐                         │
│              │            │            │                         │
│              ▼            ▼            ▼                         │
│          Daily        Urgent      Worker                         │
│         Keepalive   Escalation    Rooms                          │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

**Primary Channel** 存储在 `~/hiclaw-manager/primary-channel.json`，Manager 的主动通知（如日常心跳）会发送到这个渠道。

### 4.4 跨渠道升级（Cross-Channel Escalation）

当 Manager 在 Matrix 项目房间工作时，如果需要紧急的 Admin 决策，它可以将问题升级到 Admin 的主渠道（如 Discord DM），Admin 的回复会自动路由回原始房间。

---

## 5. 凭证管理与安全模型

### 5.1 凭证隔离架构

```
┌─────────────────────────────────────────────────────────────────┐
│                      Security Architecture                       │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  Worker (只持有消费者令牌 - 类似"工牌")                          │
│      │                                                           │
│      │ BEARER token (唯一凭证)                                   │
│      ▼                                                           │
│  ┌────────────────────────────────────────┐                      │
│  │         Higress AI Gateway             │                      │
│  │   (持有所有真实凭证，Worker 不可见)    │                      │
│  │                                        │                      │
│  │  ┌─────────────────────────────────┐  │                      │
│  │  │ Consumer: manager               │  │                      │
│  │  │   Routes: AI + FS + MCP(all)    │  │                      │
│  │  │   Full access                   │  │                      │
│  │  └─────────────────────────────────┘  │                      │
│  │                                        │                      │
│  │  ┌─────────────────────────────────┐  │                      │
│  │  │ Consumer: worker-alice          │  │                      │
│  │  │   Routes: AI + FS + MCP(github) │  │                      │
│  │  │   Limited access                │  │                      │
│  │  └─────────────────────────────────┘  │                      │
│  │                                        │                      │
│  │  ┌─────────────────────────────────┐  │                      │
│  │  │ Consumer: worker-bob            │  │                      │
│  │  │   Routes: AI + FS               │  │                      │
│  │  │   No MCP access                 │  │                      │
│  │  └─────────────────────────────────┘  │                      │
│  │                                        │                      │
│  │  ┌─────────────────────────────────┐  │                      │
│  │  │ Real Credentials (Worker 不可见) │  │                      │
│  │  │   - LLM API Key                 │  │                      │
│  │  │   - GitHub PAT                  │  │                      │
│  │  │   - Other MCP Server secrets    │  │                      │
│  │  └─────────────────────────────────┘  │                      │
│  └────────────────────────────────────────┘                      │
│      │                                                           │
│      ▼                                                           │
│  LLM API / GitHub API / Other MCP Servers                        │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### 5.2 安全优势

1. **Worker 永不持有真实凭证**：即使 Worker 被攻击，攻击者也拿不到 API Key 或 GitHub PAT
2. **细粒度权限控制**：Manager 可以动态调整每个 Worker 的 MCP 访问权限
3. **集中审计**：所有 API 调用都经过 Higress Gateway，可集中记录和监控

### 5.3 动态权限管理

**撤销 MCP 权限**：
```
Admin: 撤销 Alice 对 GitHub MCP Server 的访问
Manager: 好的，已撤销。Alice 现在尝试 GitHub 操作会收到 403 错误。
```

**恢复 MCP 权限**：
```
Admin: 恢复 Alice 对 GitHub MCP Server 的访问
Manager: 已恢复。Alice 可以正常执行 GitHub 操作了。
```

---

## 6. 文件系统与状态同步

### 6.1 双存储架构

HiClaw 使用两种存储：

| 存储类型 | 路径 | 同步方式 | 用途 |
|----------|------|----------|------|
| **Manager Workspace** | `~/hiclaw-manager/` (host) | 不同步 | Manager 本地状态、配置 |
| **MinIO Object Storage** | `hiclaw-storage/` bucket | `mc mirror --watch` 双向同步 | Agent 配置、任务数据、共享文件 |

### 6.2 文件系统布局

#### Manager Workspace（本地，不同步）

```
~/hiclaw-manager/                    # Host path (bind-mounted)
├── SOUL.md                          # Manager identity
├── AGENTS.md                        # Workspace guide
├── HEARTBEAT.md                     # Heartbeat checklist
├── openclaw.json                    # OpenClaw config (regenerated each boot)
├── skills/                          # Manager's own skills
├── worker-skills/                   # Worker skill definitions
├── workers-registry.json            # Worker skill assignments and room IDs
├── state.json                       # Active task state
├── worker-lifecycle.json            # Worker container status and idle tracking
├── primary-channel.json             # Admin's preferred primary channel
├── trusted-contacts.json            # Non-admin contacts allowed to converse
├── coding-cli-config.json           # Coding CLI delegation config
├── yolo-mode                        # If present, enables YOLO mode
├── .session-scan-last-run           # Timestamp of last session expiry scan
└── memory/                          # Manager's memory files
```

#### MinIO Object Storage（共享，双向同步）

```
MinIO bucket: hiclaw-storage/        # Mirrored to ~/hiclaw-fs/ on Manager
├── agents/
│   ├── alice/                       # Worker Alice config
│   │   ├── SOUL.md                  # Worker identity
│   │   ├── openclaw.json            # OpenClaw config
│   │   ├── skills/                  # Worker skills
│   │   └── mcporter-servers.json    # MCP server endpoints
│   └── bob/                         # Worker Bob config
├── shared/
│   ├── tasks/                       # Task specs, metadata, and results
│   │   └── task-{id}/
│   │       ├── meta.json            # Task metadata
│   │       ├── spec.md              # Complete task spec
│   │       ├── base/                # Reference files
│   │       └── result.md            # Task result
│   └── knowledge/                   # Shared reference materials
└── workers/                         # Worker work products
```

### 6.3 文件同步机制

```
┌─────────────────────────────────────────────────────────────────┐
│                    File Sync Architecture                        │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  Manager Container                                               │
│  ┌────────────────────┐    mc mirror    ┌──────────────────┐    │
│  │  ~/hiclaw-fs/      │ ◄────────────► │      MinIO       │    │
│  │  (local copy)      │    --watch      │    :9000         │    │
│  └────────────────────┘                 └────────┬─────────┘    │
│                                                  │               │
│                                                  │ HTTP          │
│                                                  │               │
│  Worker Containers                               │               │
│  ┌────────────────────┐    mc mirror    ┌───────┴────────┐     │
│  │  ~/hiclaw-fs/      │ ◄────────────► │                 │     │
│  │  (local copy)      │  5-min cycle    │   (via Gateway) │     │
│  └────────────────────┘                 └─────────────────┘     │
│                                                                  │
│  同步规则：                                                      │
│  - Manager → MinIO: 实时 (--watch)                              │
│  - MinIO → Worker: 每 5 分钟 + 被通知时立即拉取                 │
│  - skills/** 目录: 只从 Manager 推送，Worker 不能修改            │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### 6.4 文件同步通知协议

当 Manager 更新了 Worker 需要读取的文件时，必须通过 Matrix @ 通知 Worker 运行 `hiclaw-sync`：

```
Manager → Worker's Room:
  "@alice 我已更新了任务说明，请运行 hiclaw-sync 拉取最新文件。"

Alice → Worker's Room:
  "收到，正在同步... 同步完成。"
```

---

## 7. 生命周期管理

### 7.1 Worker 创建流程

```
┌─────────────────────────────────────────────────────────────────┐
│                   Worker Creation Workflow                       │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  Step 1: Admin Request                                          │
│  ─────────────────────                                          │
│  Admin → Manager (DM):                                          │
│    "创建一个名为 alice 的前端 Worker，需要 GitHub MCP 权限"      │
│                                                                  │
│  Step 2: Manager Prepares                                       │
│  ───────────────────────                                        │
│  1. 写入 SOUL.md (Worker 身份定义)                              │
│  2. 确定技能分配 (读取 ~/worker-skills/ 下各技能的 assign_when) │
│                                                                  │
│  Step 3: Run create-worker.sh                                   │
│  ────────────────────────────                                   │
│  bash create-worker.sh --name alice --skills github-operations  │
│                                                                  │
│  脚本自动执行：                                                  │
│  ├── Matrix 用户注册                                            │
│  ├── 3-party Room 创建                                          │
│  ├── Higress Consumer 创建                                      │
│  ├── AI/MCP Route 授权                                          │
│  ├── Config 文件生成 (openclaw.json, mcporter-servers.json)     │
│  ├── Skills 推送                                                │
│  └── Container 创建并启动 (如有 socket 访问)                    │
│                                                                  │
│  Step 4: Post-Creation                                          │
│  ─────────────────────                                          │
│  Manager → Alice's Room:                                        │
│    "@alice 你已就绪！请向房间里的大家介绍一下自己。"             │
│                                                                  │
│  Alice → Alice's Room:                                          │
│    "大家好！我是 Alice，专注于前端开发..."                       │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### 7.2 Container API 实现

Manager 通过挂载 Docker/Podman socket 直接管理 Worker 容器：

```bash
# 检查 socket 可用性
container_api_available() {
    if [ ! -S "${CONTAINER_SOCKET}" ]; then
        return 1
    fi
    curl -s --unix-socket "${CONTAINER_SOCKET}" "${CONTAINER_API_BASE}/version" | grep -q '"ApiVersion"'
}

# 创建 Worker 容器
container_create_worker "alice"

# 启动已停止的容器
container_start_worker "alice"

# 停止容器
container_stop_worker "alice"

# 获取容器状态
container_status_worker "alice"  # 返回: running, stopped, not_found
```

### 7.3 自动生命周期管理

Manager 在心跳检查时自动管理 Worker 容器：

```
┌─────────────────────────────────────────────────────────────────┐
│                 Automatic Lifecycle Management                   │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │                    Heartbeat (每小时)                     │   │
│  └──────────────────────────────────────────────────────────┘   │
│                              │                                   │
│                              ▼                                   │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │  检测空闲 Worker                                         │   │
│  │  (idle_timeout_minutes: 30, 可配置)                      │   │
│  └──────────────────────────────────────────────────────────┘   │
│                              │                                   │
│          ┌───────────────────┼───────────────────┐               │
│          │                   │                   │               │
│          ▼                   ▼                   ▼               │
│   ┌────────────┐     ┌────────────┐      ┌────────────┐         │
│   │ 有活跃任务 │     │ 空闲 < 30m │      │ 空闲 ≥ 30m │         │
│   │ → 询问进度 │     │ → 保持运行 │      │ → 自动停止 │         │
│   └────────────┘     └────────────┘      └────────────┘         │
│                                                                  │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │                    任务分配时                             │   │
│  └──────────────────────────────────────────────────────────┘   │
│                              │                                   │
│                              ▼                                   │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │  自动唤醒已停止的 Worker                                  │   │
│  │  container_start_worker "alice"                          │   │
│  └──────────────────────────────────────────────────────────┘   │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### 7.4 Session 管理

OpenClaw 使用基于类型的会话策略：

```json
{
  "session": {
    "resetByType": {
      "dm":    { "mode": "daily", "atHour": 4 },
      "group": { "mode": "idle",  "idleMinutes": 2880 }
    }
  }
}
```

| 会话类型 | 重置策略 | 说明 |
|----------|----------|------|
| **DM** (Manager ↔ Admin) | 每天 04:00 重置 | 防止上下文无限积累 |
| **Group** (Worker Rooms) | 2 天 (2880 分钟) 空闲后重置 | 保持任务上下文 |

**每日 Keepalive 通知** (10:00-10:59)：Manager 会通知 Admin 哪些房间即将因空闲被重置，Admin 可选择发送 keepalive 消息维持会话。

---

## 8. 关键技术实现

### 8.1 技术要点速查

| 问题 | 正确实现 | 常见错误 |
|------|----------|----------|
| Tuwunel 环境变量前缀 | `CONDUWUIT_` | ~~`TUWUNEL_`~~ |
| Higress Console 认证 | Session Cookie | ~~Basic Auth~~ |
| MCP Server 创建 | `PUT /v1/mcpServer` | ~~`POST /v1/mcpServer`~~ |
| Auth 插件生效时间 | ~40s | 立即 |
| OpenClaw Skills 自动加载路径 | `workspace/skills/<name>/SKILL.md` | - |
| Node.js 版本要求 | >= 22 | ~~20 或更低~~ |
| Worker 响应条件 | 必须包含 `m.mentions` | 只在 body 中 @user |

### 8.2 OpenClaw Gateway 配置

OpenClaw 必须配置 gateway 才能在无头模式下运行：

```json
{
  "gateway": {
    "mode": "local",
    "port": 18799,
    "auth": { "token": "<some-token>" }
  }
}
```

**错误**：缺少 `gateway.mode=local` → OpenClaw 拒绝启动
**错误**：缺少 `gateway.auth.token` → OpenClaw 拒绝启动

### 8.3 Skills 格式要求

SKILL.md 文件 **必须** 包含 YAML front matter，否则 OpenClaw 不会发现：

```markdown
---
name: my-skill-name
description: What this skill does and when to use it
assign_when: What role/responsibility warrants this skill (for Workers)
---

# Skill Title
...content...
```

### 8.4 Higress AI Provider 变通方案

Higress Console API 不支持直接创建 `qwen` 类型 provider（会返回 "Missing Qwen specific configurations"）。变通方案是使用 `type=openai` + 自定义 API URL：

```json
{
  "name": "qwen",
  "type": "openai",
  "tokens": ["your-api-key"],
  "rawConfigs": {
    "apiUrl": "https://dashscope.aliyuncs.com/compatible-mode/v1"
  }
}
```

---

## 附录：API 快速参考

### Matrix API

| 操作 | Endpoint | Method |
|------|----------|--------|
| 注册用户 | `/_matrix/client/v3/register` | POST |
| 登录 | `/_matrix/client/v3/login` | POST |
| 创建房间 | `/_matrix/client/v3/createRoom` | POST |
| 发送消息 | `/_matrix/client/v3/rooms/{roomId}/send/m.room.message/{txnId}` | PUT |
| 获取已加入房间 | `/_matrix/client/v3/joined_rooms` | GET |
| 获取房间消息 | `/_matrix/client/v3/rooms/{roomId}/messages` | GET |

### Container API (via Docker Socket)

| 操作 | Endpoint | Method |
|------|----------|--------|
| 创建容器 | `/containers/create?name={name}` | POST |
| 启动容器 | `/containers/{id}/start` | POST |
| 停止容器 | `/containers/{id}/stop` | POST |
| 删除容器 | `/containers/{id}?force=true` | DELETE |
| 获取状态 | `/containers/{id}/json` | GET |
| 获取日志 | `/containers/{id}/logs` | GET |

### Higress Console API

| 操作 | Endpoint | Method |
|------|----------|--------|
| 登录 | `/session/login` | POST |
| 列出 Consumer | `/v1/consumers` | GET |
| 创建 Consumer | `/v1/consumers` | POST |
| 列出 AI Provider | `/v1/ai/providers` | GET |
| 创建 MCP Server | `/v1/mcpServer` | PUT |
| 授权 MCP Consumer | `/v1/mcpServer/consumers` | PUT |

---

*文档生成时间：2026-03-04*
*基于 HiClaw 项目代码和技术文档*
