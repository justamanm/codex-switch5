# 原生 Mac 界面调整实施计划

目标：落实已确认的设计，保留全部业务功能。分支：`codex/friendly-mac-ui`。

约束：只调整 SwiftUI 展示和中英文文案；不改账号服务、推荐、排序和统计算法；不改图标；不生成 DMG。直接在本任务执行，不使用 Superpowers。

## 1. 账号页和基础样式

- [x] 新增 `AppStyle.swift`，统一深浅色背景、蓝色操作与边线。
- [x] `ContentView.swift` 取消全局强制大字和大控件，入口仍为 `DashboardView()`。
- [x] `DashboardView.swift` 将账号记录变为上下两层；保留现有 `refreshAction`、`switchAction`、`aliasAction`、`removeAction`、`reauthenticateAction` 和拖动回调。
- [x] 顶部摘要以当前和推荐账号分列，主按钮靠近目标。分组开关与管理合并到菜单，换组保留在账号菜单。
- [x] 失效账号使用 `account.authInvalid` 标记历史值，不能修改其额度或切换规则。

## 2. 统计、记录与反馈

- [x] 统计总量优先，所有分项和四位金额保持可见或可展开。账号周期明细适应窄窗口。
- [x] `UsageLearningView.swift` 将图表提前、说明折叠；日期范围、数据限制和全部观察值保留。
- [x] 切换记录按 `Calendar.current.startOfDay(for: record.timestamp)` 分组；日期、秒级时间、失败原因完整保留。
- [x] 设置、登录和错误提示统一字号与间距；维持原确认和取消回调。
- [x] `Localization.swift` 补齐新增中文键的英文翻译。

## 3. 验证与交付

- [x] 运行 `scripts/build-app.sh`，编译并替换 `dist/Codex Switch5.app`（脚本保留旧包备份）。
- [x] 只启动此包检查账号、统计、记录及菜单；不执行真实账号切换、移除或登录。
- [x] 实测约 1006 像素窗口的中英文显示，设置已恢复中文。窄窗口拖动检查因 UI 工具返回 noWindowsAvailable 未完成；深色、760/1440 宽度及全键盘操作未实测。
- [x] 检查 `git diff --check`、新增翻译重复键和业务代码未改动；报告实际增删行数及未测项。
- [x] 本地提交源码与设计文档，不推送远端。

## 验证结果

- 最终 release 构建和应用签名成功，已重启 `dist/Codex Switch5.app`。未生成 DMG。
- 实际查看账号、统计摘要、账号周期明细、使用习惯、日期分组记录；确认 Token 明细可展开，账号更多菜单保留别名、换组、身份和移除。
- 英文检查发现并修正今日翻译缺失、设置行拥挤；重新打包并查看英文设置后恢复中文。
- `git diff --check` 通过，翻译字典无重复键；Core 与 AppModel 无改动。
- 未进行真实切换、登录、移除或更换分组；不宣称这些业务流程经过本轮端到端测试。
- 深色和最小窗口的视觉验收仍需补查，当前完成的是代码实现与上述范围内的实机检查。
