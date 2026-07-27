# Accio Alibaba Data Advisor

让 Codex 使用已登录的 Accio 账号：

- 获取、搜索并调用完整的 Accio MCP 工具
- 查询 Alibaba.com Data Advisor 店铺经营汇总和询盘访客明细
- 将工具目录保存到本地，避免每次重新请求 `tools/list`

完整工具目录见 [tools_catalog.json](references/tools_catalog.json)。

## 安装

需要 Windows、PowerShell 7、Codex，以及已安装并登录的 Accio。

```powershell
git clone https://github.com/MeGustas-5427/accio-alibaba-data-advisor.git `
  "$env:USERPROFILE\.codex\skills\accio-alibaba-data-advisor"
```

## 首次使用

打开 Accio 并登录，然后运行：

```powershell
cd "$env:USERPROFILE\.codex\skills\accio-alibaba-data-advisor"
& ".\scripts\accio_data_advisor.ps1" -Action update-token
```

之后可以在 Codex 中直接提出：

```text
使用 accio-alibaba-data-advisor 查找与 inquiry 相关的工具。
使用 accio-alibaba-data-advisor 调用 data_advisor_category_infer。
使用 accio-alibaba-data-advisor 查询 2026-07-01 到 2026-07-23 的店铺经营汇总。
```

需要重新同步工具目录时运行：

```powershell
& ".\scripts\accio_data_advisor.ps1" -Action refresh-tools
```

仅用于你有权访问的账号。认证信息使用 Windows CurrentUser DPAPI 加密，不会提交到 Git。

## License

本仓库原创的 `SKILL.md`、`README.md`、`scripts/` 和 `assets/` 采用 [MIT License](LICENSE)。

`references/tools_catalog.json` 由 Accio 远程服务生成，可能包含第三方工具说明和参数结构，不属于本项目的 MIT 再授权范围，适用其原始提供方的条款。

本项目是非官方项目，与 Alibaba.com 或 Accio 无隶属、赞助或背书关系。相关名称和商标归各自权利人所有。

## QQ 交流群

`1094787834`
