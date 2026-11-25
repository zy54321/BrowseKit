# 018-BrowseKit 技术架构与组装说明

> **文档定位**：记录 `018-BrowseKit` 的整体组件构成、通信链路、沙箱边界与核心运维基线。  
> **建议存放位置**：`E:\01_Work\01_PersonalProjects\018-BrowseKit\ARCHITECTURE.md`（位于项目根目录、容器挂载沙箱 `/workspace` 之外，防止被自动化工具误改，且打开项目即可速查）。  
> **最后更新**：2026-11-24（v1.0.3 三入口、开发隔离与按需槽位）
> **当前版本：v1.0.3**

---

## 1. 项目定位与核心目标

`018-BrowseKit` 是一套运行于 Windows 11 本地的**全网页化 AI 浏览器自动化与标书分析基础设施**，主要用于政采/军采机会筛查、多平台招投标信息获取及日常工程资料收集。

核心设计原则：
1. **脱离 IDE 依赖，全网页化**：不依赖 Cursor 或 Codex，使用独立网页控制台操作，原生适配接入 `015-FamilyOS` 网关与 Homarr 看板。
2. **复用真实登录态，拒绝脆弱模拟登录**：由人工在独立 Chrome 中正常登录账号并保留会话，自动化层仅做页面接管，不触碰密码、不做反爬对抗。
3. **长任务防失忆、可续跑、可审计**：任务状态强制落盘到 Markdown 账本文件，不依赖易遗忘的模型对话上下文。
4. **严格沙箱隔离与只读红线**：模型仅能读写 `/workspace` 沙箱，严禁触碰报名、投标、付款等外部写入操作。

---

## 2. 系统组件清单

整套工具拆分为 5 个解耦模块，分布在 **Docker 容器**、**Windows 11 宿主机** 和 **云端模型 API** 三层：

| 层级 | 组件名称 | 运行位置 / 镜像 | 监听地址与端口 | 核心职责 |
| :--- | :--- | :--- | :--- | :--- |
| **1. 网页控制台** | **Open WebUI** (`browsekit-webui`) | Docker 容器（v0.13.4） | `3000`（容器内 `8080`） | 提供独立网页交互界面、自定义助手管理、工具调用可视化及用户权限管理（已关闭自助注册）。 |
| **2. 推理大脑** | **DeepSeek-V4.1-Flash** + 自定义预设「政采筛查浏览器助手」 | 云端 OpenAI 兼容接口 (`https://api.deepseek.com/v1`) | HTTPS 出站 | 负责页面理解、多模态看图、标书筛查与工具编排；启用原生函数调用（Native）与低温度（`0.2`）。 |
| **3. 浏览器执行层** | **AI 专用 Chrome**（Chrome 157） + **`@playwright/mcp`** | Windows 11 宿主机（PowerShell 5.1 启动） | Chrome CDP: `8933`<br>MCP: `127.0.0.1:8931` | 专用 Chrome 使用独立 `chrome-profile` 保存真实登录态并将下载路径锁死在 `workspace\inbox\`；Playwright MCP 通过 CDP 接管浏览器，暴露页面快照、点击、切标签页、截图等能力。 |
| **4. 文件与解析层** | **`browsekit-tools:local`**（基于 `mcpo` 自定义构建，1.87 GB） | Docker 容器（`browsekit-net`） | `127.0.0.1:8932` → 容器 `8000` | 受 `MCPO_API_KEY` 保护的两套 OpenAPI 工具：<br>• **`/filesystem`**：`/workspace` 内的读写、建目录、移动与重命名；<br>• **`/markitdown`**：内置 **LibreOffice 7.4.7.2 无头版** + **MarkItDown**，透明支持 `.docx`/`.doc`/`.pdf`/`.xlsx`/`.xls`/`.rtf` 等全格式全文提取。 |
| **5. 任务账本层** | **Local Workspace** | 宿主机 `workspace\` 映射至容器 `/workspace` | 本地卷挂载 | 存放防失忆模板、静默下载收件箱及按项目分目录归档的任务报告与采购文件。 |

---

## 3. 整体组装与数据流转

### 3.1 架构拓扑

```text
[用户浏览器访问 Open WebUI :3000]
              │
              ▼
