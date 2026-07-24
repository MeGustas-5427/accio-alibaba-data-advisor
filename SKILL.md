---
name: accio-alibaba-data-advisor
description: 通过 Accio 已授权账号的远程 MCP 缓存、检索、导出并调用完整工具目录，也可直接查询 Alibaba.com Data Advisor 店铺经营汇总和询盘访客明细。用于查找 Accio 可用工具及用途、生成可提交的公开工具目录快照、按名称或说明筛选工具、调用用户指定工具、验证本地缓存与凭据，或在 Accio Token 更新后同步技能凭据；不依赖 localhost:4097，Accio 关闭后仍可在 Token 有效期内使用。
---

# Accio Alibaba Data Advisor

先定位本 `SKILL.md` 所在目录并记为 `SKILL_DIR`。所有操作只调用：

```powershell
& "<SKILL_DIR>\scripts\accio_data_advisor.ps1" -Action <action> ...
```

## 安全边界

- 凭据只保存在 `state/credentials.dpapi`，由 Windows CurrentUser DPAPI 加密，不能复制到其他用户或电脑使用。
- 最新 `tools/list` 运行缓存保存在 `state/tools_catalog.json`；该目录被 Git 忽略。
- 可提交的公开快照保存在 `references/tools_catalog.snapshot.json`。快照保留工具名称、说明和参数结构，仅清理真实的敏感默认值、示例值或凭据值。
- 不读取、打印、转述或上传 Token、Refresh Token、Cookie、Authorization、`connectId` 或 `sessionKey`。
- 不把 `state/` 放入 `.skill` 包、Git、云任务、日志或交付物。重新打包前必须临时移走 `state/`，打包后恢复。
- 通用 `call-tool` 只调用用户明确指定的工具。调用前先从缓存读取其 `description`、`inputSchema` 和 `annotations`；涉及写入、发送、删除、权限或其他重要外部动作时，按该动作本身的风险要求取得确认。
- 任一凭据解密、远程认证、工具目录或响应门禁失败时立即停止，不得把失败当作空数据。

## 固定流程

1. 运行 `status`。
2. 若凭据不存在、已过期或不足 5 分钟到期，请用户打开并登录 Accio，然后运行 `update-token`。
3. 若工具缓存不存在，或用户明确要求刷新目录，运行一次 `refresh-tools`。`update-token` 已同步刷新缓存，不要紧接着重复刷新。
4. 运行 `self-test`，要求凭据可用、完整缓存可读且数量一致；该动作不重复请求远程 `tools/list`。
5. 用 `list-tools` 从缓存列出或检索工具；每项保留用途说明和输入结构。
6. 用户要公开或提交工具目录时运行 `export-tools`，从缓存生成稳定快照；该动作不访问远程。
7. 根据请求运行便捷动作 `shop-summary` / `visitor-detail`，或用 `call-tool` 调用缓存目录中的指定工具。
8. 最终只汇报工具、查询范围、分页、返回记录或指标；不要汇报凭据内容。

## 凭据操作

查看状态：

```powershell
& "<SKILL_DIR>\scripts\accio_data_advisor.ps1" -Action status
```

用户打开并登录 Accio 后更新 Token：

```powershell
& "<SKILL_DIR>\scripts\accio_data_advisor.ps1" -Action update-token
```

验证远程连接与工具目录：

```powershell
& "<SKILL_DIR>\scripts\accio_data_advisor.ps1" -Action refresh-tools
```

验证本地凭据与缓存：

```powershell
& "<SKILL_DIR>\scripts\accio_data_advisor.ps1" -Action self-test
```

导出可提交的公开工具目录快照：

```powershell
& "<SKILL_DIR>\scripts\accio_data_advisor.ps1" -Action export-tools
```

列出缓存中的完整工具目录：

```powershell
& "<SKILL_DIR>\scripts\accio_data_advisor.ps1" -Action list-tools
```

按工具名或用途说明检索：

```powershell
& "<SKILL_DIR>\scripts\accio_data_advisor.ps1" `
  -Action list-tools `
  -ToolSearch "inquiry"
```

调用缓存目录中的指定工具：

```powershell
& "<SKILL_DIR>\scripts\accio_data_advisor.ps1" `
  -Action call-tool `
  -ToolName "data_advisor_account_summary" `
  -ArgumentsJson '{"accountQueryParam":{"startDate":"2026-07-01","endDate":"2026-07-23","statisticsType":"day"}}'
```

## 查询

店铺经营汇总：

```powershell
& "<SKILL_DIR>\scripts\accio_data_advisor.ps1" `
  -Action shop-summary `
  -StartDate 2026-07-01 `
  -EndDate 2026-07-23 `
  -StatisticsType day
```

调用 `data_advisor_shop_summary`，请求结构为：

```json
{"advisorQueryParam":{"startDate":"YYYY-MM-DD","endDate":"YYYY-MM-DD","statisticsType":"day"}}
```

询盘访客明细：

```powershell
& "<SKILL_DIR>\scripts\accio_data_advisor.ps1" `
  -Action visitor-detail `
  -StartDate 2026-07-23 `
  -EndDate 2026-07-23 `
  -IsMcFb true `
  -PageNo 1 `
  -PageSize 20
```

调用 `data_advisor_visitor_detail`，请求结构为：

```json
{"visitorQueryParam":{"startDate":"YYYY-MM-DD","endDate":"YYYY-MM-DD","isMcFb":true,"pageNO":1,"pageSize":20}}
```

`isMcFb=true` 只查询产生询盘的访客。分页时严格递增 `PageNo`，保留相同日期范围、`IsMcFb` 和 `PageSize`；遇到空页或上游明确结束标记后停止。
