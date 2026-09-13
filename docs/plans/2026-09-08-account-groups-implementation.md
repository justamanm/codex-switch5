# 账号手动分组实现计划

> **执行要求：** 按任务逐项实现和验证，不改动账号凭据内容，不覆盖当前未提交的界面调整。

**目标：** 修正“失效”标记位置，并实现可持久保存、批量管理、添加时选择和按组展示的账号分组功能。

**实现方式：** 在核心模块新增独立的 JSON 分组存储，`AppModel` 负责把存储操作转换成界面状态，`DashboardView` 只负责分组管理和展示。分组文件保存在 `~/.codex/codex_switcher_account_groups.json`，与账号凭据完全分离。

**技术：** Swift 6、SwiftUI、Foundation、XCTest、Swift Package Manager。

## 全局限制

- 每个账号最多属于一个分组，也允许不分组。
- 删除分组只解除关系，不删除账号。
- 添加账号取消或失败时不保存分组关系。
- 分组功能不改变 Token 统计页排序。
- 每次修改后构建并重启 `dist/Codex Switcher.app`，使用非全屏窗口验证。

---

### 任务一：实现独立分组存储

**文件：**

- 新建：`Sources/CodexSwitcherCore/AccountGroupStore.swift`
- 修改：`Tests/CodexSwitcherCoreTests/CodexSwitcherCoreTests.swift`
- 修改：`Sources/CodexSwitcherCoreChecks/main.swift`

**接口：**

- `AccountGroup: Codable, Identifiable, Equatable, Sendable`，字段为 `id: UUID`、`name: String`。
- `AccountGroupState: Codable, Equatable, Sendable`，字段为 `groups: [AccountGroup]`、`accountGroupIDs: [String: UUID]`。
- `AccountGroupStore.load(validAccounts:) throws -> AccountGroupState`。
- `AccountGroupStore.save(_:) throws`，使用临时文件后原子替换。
- 状态方法：创建、改名、删除分组和批量移动账号；统一校验空名称与重名。

- [ ] 编写测试：空文件得到空状态；保存再读取保持一致；重复名称和空名称失败；批量移动后一个账号只有一个分组；删除分组后账号关系消失；无效账号关系读取后被清理。
- [ ] 运行 `swift test --filter CodexSwitcherCoreTests`，确认新增测试先失败。
- [ ] 实现上述数据类型、校验和原子保存。
- [ ] 在核心检查程序增加相同的关键断言。
- [ ] 运行 `swift test` 和 `swift run CodexSwitcherCoreChecks`，确认全部通过。

### 任务二：接入应用状态和添加账号流程

**文件：**

- 修改：`Sources/CodexSwitcher/AppModel.swift`
- 修改：`Sources/CodexSwitcher/Localization.swift`

**接口：**

- 发布状态：`accountGroups`、`accountGroupIDs`、`pendingAddAccountGroupID`、`accountGroupError`。
- 操作：`createAccountGroup(name:)`、`renameAccountGroup(id:name:)`、`deleteAccountGroup(id:)`、`assignAccounts(_:to:)`、`groupID(for:)`。
- 新增账号准备时把待选分组重置为未分组；仅在新账号成功写入后保存选择结果。

- [ ] 在 `start()` 中读取分组文件，并用当前账号列表清理失效关系。
- [ ] 实现创建、改名、删除和批量移动；保存失败时恢复旧状态并显示错误。
- [ ] 删除账号成功后移除该账号的分组关系。
- [ ] 把新增账号成功分支接入待选分组；重新登录不改变原有分组。
- [ ] 为新增界面文字补充中英文翻译。
- [ ] 运行 `swift build`，确认状态接口和现有功能可编译。

### 任务三：修正“失效”位置并增加分组管理界面

**文件：**

- 修改：`Sources/CodexSwitcher/DashboardView.swift`

**界面行为：**

- 账号名称和“失效”使用同一横排，名称设置 `lineLimit(1)`、`truncationMode(.tail)` 和较低布局优先级；徽标固定尺寸，确保始终显示在名称右侧。
- “所有账号”标题行增加“按分组显示”切换与“管理分组”按钮。
- 管理窗口左侧管理分组名称，右侧勾选账号；保存时一次性批量移动。
- 删除分组前显示确认框，说明账号会进入未分组。

- [ ] 调整宽屏和窄屏账号身份区域，使“失效”紧邻账号名且不会被挤到操作区。
- [ ] 增加创建分组、改名和删除界面，错误显示在操作位置附近。
- [ ] 增加账号多选列表和批量加入按钮；已属于目标分组的账号默认勾选。
- [ ] 处理空名称、重名、未选择分组和未选择账号时的禁用状态。
- [ ] 构建应用，检查管理窗口在最小宽度下无截断。

### 任务四：添加账号时选择分组并按组展示

**文件：**

- 修改：`Sources/CodexSwitcher/DashboardView.swift`

**界面行为：**

- 非重新登录的添加账号窗口显示分组选择框，第一项为“未分组”。
- 平铺模式保持当前列表。
- 按组模式按分组创建顺序显示标题和账号；未分组区放在最后，空分组不显示账号区。
- 按组模式拖动只改变同组顺序，不能跨组；跨组操作进入管理窗口完成。

- [ ] 在添加账号窗口接入 `pendingAddAccountGroupID`，等待登录期间仍显示所选分组但不能修改。
- [ ] 增加本地保存的“按分组显示”开关。
- [ ] 将账号列表数据整理为分组段落，同时复用现有账号卡片组件。
- [ ] 限制按组拖动范围；平铺模式保持当前拖动行为。
- [ ] 在最小宽度和普通非全屏宽度检查标题、按钮、分组标题和账号卡片边距一致。

### 任务五：完整验证和交付

**文件：**

- 修改（仅在发现问题时）：上述实现文件。

- [ ] 运行 `swift test`、`swift run CodexSwitcherCoreChecks` 和 `git diff --check`。
- [ ] 运行 `./scripts/build-app.sh`，确认生成 `dist/Codex Switcher.app`。
- [ ] 退出旧进程并启动新应用。
- [ ] 实际验证：创建两个分组、拦截重名、改名、批量加入、从旧组移动、删除组后进入未分组。
- [ ] 验证添加账号窗口允许选择分组和未分组；不执行真实登录以避免修改用户账号，成功保存路径由核心测试覆盖。
- [ ] 切换平铺和按组显示，验证同组连续、未分组最后、当前账号高亮和“失效”位置。
- [ ] 在最小宽度及普通非全屏宽度分别检查账号页；再检查 Token 和切换记录页面未受影响。
- [ ] 汇报新增与删除行数、测试结果、未验证边界和未提交文件。