┌──────────────────────────────────────────────────────────┐
│ Docker 内部网络 (browsekit-net)                           │
│                                                          │
│  ┌──────────────────────┐    OpenAPI + Bearer Key        │
│  │   browsekit-webui    │ ────────────────────────────┐  │
│  │   (Open WebUI)       │                             ▼  │
│  └──────────┬───────────┘          ┌───────────────────┐ │
│             │                      │ browsekit-tools   │ │
│  ① 发送提示词与工具描述             │  • /filesystem    │ │
│     接收结构化工具调用              │  • /markitdown    │ │
│             │                      │ (LO 7.4 + Python) │ │
│             ▼                      └─────────┬─────────┘ │
│  [DeepSeek API 云端]                         │ 只读写    │
└─────────────┼────────────────────────────────┼───────────┘
              │ ② MCP (Streamable HTTP)        │ 卷挂载
              │   host.docker.internal:8931    │ (/workspace)
              ▼                                ▼
┌──────────────────────────────────────────────────────────┐
│ Windows 11 宿主机                                         │
│                                                          │
│  ┌──────────────────────┐         ┌───────────────────┐  │
│  │  @playwright/mcp     │         │ workspace\        │  │
│  │  (127.0.0.1:8931)    │         │  ├─ inbox\ ◄──────┼──┼─ Chrome 静默下载
│  └──────────┬───────────┘         │  ├─ templates\    │  │
│             │ CDP 远程调试 (:8933) │  └─ tasks\        │  │
│             ▼                     └───────────────────┘  │
│  ┌──────────────────────┐                                │
│  │  AI 专用 Chrome       │ ◄─── 人工登录真实账号          │
│  │  (独立 chrome-profile)│ ──── 访问招标雷达 / 政采网     │
│  └──────────────────────┘                                │
└──────────────────────────────────────────────────────────┘
```

### 3.2 单次筛标任务的完整执行链路

1. **入口就位**：用户在专用 Chrome 中手动打开并登录目标站点（如招标雷达/标标达、政采网等），停留在列表页。
2. **建立账本**：用户在 Open WebUI 选中「政采筛查浏览器助手」发指令；模型首先调用 `/filesystem` 读取 `/workspace/templates/`，在 `/workspace/tasks/YYYY-MM-DD_站点_主题/` 下初始化 `GOAL.md`、`PROGRESS.md`、`REPORT.md` 与 `files/`。
3. **浏览与筛查**：模型通过 `host.docker.internal:8931/mcp` 读取当前页面结构快照（snapshot），按预算与行业标准初筛列表；点击候选标题切入新标签页核查详情（聚合站允许点击「阅读原文」跳原发布站查正文与公开附件），每核查 1–3 条即更新 `PROGRESS.md` 断点。
4. **无弹窗下载与跨容器交接**：点击下载链接（严格只点 1 次，不等待 Playwright `download` 事件）后，专用 Chrome 将附件静默落盘至宿主机 `workspace\inbox\`；模型等待 3–5 秒后直接通过 `/filesystem` 检查 `/workspace/inbox/`，确认无 `.crdownload` / `.tmp` 临时文件残留。
5. **全格式标书解析**：模型将文件路径传入 `/markitdown`（`convert_to_markdown`）：
   - `.docx` / `.pdf` / `.xlsx` / `.pptx` / `.html` 等由 MarkItDown 直接提取；
   - `.doc` / `.rtf` / `.wps` / `.xls` 等老旧 OLE2 格式由 `server.py` 在隔离临时目录自动唤起无头 LibreOffice（`soffice --headless`，超时 90 秒）转为 `.docx` / `.xlsx` 后提取全文，退出即清理临时目录与 profile，原文件只读不改。
6. **分项目归档与汇报**：保留或待确认项目在任务目录 `files/` 下建立独立子文件夹（如 `files/01_项目简称/`）归档附件；按 8 项固定核查标准生成 `REPORT.md`，并在 Open WebUI 对话末尾输出固定 4 段汇报（基本情况、含官方链接的候选清单、本地档案路径、异常与待人工项）。

---

## 4. 目录结构与边界约束

```text
E:\01_Work\01_PersonalProjects\018-BrowseKit\
├─ ARCHITECTURE.md          # 本架构文档（位于沙箱外）
├─ chrome-profile\          # AI 专用 Chrome 独立配置与登录态（严禁挂载进容器）
├─ docker\                  # 容器编排与自定义工具镜像（严禁挂载进工具容器）
│  ├─ .env                  # 密钥配置（WEBUI_SECRET_KEY / MCPO_API_KEY 等，严禁明文入库）
│  ├─ docker-compose.yml    # 编排 browsekit-webui 与 browsekit-tools
│  ├─ mcpo-config.json      # 注册 filesystem 与自定义 markitdown 服务
│  └─ tools\
│     ├─ Dockerfile         # 基于 ghcr.io/open-webui/mcpo:main，预装 LO 7.4.7.2 与 venv
│     └─ server.py          # FastMCP (mcp>=1.2,<2) 包装器：路径沙箱 + LO 透明转换
└─ workspace\               # 容器唯一可读写沙箱（映射为容器内 /workspace）
   ├─ inbox\                # 专用 Chrome 唯一静默下载落点（处理完清空）
   ├─ templates\            # GOAL.md / PROGRESS.md / REPORT.md 标准模板
   └─ tasks\                # 按日期与任务隔离的档案目录
      └─ YYYY-MM-DD_站点_主题\
         ├─ GOAL.md         # 任务目标与筛选边界
         ├─ PROGRESS.md     # 实时断点、列表全量初筛表与异常记录
         ├─ REPORT.md       # 候选项目 8 项固定核查报告
         └─ files\
            └─ 01_项目简称\  # 按项目独立归档的招标文件与附件
