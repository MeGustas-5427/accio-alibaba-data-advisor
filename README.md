# Accio Alibaba Data Advisor

一个供 Codex 使用的本地技能：复用当前 Windows 用户已授权的 Accio 会话，读取 Alibaba.com Data Advisor 的店铺经营汇总和询盘访客明细。

本技能不会绕过登录或认证。请仅用于你有权访问的 Accio 与 Alibaba.com 账号。

## 📣 QQ 交流群

> [!IMPORTANT]
> **交流群号：`1094787834`**

## 功能

- 查询店铺经营汇总：`data_advisor_shop_summary`
- 查询询盘访客明细：`data_advisor_visitor_detail`
- 检查远程 Data Advisor 工具与认证状态
- 在 Accio 已打开并登录后更新本地 Token
- Token 有效期内，Accio 关闭后仍可执行查询

## 环境要求

- Windows
- PowerShell 7
- 已安装并登录 Accio
- Codex 技能目录

## 安装

将仓库克隆到 Codex 技能目录，并保持目录名为：

```text
accio-alibaba-data-advisor
```

Codex 会从 `SKILL.md` 读取技能说明。

## 首次配置与更新 Token

1. 打开 Accio 并确认已登录。
2. 在仓库目录运行：

```powershell
& ".\scripts\accio_data_advisor.ps1" -Action update-token
```

3. 验证连接：

```powershell
& ".\scripts\accio_data_advisor.ps1" -Action self-test
```

Token 保存在 `state/credentials.dpapi`，使用 Windows CurrentUser DPAPI 加密，只能由同一台电脑上的同一 Windows 用户解密。

## 使用

在 Codex 中可以直接提出：

```text
使用 accio-alibaba-data-advisor 查询 2026-07-01 到 2026-07-23 的店铺经营汇总。
```

也可以直接运行脚本。

查看状态：

```powershell
& ".\scripts\accio_data_advisor.ps1" -Action status
```

店铺经营汇总：

```powershell
& ".\scripts\accio_data_advisor.ps1" `
  -Action shop-summary `
  -StartDate 2026-07-01 `
  -EndDate 2026-07-23 `
  -StatisticsType day
```

询盘访客明细：

```powershell
& ".\scripts\accio_data_advisor.ps1" `
  -Action visitor-detail `
  -StartDate 2026-07-23 `
  -EndDate 2026-07-23 `
  -IsMcFb true `
  -PageNo 1 `
  -PageSize 20
```

`StatisticsType` 支持 `day`、`week`、`month`；`IsMcFb=true` 表示只查询产生询盘的访客。

## 安全

- `state/` 已由 `.gitignore` 忽略，禁止强制加入 Git。
- 不要打印、提交或上传 Token、Refresh Token、Cookie、Authorization 或 Accio 凭据文件。
- 不要把 `state/` 放进 `.skill` 包或其他交付物。
- 凭据过期后，重新打开并登录 Accio，再运行 `update-token`。
- 任一认证、工具目录或响应校验失败时，脚本会停止，不会把失败当作空数据。

## 文件结构

```text
.
├── .gitignore
├── README.md
├── SKILL.md
├── scripts/
│   └── accio_data_advisor.ps1
└── state/                    # 本地生成并被 Git 忽略
    └── credentials.dpapi
```
