---
name: accio-alibaba-data-advisor
description: 通过 Accio 已授权账号的远程 MCP 查询 Alibaba.com Data Advisor，并在 Accio 定期打开后安全更新本地加密 Token。用于查询店铺经营汇总、询盘访客明细、检查 Data Advisor 工具目录、验证远程访问状态，或在 Accio Token 更新后同步技能凭据；不依赖 localhost:4097，Accio 关闭后仍可在 Token 有效期内查询。
---

# Accio Alibaba Data Advisor

先定位本 `SKILL.md` 所在目录并记为 `SKILL_DIR`。所有操作只调用：

```powershell
& "<SKILL_DIR>\scripts\accio_data_advisor.ps1" -Action <action> ...
```

## 安全边界

- 凭据只保存在 `state/credentials.dpapi`，由 Windows CurrentUser DPAPI 加密，不能复制到其他用户或电脑使用。
- 不读取、打印、转述或上传 Token、Refresh Token、Cookie、Authorization、`connectId` 或 `sessionKey`。
- 不把 `state/` 放入 `.skill` 包、Git、云任务、日志或交付物。重新打包前必须临时移走 `state/`，打包后恢复。
- 仅调用本脚本内置的只读 Data Advisor 操作；不要改成任意 MCP 工具调用器。
- 任一凭据解密、远程认证、工具目录或响应门禁失败时立即停止，不得把失败当作空数据。

## 固定流程

1. 运行 `status`。
2. 若凭据不存在、已过期或不足 5 分钟到期，请用户打开并登录 Accio，然后运行 `update-token`。
3. 运行 `self-test`，要求远程 HTTP 成功且两个目标工具均存在。
4. 根据请求运行 `shop-summary` 或 `visitor-detail`。
5. 最终只汇报查询范围、分页、返回记录或指标；不要汇报凭据内容。

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
& "<SKILL_DIR>\scripts\accio_data_advisor.ps1" -Action self-test
```

列出 Data Advisor 工具元数据：

```powershell
& "<SKILL_DIR>\scripts\accio_data_advisor.ps1" -Action list-tools
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