```

---

## 5. 安全隔离与工程红线

| 维度 | 具体落盘措施 |
| :--- | :--- |
| **网络隔离** | Playwright MCP（`8931`）与工具服务（`8932`）全部收紧绑定在 `127.0.0.1`，外网与局域网无法直连。 |
| **账号隔离** | Open WebUI 已关闭「新注册用户」开关，仅管理员可登录；`browsekit-tools` 接口强制要求 `Bearer MCPO_API_KEY` 鉴权。 |
| **文件沙箱** | `browsekit-tools` 仅挂载 `../workspace:/workspace`（读写）与 `mcpo-config.json`（只读），绝不挂载 `.env`、项目根目录或 `chrome-profile`。`server.py` 额外执行 `os.path.realpath` 校验，拦截一切 `../` 穿透与 `/workspace` 外路径访问。 |
| **浏览器隔离** | 专用 Chrome 使用独立 `--user-data-dir`，与日常个人浏览器进程和 Cookie 完全物理隔离。 |
| **业务动作红线** | 助手系统提示词硬性禁止点击「报名」「提交」「投标」「付款」「修改账号」等外部写入按钮；遇登录墙、图形/滑块/短信验证码或必须报名才可下载的文件时，原地停下交人工处理。 |

---

## 6. Open WebUI 关键配置基线（重建/迁移参考）

### 6.1 外部连接（模型接口）
- **URL**：`https://api.deepseek.com/v1`
- **认证**：Bearer（DeepSeek 官方 API Key）
- **基础模型**：`DeepSeek-V4.1-Flash`（确认开启 **视觉 Vision** 能力）

### 6.2 外部工具服务器（扩展功能）
| 名称 | 类型 | URL | 认证方式 |
| :--- | :--- | :--- | :--- |
| 工作区文件 | OpenAPI | `http://browsekit-tools:8000/filesystem` | Bearer (`MCPO_API_KEY`) |
| 文档解析 | OpenAPI | `http://browsekit-tools:8000/markitdown` | Bearer (`MCPO_API_KEY`) |
| 浏览器控制 | MCP (Streamable HTTP) | `http://host.docker.internal:8931/mcp` | 无（None） |

### 6.3 自定义助手预设
- **名称**：`政采筛查浏览器助手`
- **模型 ID**：`procurement-assistant`
- **基础模型**：`DeepSeek-V4.1-Flash`
- **工具勾选**：工作区文件、文档解析、浏览器控制（关闭未配置的「代码解释器」与「终端」）
- **高级参数**：函数调用 = **原生模式（Native）**，Temperature = **`0.2`**

---

## 7. 项目进度与维护备忘

### 当前里程碑
- [x] **Phase 0 & 1**：宿主机只读勘察、`018-BrowseKit` 目录与模板初始化、专用 Chrome + Playwright MCP 接管与下载锁死 `inbox\`。
- [x] **Phase 2**：Open WebUI 与 `browsekit-tools` 容器化编排上线，三大工具全链路验证 HTTP 200。
- [x] **Phase 3**：政采网与招标雷达实机闭环验收；容器补齐 LibreOffice 7.4.7.2 无头转换（实测老版 `.doc` 6.5 秒提取 53,463 字符）；升级分项目归档、阅读原文跳转与 4 段带链接汇报提示词。
- [ ] **Phase 4**：将 Open WebUI 按 `015-FamilyOS` 现有 `apps.json`、Nginx 反代与 Homarr 机制正式接入统一入口。

### 关键运维注意点
1. **依赖版本锁定**：`docker/tools/Dockerfile` 中有意将 Python `mcp` 依赖锁定在 `mcp>=1.2,<2`（2.x 版本已将 `FastMCP` 重命名为 `MCPServer`），后续升级依赖时需同步调整 `server.py`。
2. **密钥轮换方法**：如需轮换本地 `MCPO_API_KEY`，修改 `docker/.env` 后仅需执行 `docker compose up -d browsekit-tools`，再在 Open WebUI「管理员面板 → 设置 → 扩展功能」同步更新 `filesystem` 与 `markitdown` 两条 Bearer 密钥即可。
3. **版本发布**：与台账相同，先双击 `01_提交GitHub.bat`，再双击 `02_制作Release.bat`，最后到 `E:\01_Work\03_Release\01_Personal\018-BrowseKit\<版本>\scripts\03_发布Prod.bat` 发布。正式登录态在 `E:\01_Work\04_Prod\01_Personal\018-BrowseKit\data\`，发布只新增版本目录并切换 `current.txt`。

---

## 8. v1.0.3 提交流程、Release 与按需槽位

正式数据在 `E:\01_Work\04_Prod\01_Personal\018-BrowseKit\data\`（`chrome-profile`、`workspace`、`.env`、`.run`）。开发目录里的同名文件夹只给本地保留，不参与发布，也不会被 Git 提交。

### 8.1 三个批处理

顺序与台账系统一致：

| 顺序 | 入口 | 位置 | 作用 |
| :--- | :--- | :--- | :--- |
| 1 | `01_提交GitHub.bat` | 开发目录 | 检查敏感文件后提交并 `git push`。不制作 Release，不发布 Prod。需要已配置 `origin`。公开仓库、提交和推送都只确认 `Y` 或 `N`。 |
| 2 | `02_制作Release.bat` | 开发目录 | 只接受已经推到 GitHub、且工作区干净的修订。自动查看已有 Release 目录和 Prod 版本号，取最大号后补丁加一，打包到新的 `vX.Y.Z` 目录，不覆盖旧版本。不安装、不升级 Prod。确认只按 `Y` 或 `N`。 |
| 3 | `scripts\03_发布Prod.bat` | Release 包内 | 把该版本复制到 `04_Prod\01_Personal\018-BrowseKit\vX.Y.Z`，停止旧版本后把 `current.txt` 切过去，再启动。不覆盖 `data\`，不使用 `docker compose down -v`。确认是 `YES-PROD`。 |

开发目录只保留 `01_提交GitHub.bat` 和 `02_制作Release.bat`。本地调试直接运行 `scripts\Dev-BrowseKit.ps1`，`-Action up` 启动，`-Action down` 只停开发环境。

### 8.2 端口对照

| 环境 | WebUI | MCP Host | MCPO | Chrome CDP | 配置目录 | 工作区 | 状态目录 |
| :--- | ---: | ---: | ---: | ---: | :--- | :--- | :--- |
| 生产 / 槽位 1 | 3000 | 8931 | 8932 | 8933 | `04_Prod\...\data\chrome-profile\` | `04_Prod\...\data\workspace\` | `04_Prod\...\data\.run\` |
| 开发（各 +10） | 3010 | 8941 | 8942 | 8943 | `chrome-profile-dev\` | `workspace-dev\` | `.run-dev\` |
| 槽位 2（按需） | — | 8962 | — | 8952 | `chrome-profile-slot2\` | `workspace-slot2\` | `.run-slot2\` |
| 槽位 3（按需） | — | 8963 | — | 8953 | `chrome-profile-slot3\` | `workspace-slot3\` | `.run-slot3\` |

槽位 N（N≥2）的 CDP 为 `8950+N`，MCP 为 `8960+N`。槽位不启动第二套 Open WebUI，也不随生产部署自动拉起。

```bat
scripts\slot.bat start 2
scripts\slot.bat stop 2
scripts\slot.bat status
```

`slot.bat start 1` / `stop 1` 不会改动生产 Chrome。生产主槽由 `04_Prod` 的 `启动BrowseKit.bat` 管理，发布则走 Release 包里的 `03_发布Prod.bat`。

### 8.3 无黑框

生产 MCP Host 隐藏启动，PID 写在 Prod `data\.run\playwright-mcp.pid`。托盘与热键随 `启动BrowseKit.bat` 隐藏驻留。专用 Chrome 仍是普通窗口，并在启动后送入第 2 虚拟桌面。三个批处理都像台账一样在结束时等待按键，方便看完结果。

### 8.4 发布与忽略

`.gitignore` 覆盖 `chrome-profile/`、`chrome-profile-*`、`workspace/`、`workspace-*`、`.run/`、`.run-*`、`.env` 与日志。可入库的任务模板在根目录 `templates\`，打进 Release 时变成 `workspace-templates\`。`01_提交GitHub.bat` 会拒绝上述路径和密钥特征。Release 包不含登录态、任务报告和 `.env`。