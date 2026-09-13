import AppKit
import Charts
import CodexSwitcherCore
import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showingSettings = false
    @State private var showingGroupManager = false
    @State private var showingSortManager = false
    @State private var accountsWidth: CGFloat = 0
    @State private var selectedSection = DashboardSection.accounts
    @State private var switchHistoryCategory = SwitchHistoryCategory.account
    @State private var selectedHistoryPoint: String?
    @State private var tokenHistoryInterval = TokenHistoryInterval.day
    @State private var tokenUsageDisplay = TokenUsageDisplay.summary
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var sectionPickerAnimation
    @State private var draggedAccountName: String?
    @State private var dragOrderNames: [String]?
    @State private var dragOffset: CGSize = .zero
    @State private var dragStartFrame: CGRect?
    @State private var accountRowFrames: [String: CGRect] = [:]
    @AppStorage("tokenUsageSortPeriod") private var tokenUsageSortPeriod = TokenUsageSortPeriod.fiveHours.rawValue
    @AppStorage("accountManualOrder") private var accountManualOrder = ""
    @AppStorage("showsAccountGroups") private var showsAccountGroups = false
    @AppStorage("accountSortRules") private var accountSortRulesJSON = ""
    private let accent = AppStyle.accent
    private let compactLayoutBreakpoint: CGFloat = 880
    private let pageHorizontalPadding: CGFloat = 24

    private enum DashboardSection: String, CaseIterable {
        case accounts
        case tokenUsage
        case switchHistory
    }

    private enum SwitchHistoryCategory: String, CaseIterable, Hashable {
        case account
        case group

        var title: String {
            switch self {
            case .account: "账号切换"
            case .group: "分组切换"
            }
        }
    }

    private enum TokenUsageSortPeriod: String, CaseIterable {
        case fiveHours
        case weeklyQuotaCycle
        case today
        case currentWeek
        case currentMonth

        var usagePeriod: TokenUsagePeriod {
            switch self {
            case .fiveHours: .fiveHours
            case .weeklyQuotaCycle: .weeklyQuotaCycle
            case .today: .today
            case .currentWeek: .currentWeek
            case .currentMonth: .currentMonth
            }
        }

        var title: String {
            switch self {
            case .fiveHours: "5h额度周期"
            case .weeklyQuotaCycle: "周额度周期"
            case .today: "今天"
            case .currentWeek: "本周"
            case .currentMonth: "本月"
            }
        }
    }

    private enum TokenHistoryInterval: String, CaseIterable, Hashable {
        case day
        case week
        case month

        var title: String {
            switch self {
            case .day: "每日"
            case .week: "每周"
            case .month: "每月"
            }
        }

        var calendarComponent: Calendar.Component {
            switch self {
            case .day: .day
            case .week: .weekOfYear
            case .month: .month
            }
        }

        var bucketCount: Int {
            switch self {
            case .day: 14
            case .week, .month: 12
            }
        }
    }

    private enum TokenUsageDisplay: String, CaseIterable, Hashable {
        case summary
        case accounts
        case learning

        var title: String {
            switch self {
            case .summary: "统计信息"
            case .accounts: "账号明细"
            case .learning: "使用习惯"
            }
        }
    }

    private struct TokenHistoryPoint: Identifiable {
        let start: Date
        let label: String
        let totals: TokenUsageTotals
        var id: Date { start }
    }

    var body: some View {
        GeometryReader { proxy in
            dashboardContent
                .frame(width: proxy.size.width, height: proxy.size.height)
                .onAppear { accountsWidth = proxy.size.width }
                .onChange(of: proxy.size.width) { _, width in accountsWidth = width }
        }
        .frame(minWidth: 760, minHeight: 620)
        .background(AppStyle.background)
        .tint(accent)
        .task { model.start() }
    }

    private var dashboardContent: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                pageHeader
                if selectedSection == .accounts {
                    accountOverview
                }
                if let error = model.lastError { errorCard(error) }
            }
            .padding(.horizontal, pageHorizontalPadding)
            .padding(.top, 18)
            .padding(.bottom, 14)

            Divider()

            Group {
                switch selectedSection {
                case .accounts:
                    ScrollView {
                        accountsSection
                            .padding(.horizontal, pageHorizontalPadding)
                            .padding(.top, 16)
                            .padding(.bottom, 36)
                    }
                case .tokenUsage:
                    tokenUsageSection
                case .switchHistory:
                    switchHistorySection
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(AppStyle.background)
        .tint(accent)
        .overlay(alignment: .top) {
            if let notice = model.notice {
                Text(notice)
                    .font(.system(size: 15))
                    .padding(.horizontal, 18).padding(.vertical, 12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .shadow(radius: 6)
                    .padding(.top, 12)
                    .allowsHitTesting(false)
            }
        }
        .sheet(isPresented: $model.showingSwitchConfirmation, onDismiss: { model.pendingSwitchAccount = nil }) {
            switchAccountSheet
        }
        .alert(
            model.text("移除账号"),
            isPresented: Binding(
                get: { model.removingAccount != nil },
                set: { if !$0 { model.removingAccount = nil } }
            )
        ) {
            Button(model.text("移到废纸篓"), role: .destructive) { model.confirmRemove() }
            Button(model.text("取消"), role: .cancel) { model.removingAccount = nil }
        } message: {
            Text(model.text("账号凭据将移到废纸篓，可以恢复；不会永久删除。"))
        }
        .sheet(isPresented: $model.showingAddAccount, onDismiss: model.addAccountSheetDidDismiss) {
            addAccountSheet.interactiveDismissDisabled(model.isAddingAccount)
        }
        .sheet(isPresented: $showingSettings) { settingsSheet }
        .sheet(isPresented: $showingGroupManager) { AccountGroupManagerSheet() }
        .sheet(isPresented: $showingSortManager) { AccountSortManagerSheet(rules: accountSortRulesBinding) }
        .sheet(
            isPresented: Binding(
                get: { model.editingAccount != nil },
                set: { if !$0 { model.editingAccount = nil } }
            )
        ) { aliasSheet }
    }

    private var pageHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 20) {
                headerIdentity
                Spacer(minLength: 12)
                sectionPicker
                Spacer(minLength: 12)
                headerActions
            }
            VStack(spacing: 14) {
                HStack {
                    headerIdentity
                    Spacer()
                    headerActions
                }
                sectionPicker
            }
        }
    }

    private var headerIdentity: some View {
        HStack(spacing: 10) {
            Button { showingSettings = true } label: {
                Image(systemName: "gearshape")
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(model.text("打开设置"))
            .accessibilityLabel(model.text("打开设置"))
            Text("Switch5").font(.system(size: 15, weight: .semibold))
        }
        .fixedSize()
    }

    private var headerActions: some View {
        HStack(spacing: 8) {
            Button { model.refresh() } label: {
                Label(model.text(model.isRefreshing ? "正在刷新" : "刷新"), systemImage: "arrow.clockwise")
            }
            .disabled(model.isRefreshing || model.isSwitching)
            Button { model.prepareAddAccount() } label: {
                Label(model.text("增加账号"), systemImage: "plus")
            }
            .disabled(model.isSwitching)
        }
        .controlSize(.regular)
        .fixedSize()
    }

    private var sectionPicker: some View {
        HStack(spacing: 0) {
            sectionPickerButton(.accounts, title: model.text("账号"))
            sectionPickerButton(.tokenUsage, title: model.text("用量统计"))
            sectionPickerButton(.switchHistory, title: model.text("切换记录"))
        }
        .padding(3)
        .frame(width: sectionPickerWidth, height: 36)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.04))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.14), lineWidth: 1)
                }
        }
    }

    private func sectionPickerButton(_ section: DashboardSection, title: String) -> some View {
        Button {
            guard section != selectedSection else { return }
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) {
                selectedSection = section
            }
            if section == .tokenUsage {
                model.refreshTokenUsage()
            }
        } label: {
            ZStack {
                if selectedSection == section {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(AppStyle.surface)
                        .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
                        .matchedGeometryEffect(id: "section-selection", in: sectionPickerAnimation)
                }
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(selectedSection == section ? Color.primary : Color.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityAddTraits(selectedSection == section ? .isSelected : [])
    }

    private var sectionPickerWidth: CGFloat {
        model.appLanguage.resolved() == .english ? 360 : 280
    }

    private var accountOverview: some View {
        HStack(alignment: .top, spacing: 24) {
            overviewAccount(
                title: model.text("正在使用"),
                name: model.currentName.isEmpty ? model.text("未识别") : model.displayName(for: model.currentName),
                identityHelp: model.identityHelp(for: model.currentName),
                account: model.accounts.first { $0.name == model.currentName }
            )
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                if let account = model.recommendation {
                    overviewAccount(
                        title: model.text("推荐备用"),
                        name: model.displayName(for: account.name),
                        identityHelp: model.identityHelp(for: account.name),
                        account: account
                    )
                    Button { model.requestSwitch(to: account.name) } label: {
                        Label(model.text("切换到此账号"), systemImage: "arrow.left.arrow.right")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .disabled(model.isSwitching)
                } else {
                    Text(model.text("推荐备用")).foregroundStyle(.secondary)
                    Text(model.text("暂无可用账号")).font(.headline)
                    Text(model.text("请刷新额度后重试")).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 14)
    }

    private func overviewAccount(
        title: String,
        name: String,
        identityHelp: String,
        account: AccountUsage?
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
            HoverAccountName(name: name, identityHelp: identityHelp, font: .system(size: 21, weight: .semibold))
                .lineLimit(1)
            if let account {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 14) {
                        overviewQuota("5 小时剩余", value: account.fiveHourRemaining)
                        overviewQuota("周额度剩余", value: account.weeklyRemaining)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        overviewQuota("5 小时剩余", value: account.fiveHourRemaining)
                        overviewQuota("周额度剩余", value: account.weeklyRemaining)
                    }
                }
                if account.authInvalid {
                    Text(model.text("上次记录 · 需要重新登录")).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            } else {
                Text(model.text("暂无额度信息")).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func overviewQuota(_ title: String, value: Int) -> some View {
        HStack(spacing: 5) {
            Text(model.text(title)).foregroundStyle(.secondary)
            Text("\(value)%").monospacedDigit()
        }
        .font(.system(size: 13))
        .fixedSize()
    }

    private var accountsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center) {
                Text(model.text("所有账号")).font(.system(size: 16, weight: .semibold))
                Text(model.text("%d 个", model.accounts.count)).foregroundStyle(.secondary)
                Spacer()
                Button { showingSortManager = true } label: {
                    Label(accountSortRules.isEmpty ? model.text("排序") : model.text("排序 %d", accountSortRules.count), systemImage: "arrow.up.arrow.down")
                }
                Menu {
                    Toggle(model.text("按分组显示"), isOn: $showsAccountGroups)
                    Button(model.text("管理分组")) { showingGroupManager = true }
                } label: {
                    Label(model.text("分组"), systemImage: "folder")
                }
                .fixedSize()
            }
            if let latestUpdate {
                Text(model.text("额度更新于 %@", latestUpdate))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if model.accounts.isEmpty {
                ContentUnavailableView {
                    Label(model.text("暂无账号数据"), systemImage: "person.crop.circle.badge.plus")
                } description: {
                    Text(model.text("添加账号后，可在这里查看额度和切换账号。"))
                } actions: {
                    Button(model.text("增加账号")) { model.prepareAddAccount() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isSwitching)
                }
            }
            LazyVStack(spacing: 0) {
                if showsAccountGroups {
                    ForEach(groupedAccountSections, id: \.id) { section in
                        if !section.accounts.isEmpty {
                            HStack {
                                Text(section.name)
                                    .font(.system(size: 16, weight: .semibold))
                                Text(model.text("%d 个", section.accounts.count))
                                    .font(.system(size: 14)).foregroundStyle(.secondary)
                                Spacer()
                            }
                            .padding(.top, 12)
                            .padding(.bottom, 8)
                            accountRows(section.accounts)
                        }
                    }
                } else {
                    accountRows(sortedAccounts)
                }
            }
            .coordinateSpace(name: "account-list")
            .onPreferenceChange(AccountRowFramePreferenceKey.self) { accountRowFrames = $0 }
            .overlay(alignment: .topLeading) { draggingAccountOverlay }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: manuallyOrderedAccounts.map(\.name))
        }
    }

    @ViewBuilder
    private func accountRows(_ accounts: [AccountUsage]) -> some View {
        VStack(spacing: 0) {
        ForEach(accounts) { account in
                    AccountDashboardRow(
                        account: account,
                        displayName: model.displayName(for: account.name),
                        identityHelp: model.identityHelp(for: account.name),
                        isCurrent: model.currentType == "account" && model.currentName == account.name,
                        isRecommended: model.recommendation?.name == account.name,
                        usesCompactLayout: usesCompactLayout,
                        isRefreshing: model.refreshingAccounts.contains(account.name),
                        isSwitching: model.isSwitching,
                        refreshAction: { model.refresh(account: account.name) },
                        switchAction: { model.requestSwitch(to: account.name) },
                        aliasAction: { model.beginEditingAlias(account.name) },
                        removeAction: { model.requestRemove(account.name) },
                        reauthenticateAction: { model.prepareReauthentication(for: account.name) },
                        allowsDragging: accountSortRules.isEmpty,
                        isBeingDragged: draggedAccountName == account.name,
                        dragChanged: { updateAccountDrag(account.name, translation: $0) },
                        dragEnded: finishAccountDrag
                    )
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: AccountRowFramePreferenceKey.self,
                                value: [account.name: proxy.frame(in: .named("account-list"))]
                            )
                        }
                    }
        }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private struct AccountGroupSection: Identifiable {
        let id: String
        let name: String
        let accounts: [AccountUsage]
    }

    private var groupedAccountSections: [AccountGroupSection] {
        let ordered = sortedAccounts
        var sections = model.accountGroupState.groups.map { group in
            AccountGroupSection(
                id: group.id.uuidString,
                name: group.name,
                accounts: ordered.filter { model.groupID(for: $0.name) == group.id }
            )
        }
        sections.append(AccountGroupSection(
            id: "ungrouped",
            name: model.text("未分组"),
            accounts: ordered.filter { model.groupID(for: $0.name) == nil }
        ))
        return sections
    }

    private var manuallyOrderedAccounts: [AccountUsage] {
        let accounts = model.accounts
        let accountsByName = Dictionary(uniqueKeysWithValues: accounts.map { ($0.name, $0) })
        let storedNames = (try? JSONDecoder().decode([String].self, from: Data(accountManualOrder.utf8))) ?? []
        let names = storedNames.filter { accountsByName[$0] != nil }
            + accounts.map(\.name).filter { !storedNames.contains($0) }
        let order = dragOrderNames ?? names
        return order.compactMap { accountsByName[$0] }
    }

    private var sortedAccounts: [AccountUsage] {
        AccountSorter.sorted(manuallyOrderedAccounts, by: accountSortRules)
    }

    private var accountSortRules: [AccountSortRule] {
        (try? JSONDecoder().decode([AccountSortRule].self, from: Data(accountSortRulesJSON.utf8))) ?? []
    }

    private var accountSortRulesBinding: Binding<[AccountSortRule]> {
        Binding(get: { accountSortRules }, set: { rules in
            guard let data = try? JSONEncoder().encode(rules) else { return }
            accountSortRulesJSON = String(decoding: data, as: UTF8.self)
        })
    }

    private func updateAccountDrag(_ name: String, translation: CGSize) {
        guard accountSortRules.isEmpty else { return }
        guard let sourceFrame = accountRowFrames[name] else { return }
        if draggedAccountName == nil {
            draggedAccountName = name
            dragOrderNames = manuallyOrderedAccounts.map(\.name)
            dragStartFrame = sourceFrame
        }
        guard let dragStartFrame, draggedAccountName == name, var names = dragOrderNames else { return }
        dragOffset = translation
        names.removeAll { $0 == name }
        let centerY = dragStartFrame.midY + translation.height
        let insertionIndex = names.firstIndex { accountRowFrames[$0]?.midY ?? .greatestFiniteMagnitude > centerY } ?? names.count
        names.insert(name, at: insertionIndex)
        withAnimation(.easeInOut(duration: 0.14)) {
            dragOrderNames = names
        }
    }

    private func finishAccountDrag() {
        guard let names = dragOrderNames else { return }
        guard let data = try? JSONEncoder().encode(names), let value = String(data: data, encoding: .utf8) else { return }
        accountManualOrder = value
        draggedAccountName = nil
        dragOrderNames = nil
        dragOffset = .zero
        dragStartFrame = nil
    }

    @ViewBuilder
    private var draggingAccountOverlay: some View {
        if let
            name = draggedAccountName,
            let account = manuallyOrderedAccounts.first(where: { $0.name == name }),
            let frame = dragStartFrame
        {
            AccountDashboardRow(
                account: account,
                displayName: model.displayName(for: account.name),
                identityHelp: model.identityHelp(for: account.name),
                isCurrent: model.currentType == "account" && model.currentName == account.name,
                isRecommended: model.recommendation?.name == account.name,
                usesCompactLayout: usesCompactLayout,
                isRefreshing: model.refreshingAccounts.contains(account.name),
                isSwitching: model.isSwitching,
                refreshAction: {}, switchAction: {}, aliasAction: {}, removeAction: {}, reauthenticateAction: {},
                allowsDragging: false,
                isBeingDragged: false,
                dragChanged: { _ in }, dragEnded: {}
            )
            .frame(width: frame.width)
            .offset(x: frame.minX, y: frame.minY + dragOffset.height)
            .allowsHitTesting(false)
            .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
        }
    }

    private var usesCompactLayout: Bool {
        accountsWidth > 0 && accountsWidth < compactLayoutBreakpoint
    }

    private var latestUpdate: String? {
        let formatter = ISO8601DateFormatter()
        guard let date = model.accounts.compactMap({ formatter.date(from: $0.notedAt) }).max() else {
            return nil
        }
        return date.formatted(
            .dateTime
                .year().month(.abbreviated).day()
                .hour().minute()
                .locale(model.appLanguage.locale)
        )
    }

    private var settingsSheet: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Label(model.text("设置"), systemImage: "gearshape.fill").font(.title2.bold())
                Spacer()
                Button(model.text("完成")) { showingSettings = false }.keyboardShortcut(.defaultAction)
            }
            Divider()
            Label(model.text("语言"), systemImage: "globe").font(.headline)
            Picker(model.text("语言"), selection: $model.appLanguage) {
                Text(model.text("跟随系统")).tag(AppLanguage.system)
                Text("中文").tag(AppLanguage.chinese)
                Text("English").tag(AppLanguage.english)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Divider()
            Label(model.text("自动查询"), systemImage: "clock.arrow.circlepath").font(.headline)
            VStack(alignment: .leading, spacing: 14) {
                Toggle(model.text("启用自动刷新"), isOn: $model.automaticRefresh)
                    .toggleStyle(.switch)
                    .onChange(of: model.automaticRefresh) { _, _ in model.configureAutomaticRefresh() }
                HStack(spacing: 12) {
                Text(model.text("查询间隔")).foregroundStyle(.secondary)
                TextField(model.text("间隔"), value: $model.refreshIntervalValue, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 76)
                    .onChange(of: model.refreshIntervalValue) { _, value in
                        if value < 1 { model.refreshIntervalValue = 1 }
                        model.configureAutomaticRefresh()
                    }
                Picker(model.text("时间单位"), selection: $model.refreshIntervalUnit) {
                    Text(model.text("秒")).tag("seconds")
                    Text(model.text("分钟")).tag("minutes")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 120)
                .onChange(of: model.refreshIntervalUnit) { _, _ in model.configureAutomaticRefresh() }
                }
            }
            Text(model.text("自动查询默认每 1 分钟执行；可自定义秒或分钟。全量查询时账号之间间隔 1 秒，单账号查询立即执行。"))
                .font(.system(size: 14)).foregroundStyle(.secondary)
            Divider()
            HStack {
                Text(model.text("版本"))
                Spacer()
                Text(AppVersion.display)
            }
            .font(.system(size: 14))
            .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 520)
    }

    private func errorCard(_ error: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 8) {
                Text(error.components(separatedBy: .newlines).first ?? error)
                    .font(.system(size: 14)).fixedSize(horizontal: false, vertical: true)
                if error.contains("\n") {
                    DisclosureGroup(model.text("查看详细信息")) {
                        ScrollView { Text(error).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                            .frame(maxHeight: 160)
                    }
                    .font(.system(size: 12))
                }
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(AppStyle.surface, in: RoundedRectangle(cornerRadius: 10))
    }

    private var tokenUsageSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 16) {
                    Picker(model.text("用量统计"), selection: $tokenUsageDisplay) {
                        ForEach(TokenUsageDisplay.allCases, id: \.self) { display in
                            Text(model.text(display.title)).tag(display)
                        }
                    }
                    .labelsHidden().pickerStyle(.segmented)
                    .frame(width: model.appLanguage.resolved() == .english ? 330 : 270)
                    Spacer()
                    if tokenUsageDisplay == .accounts {
                        Picker(model.text("账号排序"), selection: $tokenUsageSortPeriod) {
                            ForEach(TokenUsageSortPeriod.allCases, id: \.rawValue) { option in
                                Text(model.text(option.title)).tag(option.rawValue)
                            }
                        }
                        .pickerStyle(.menu).frame(width: 230)
                    }
                }
                Text(model.text("仅统计启用此功能后的本机记录"))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, pageHorizontalPadding).padding(.vertical, 16)
            Divider()
            if tokenUsageDisplay == .learning {
                UsageLearningView()
            } else {
                ScrollView(.vertical) {
                    LazyVStack(spacing: 10) {
                        if tokenUsageDisplay == .summary {
                            tokenUsageSummary
                                .padding(.bottom, 2)
                            tokenUsageHistoryChart
                        } else {
                            ForEach(tokenUsageSortedAccounts) { account in
                                tokenUsageAccountRow(account)
                            }
                        }
                    }
                    .padding(.horizontal, pageHorizontalPadding)
                    .padding(.vertical, 16)
                }
            }
            if tokenUsageDisplay != .learning {
                Divider()
                HStack {
                    Text(model.text("Token 总计不包含 codex-auto-review，其用量单独标注。金额不包含 codex-auto-review；* 表示还有其他用量无法估算。"))
                        .font(.system(size: 14)).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, pageHorizontalPadding).padding(.vertical, 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var tokenUsageSummary: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                tokenUsageSummaryCard(periodTitle: "今日", totals: model.tokenTotals(period: .today))
                tokenUsageSummaryCard(periodTitle: "本周", totals: model.tokenTotals(period: .currentWeek))
                tokenUsageSummaryCard(periodTitle: "本月", totals: model.tokenTotals(period: .currentMonth))
            }
            VStack(spacing: 10) {
                tokenUsageSummaryCard(periodTitle: "今日", totals: model.tokenTotals(period: .today))
                tokenUsageSummaryCard(periodTitle: "本周", totals: model.tokenTotals(period: .currentWeek))
                tokenUsageSummaryCard(periodTitle: "本月", totals: model.tokenTotals(period: .currentMonth))
            }
        }
    }

    private var tokenUsageHistoryChart: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.text("历史 Token 用量"))
                        .font(.headline)
                    Text(model.text("柱形为 Token，用量金额标在柱形上方；仅统计本机已记录的数据"))
                        .font(.system(size: 14)).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("", selection: $tokenHistoryInterval) {
                    ForEach(TokenHistoryInterval.allCases, id: \.self) { interval in
                        Text(model.text(interval.title)).tag(interval)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 230)
            }

            ScrollView(.horizontal) {
                Chart(tokenHistoryPoints) { point in
                    BarMark(
                        x: .value(model.text("时间"), point.label),
                        y: .value(model.text("Token 用量"), point.totals.total)
                    )
                    .foregroundStyle(accent.opacity(0.8))
                    .cornerRadius(3)
                    .annotation(position: .top) {
                        if point.totals.total > 0 {
                            Text(chartPriceText(point.totals))
                                .font(.system(size: 13).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityLabel(point.label)
                    .accessibilityValue(model.text("%@ Token，金额 %@", compactTokens(point.totals.total), chartPriceText(point.totals)))
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let amount = value.as(Double.self) { Text(compactTokens(Int(amount.rounded()))) }
                        }
                    }
                }
                .chartYAxisLabel(model.text("Token 用量"))
                .chartXSelection(value: $selectedHistoryPoint)
                .chartYScale(domain: 0...tokenHistoryChartMaximum)
                .frame(minWidth: 1050, minHeight: 210)
            }
            .scrollIndicators(.visible)
            HStack {
                Picker(model.text("查看时段"), selection: $selectedHistoryPoint) {
                    Text(model.text("选择时段")).tag(String?.none)
                    ForEach(tokenHistoryPoints) { point in
                        Text(point.label).tag(Optional(point.label))
                    }
                }
                .frame(width: 230)
                if let point = tokenHistoryPoints.first(where: { $0.label == selectedHistoryPoint }) {
                    Text(model.text("%@ Token，金额 %@", compactTokens(point.totals.total), tablePriceText(point.totals)))
                        .textSelection(.enabled)
                }
            }
            .font(.system(size: 12))
            .onChange(of: tokenHistoryInterval) { _, _ in selectedHistoryPoint = nil }

        }
        .padding(14)
        .background(AppStyle.surface, in: RoundedRectangle(cornerRadius: 10))
    }

    private var tokenHistoryPoints: [TokenHistoryPoint] {
        let calendar = Calendar.current
        let component = tokenHistoryInterval.calendarComponent
        let now = Date()
        guard let currentStart = calendar.dateInterval(of: component, for: now)?.start else { return [] }
        let formatter = DateFormatter()
        formatter.locale = model.appLanguage.locale
        formatter.dateFormat = tokenHistoryInterval == .month ? "yyyy-MM" : "MM-dd"

        return (0..<tokenHistoryInterval.bucketCount).reversed().compactMap { offset in
            guard
                let start = calendar.date(byAdding: component, value: -offset, to: currentStart),
                let end = calendar.date(byAdding: component, value: 1, to: start)
            else { return nil }
            return TokenHistoryPoint(
                start: start,
                label: formatter.string(from: start),
                totals: model.tokenTotals(from: start, to: end)
            )
        }
    }

    private func tokenUsageSummaryCard(periodTitle: String, totals: TokenUsageTotals) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.text("%@总 Token", model.text(periodTitle)))
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Text(compactTokens(totals.total))
                .font(.system(size: 25, weight: .semibold)).monospacedDigit()
            VStack(alignment: .leading, spacing: 3) {
                Text(model.text("API 等值估算")).font(.system(size: 12))
                Text(tablePriceText(totals)).monospacedDigit().textSelection(.enabled)
            }
            .foregroundStyle(.secondary)
            Divider()
            DisclosureGroup(model.text("Token 明细")) {
            VStack(alignment: .leading, spacing: 6) {
                summaryMetric("输入", value: compactTokens(totals.input))
                summaryMetric("缓存", value: compactTokens(totals.cachedInput))
                summaryMetric("输出", value: compactTokens(totals.output))
                summaryMetric("推理", value: compactTokens(totals.reasoningOutput))
                if totals.autoReviewTokens > 0 {
                    summaryMetric("自动审查", value: compactTokens(totals.autoReviewTokens))
                    Text(model.text("（未计入 Token 总数）")).foregroundStyle(.secondary)
                }
                if totals.unpricedEvents > 0 {
                    Text(model.text("还有其他用量无法估算")).foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 12)).monospacedDigit()
            }
            .font(.system(size: 12))
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AppStyle.surface, in: RoundedRectangle(cornerRadius: 10))
    }

    private func summaryMetric(_ title: String, value: String) -> some View {
        HStack {
            Text(model.text(title)).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }

    private var tokenHistoryChartMaximum: Double {
        max(Double(tokenHistoryPoints.map(\.totals.total).max() ?? 0) * 1.18, 1)
    }

    private func chartPriceText(_ totals: TokenUsageTotals) -> String {
        totals.unpricedEvents > 0
            ? String(format: "$%.2f*", totals.estimatedUSD)
            : String(format: "$%.2f", totals.estimatedUSD)
    }

    private var tokenUsageSortedAccounts: [AccountUsage] {
        let selected = TokenUsageSortPeriod(rawValue: tokenUsageSortPeriod) ?? .fiveHours
        return model.rankedAccounts.enumerated().sorted { lhs, rhs in
            let left = model.tokenTotals(for: lhs.element.name, period: selected.usagePeriod).total
            let right = model.tokenTotals(for: rhs.element.name, period: selected.usagePeriod).total
            return left == right ? lhs.offset < rhs.offset : left > right
        }.map(\.element)
    }

    private func tokenUsageAccountRow(_ account: AccountUsage) -> some View {
        let isCurrent = model.currentType == "account" && model.currentName == account.name
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(model.displayName(for: account.name))
                    .font(.system(size: 18, weight: .semibold))
                    .lineLimit(1)
                if isCurrent {
                    Text(model.text("当前使用"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(accent)
                }
            }
            .foregroundStyle(.primary)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), alignment: .topLeading)], alignment: .leading, spacing: 22) {
                tokenUsagePeriod(
                    title: "5h额度周期",
                    subtitle: model.fiveHourPeriodText(for: account.name) ?? model.text("暂无精确重置时间"),
                    totals: model.tokenTotals(for: account.name, period: .fiveHours),
                    unavailable: model.fiveHourPeriodText(for: account.name) == nil
                )
                tokenUsagePeriod(
                    title: "周额度周期",
                    subtitle: model.weeklyQuotaPeriodText(for: account.name) ?? model.text("暂无精确重置时间"),
                    totals: model.tokenTotals(for: account.name, period: .weeklyQuotaCycle),
                    unavailable: model.weeklyQuotaPeriodText(for: account.name) == nil,
                    projection: model.weeklyQuotaProjections[account.name]
                )
                tokenUsagePeriod(title: "今天", totals: model.tokenTotals(for: account.name, period: .today))
                tokenUsagePeriod(title: "本周", totals: model.tokenTotals(for: account.name, period: .currentWeek))
                tokenUsagePeriod(title: "本月", totals: model.tokenTotals(for: account.name, period: .currentMonth))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(
                AppStyle.surface,
                in: RoundedRectangle(cornerRadius: 12)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(
                        AppStyle.separator.opacity(0.4),
                        lineWidth: 1
                    )
            }
        }
    }

    private func tokenUsagePeriod(
        title: String,
        subtitle: String? = nil,
        totals: TokenUsageTotals,
        unavailable: Bool = false,
        projection: WeeklyQuotaProjection? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) {
                    Text(model.text(title))
                        .font(.system(size: 15, weight: .semibold))
                        .fixedSize(horizontal: true, vertical: false)
                    Spacer()
                    if !unavailable {
                        Text(compactTokens(totals.total))
                            .font(.headline)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.text(title)).font(.system(size: 15, weight: .semibold))
                    if !unavailable {
                        Text(compactTokens(totals.total)).font(.headline)
                    }
                }
            }
            if let subtitle {
                Text(subtitle).foregroundStyle(.secondary).lineLimit(2)
            }
            if !unavailable {
                Text(model.text("输入 %@ · 缓存 %@", compactTokens(totals.input), compactTokens(totals.cachedInput)))
                Text(model.text("输出 %@ · 推理 %@", compactTokens(totals.output), compactTokens(totals.reasoningOutput)))
                if totals.autoReviewTokens > 0 {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.text("codex-auto-review %@", compactTokens(totals.autoReviewTokens)))
                        Text(model.text("（未计入 Token 总数）"))
                            .font(.system(size: 12))
                    }
                    .foregroundStyle(.secondary)
                }
                Text(model.text("API 等值估算 %@", tablePriceText(totals))).foregroundStyle(.secondary)
                if let projection {
                    Text(model.text(
                        projection.isPartial ? "预测 $%.2f* · %d%%用量" : "预测 $%.2f · %d%%用量",
                        projection.estimatedFullUSD,
                        projection.observedUsedPercent
                    ))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                } else if title == "周额度周期" {
                    Text(model.text("周额度预测：暂无数据"))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .font(.system(size: 14))
        .padding(.horizontal, 12)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tablePriceText(_ totals: TokenUsageTotals) -> String {
        if totals.unpricedEvents == 0 { return String(format: "$%.4f", totals.estimatedUSD) }
        if totals.estimatedUSD > 0 { return String(format: "$%.4f*", totals.estimatedUSD) }
        return model.text("暂无法估算")
    }

    private var switchHistorySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Text(model.text("切换记录")).font(.title3.bold())
                Picker("", selection: $switchHistoryCategory) {
                    ForEach(SwitchHistoryCategory.allCases, id: \.self) { category in
                        Text(model.text(category.title)).tag(category)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 230)
                Spacer()
                Text(model.text("仅保存在本机，最多保留 500 条"))
                    .font(.system(size: 14)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, pageHorizontalPadding).padding(.vertical, 16)
            Divider()
            if filteredSwitchHistory.isEmpty {
                ContentUnavailableView(
                    model.text(switchHistoryCategory == .account ? "暂无账号切换记录" : "暂无分组切换记录"),
                    systemImage: "clock.arrow.circlepath",
                    description: Text(model.text(
                        switchHistoryCategory == .account
                            ? "完成账号切换、添加或重新登录后会显示在这里。"
                            : "更换账号分组后会显示在这里。"
                    ))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(historyDays, id: \.self) { day in
                            Section {
                                VStack(spacing: 0) {
                                    ForEach(historyByDay[day] ?? []) { record in
                                        historyRow(record)
                                    }
                                }
                                .background(AppStyle.surface, in: RoundedRectangle(cornerRadius: 10))
                            } header: {
                                Text(day.formatted(.dateTime.year().month().day().locale(model.appLanguage.locale)))
                                    .font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(pageHorizontalPadding)
                }

            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var historyByDay: [Date: [SwitchHistoryRecord]] {
        Dictionary(grouping: filteredSwitchHistory) { Calendar.current.startOfDay(for: $0.timestamp) }
    }

    private var historyDays: [Date] { historyByDay.keys.sorted(by: >) }

    private func historyRow(_ record: SwitchHistoryRecord) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Text(record.timestamp.formatted(.dateTime.hour().minute().second().locale(model.appLanguage.locale)))
                .font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
            VStack(alignment: .leading, spacing: 7) {
                Text(historyTitle(record)).font(.system(size: 14, weight: .medium))
                    .textSelection(.enabled)
                if !record.message.isEmpty {
                    DisclosureGroup(model.text("查看详细信息")) {
                        Text(record.message).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.system(size: 12))
                }
            }
            Spacer(minLength: 8)
            Label(model.text(record.result == .success ? "成功" : "失败"),
                  systemImage: record.result == .success ? "checkmark" : "exclamationmark.circle")
                .font(.system(size: 12))
                .foregroundStyle(record.result == .success ? Color.secondary : Color.red)
                .fixedSize()
        }
        .padding(14)
        .overlay(alignment: .bottom) { Divider().padding(.horizontal, 14) }
    }

    private var filteredSwitchHistory: [SwitchHistoryRecord] {
        model.switchHistory.filter { record in
            switch switchHistoryCategory {
            case .account:
                record.resolvedAction != .changeGroup
            case .group:
                record.resolvedAction == .changeGroup
            }
        }
    }

    private func historyTitle(_ record: SwitchHistoryRecord) -> String {
        switch record.resolvedAction {
        case .switchAccount:
            return model.text("%@ → %@", historyAccountName(record.fromAccount), historyAccountName(record.toAccount))
        case .addAccount:
            if record.includesGroupAssignment == true {
                return model.text("新增账号：%@ · 加入 %@", historyAccountName(record.toAccount), historyGroupName(record.toGroup))
            }
            return model.text("新增账号：%@", historyAccountName(record.toAccount))
        case .reauthenticate:
            if record.includesGroupAssignment == true {
                return model.text("重新登录：%@ · 加入 %@", historyAccountName(record.toAccount), historyGroupName(record.toGroup))
            }
            return model.text("%@ → %@（重新登录）", historyAccountName(record.fromAccount), historyAccountName(record.toAccount))
        case .changeGroup:
            return model.text(
                "%@：%@ → %@",
                historyAccountName(record.toAccount),
                historyGroupName(record.fromGroup),
                historyGroupName(record.toGroup)
            )
        }
    }

    private func historyGroupName(_ group: String?) -> String {
        group ?? model.text("未分组")
    }

    private func historyAccountName(_ account: String) -> String {
        let alias = model.aliases[account]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !alias.isEmpty, alias != account else { return account }
        return "\(alias)（\(account)）"
    }

    private func compactTokens(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.2fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fK", Double(value) / 1_000) }
        return String(value)
    }

    private var switchAccountSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.2.circlepath.circle")
                    .font(.system(size: 24)).foregroundStyle(accent)
                Text(model.text("切换账号"))
                    .font(.title2.bold())
            }
            Text(model.text("切换前请确认以下事项。"))
                .foregroundStyle(.secondary)
            Label(model.text("将账号切换到 %@", model.pendingSwitchAccount.map { model.displayName(for: $0) } ?? ""), systemImage: "person.crop.circle.badge.checkmark")
                .font(.system(size: 15))
            HStack(alignment: .top, spacing: 12) {
                if model.isChatGPTInstalled {
                    switchInstructionCard(
                        title: "ChatGPT（自动操作）",
                        systemImage: "bubble.left.and.bubble.right.fill",
                        steps: [
                            ("确认后自动关闭", "power"),
                            ("切换完成后自动重新打开", "arrow.up.forward.app")
                        ]
                    )
                }
                if model.isCodexCLIInstalled {
                    switchInstructionCard(
                        title: "Codex CLI（需手动关闭和重启）",
                        systemImage: "terminal.fill",
                        steps: [
                            ("如果你正在终端中使用 codex，请先保存并退出；如果不使用终端版 Codex，可直接继续。", "terminal")
                        ]
                    )
                }
            }
            HStack {
                Spacer()
                Button(model.text("取消")) {
                    model.showingSwitchConfirmation = false
                    model.pendingSwitchAccount = nil
                }
                .keyboardShortcut(.cancelAction)
                Button(model.text("切换到 %@", model.pendingSwitchAccount ?? "")) { model.confirmSwitch() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(26)
        .frame(width: 620)
    }

    private func switchInstructionCard(
        title: String,
        systemImage: String,
        steps: [(String, String)]
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(model.text(title), systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(accent)
            Divider()
            ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                Label(model.text(step.0), systemImage: step.1)
                    .font(.system(size: 15))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private var addAccountSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: model.isWaitingForLogin ? "person.crop.circle.badge.clock" : "person.badge.plus")
                .font(.system(size: 26)).foregroundStyle(accent)
            Text(model.reauthenticatingAccount.map { model.text("重新登录 %@ 账号", model.displayName(for: $0)) }
                ?? model.text(model.isWaitingForLogin ? "等待新账号登录" : "增加 Codex 账号"))
                .font(.title2.bold())
            Text(model.text(model.isWaitingForLogin ? "第 2 步 · 完成登录" : "第 1 步 · 准备登录"))
                .font(.system(size: 12)).foregroundStyle(.secondary)
            if model.isWaitingForLogin {
                Text(model.addAccountStage).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ProgressView().controlSize(.large)
                Text(model.text(model.addAccountUsesChatGPT
                    ? "取消后会关闭 ChatGPT 应用并恢复原账号。"
                    : "取消后会恢复原账号。"))
                    .font(.system(size: 14)).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    if model.isCodexCLIInstalled {
                        Label(model.text("如果你正在终端中使用 codex，请先保存并退出；如果不使用终端版 Codex，可直接继续。"), systemImage: "terminal")
                    }
                    if model.isChatGPTInstalled {
                        Label(model.text("继续后会关闭 ChatGPT，保留当前登录账号，只需在 ChatGPT 完成登录即可"), systemImage: "arrow.down.doc")
                    } else {
                        Label(model.text("继续后会保存当前账号，并等待你运行 codex login"), systemImage: "arrow.down.doc")
                    }
                }
                .font(.system(size: 15))
                if model.showsReauthenticationGroupOptions {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                        GridRow {
                            Text(model.text(model.reauthenticatingAccount == nil ? "要加入的分组" : "要切换的分组"))
                                .frame(width: 110, alignment: .trailing)
                            Picker("", selection: $model.pendingAddAccountGroupID) {
                                ForEach(model.accountGroupState.groups) { group in
                                    Text(group.name).tag(Optional(group.id))
                                }
                                Text(model.text("未分组")).tag(UUID?.none)
                            }
                            .labelsHidden()
                            .frame(width: 320)
                        }
                        if model.pendingAddAccountGroupID != nil {
                            GridRow {
                                Text(model.text("替换组内账号"))
                                    .frame(width: 110, alignment: .trailing)
                                Picker("", selection: $model.pendingReauthenticationReplacementAccount) {
                                    Text(model.text("不替换，仅加入此分组")).tag(String?.none)
                                    ForEach(
                                        model.reauthenticationReplacementCandidates(
                                            for: model.pendingAddAccountGroupID,
                                            excluding: model.reauthenticatingAccount
                                        ),
                                        id: \.self
                                    ) { account in
                                        Text(model.displayName(for: account)).tag(Optional(account))
                                    }
                                }
                                .labelsHidden()
                                .frame(width: 320)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .onChange(of: model.pendingAddAccountGroupID) {
                        model.clearInvalidReauthenticationReplacement()
                    }
                    if model.pendingAddAccountGroupID != nil {
                        Text(model.text("替换只会将所选账号移出当前分组，不会删除账号或登录凭证。"))
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                } else {
                    HStack {
                        Spacer()
                        Button(model.text(model.reauthenticatingAccount == nil ? "加入分组" : "切换分组")) {
                            if model.reauthenticatingAccount == nil,
                               model.pendingAddAccountGroupID == nil {
                                model.pendingAddAccountGroupID = model.accountGroupState.groups.first?.id
                            }
                            model.showsReauthenticationGroupOptions = true
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button(model.text(model.isCancellingLogin ? "正在恢复…" : "取消")) { model.cancelLoginWatch() }
                    .disabled(model.isCancellingLogin)
                    .keyboardShortcut(.cancelAction)
                if !model.isAddingAccount {
                    Button(model.text(model.isChatGPTInstalled ? "退出 ChatGPT 并继续" : "保存当前账号并继续")) { model.startAddAccount() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(26).frame(width: 540)
    }

    private var aliasSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(model.text("设置账号别名")).font(.title2.bold())
            Text(model.text("界面只显示别名；鼠标停留在别名上仍可查看用户名和邮箱。"))
                .foregroundStyle(.secondary)
            TextField(model.text("别名"), text: $model.editingAlias)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button(model.text("取消")) { model.editingAccount = nil }
                Button(model.text("保存")) { model.saveAlias() }.buttonStyle(.borderedProminent)
            }
        }
        .padding(24).frame(width: 420)
    }
}

private struct AccountSortManagerSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Binding var rules: [AccountSortRule]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(model.text("组合排序")).font(.title2.bold())
                Spacer()
                Button(model.text("完成")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
            Text(model.text("从上到下依次比较；时间未知的账号始终排在最后。"))
                .font(.system(size: 15)).foregroundStyle(.secondary)
            if rules.isEmpty {
                ContentUnavailableView(model.text("使用手动排序"), systemImage: "arrow.up.arrow.down")
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                VStack(spacing: 8) {
                    ForEach(rules.indices, id: \.self) { index in
                        HStack(spacing: 10) {
                            Text("\(index + 1)").foregroundStyle(.secondary).frame(width: 18)
                            Picker("", selection: fieldBinding(index)) {
                                ForEach(availableFields(for: index), id: \.self) { field in
                                    Text(fieldTitle(field)).tag(field)
                                }
                            }
                            .labelsHidden().frame(width: 190)
                            Picker("", selection: directionBinding(index)) {
                                Text(model.text("升序")).tag(AccountSortDirection.ascending)
                                Text(model.text("降序")).tag(AccountSortDirection.descending)
                            }
                            .labelsHidden().frame(width: 100)
                            Button { move(index, by: -1) } label: { Image(systemName: "arrow.up") }
                                .disabled(index == 0)
                            Button { move(index, by: 1) } label: { Image(systemName: "arrow.down") }
                                .disabled(index == rules.count - 1)
                            Button(role: .destructive) { rules.remove(at: index) } label: { Image(systemName: "trash") }
                        }
                    }
                }
            }
            Divider()
            HStack {
                Button { addRule() } label: { Label(model.text("添加排序条件"), systemImage: "plus") }
                    .disabled(rules.count == AccountSortField.allCases.count)
                Spacer()
                Button(model.text("恢复手动排序"), role: .destructive) { rules.removeAll() }
                    .disabled(rules.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 560)
    }

    private func fieldBinding(_ index: Int) -> Binding<AccountSortField> {
        Binding(get: { rules[index].field }, set: { rules[index].field = $0 })
    }

    private func directionBinding(_ index: Int) -> Binding<AccountSortDirection> {
        Binding(get: { rules[index].direction }, set: { rules[index].direction = $0 })
    }

    private func availableFields(for index: Int) -> [AccountSortField] {
        let used = Set(rules.enumerated().filter { $0.offset != index }.map { $0.element.field })
        return AccountSortField.allCases.filter { !used.contains($0) }
    }

    private func addRule() {
        guard let field = AccountSortField.allCases.first(where: { candidate in !rules.contains { $0.field == candidate } }) else { return }
        rules.append(AccountSortRule(field: field))
    }

    private func move(_ index: Int, by offset: Int) {
        let destination = index + offset
        guard rules.indices.contains(destination) else { return }
        rules.swapAt(index, destination)
    }

    private func fieldTitle(_ field: AccountSortField) -> String {
        switch field {
        case .weeklyReset: model.text("周重置时间")
        case .weeklyQuota: model.text("周额度")
        case .fiveHourReset: model.text("5h重置时间")
        case .fiveHourQuota: model.text("5h额度")
        }
    }
}

private struct AccountGroupManagerSheet: View {
    private enum FocusedField: Hashable { case newGroupName, editedGroupName }

    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedField: FocusedField?
    @State private var newGroupName = ""
    @State private var selectedGroupID: UUID?
    @State private var editedGroupName = ""
    @State private var selectedAccounts: Set<String> = []
    @State private var groupToDelete: AccountGroup?
    @State private var batchResult: String?
    @State private var batchResultTask: Task<Void, Never>?
    private let accent = AppStyle.accent
    private let accountColumns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.text("管理分组"))
                        .font(.title2.bold())
                    Text(model.text("创建、重命名分组，并批量调整账号归属"))
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(model.text("完成")) { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .tint(accent)
            }
            .padding(.horizontal, 30)
            .padding(.vertical, 16)

            Divider()

            ScrollView {
                VStack(spacing: 14) {
                    groupCard(title: model.text("创建分组")) {
                        HStack(spacing: 10) {
                            TextField(model.text("新分组名称"), text: $newGroupName)
                                .textFieldStyle(.roundedBorder)
                                .focused($focusedField, equals: .newGroupName)
                            Button(model.text("创建分组")) {
                                if let id = model.createAccountGroup(name: newGroupName) {
                                    newGroupName = ""
                                    selectGroup(id)
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(accent)
                            .disabled(newGroupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }

                    groupCard(title: model.text("编辑分组")) {
                        VStack(spacing: 10) {
                            HStack(spacing: 10) {
                                Picker(model.text("目标分组"), selection: $selectedGroupID) {
                                    ForEach(model.accountGroupState.groups) { group in
                                        Text(group.name).tag(Optional(group.id))
                                    }
                                    Text(model.text("未分组")).tag(UUID?.none)
                                }
                                .frame(width: 180)
                                .onChange(of: selectedGroupID) { _, value in loadSelection(value) }

                                if let selectedGroupID,
                                   let group = model.accountGroupState.groups.first(where: { $0.id == selectedGroupID }) {
                                    TextField(model.text("分组名称"), text: $editedGroupName)
                                        .textFieldStyle(.roundedBorder)
                                        .focused($focusedField, equals: .editedGroupName)
                                    Button(model.text("更新名称")) {
                                        model.renameAccountGroup(id: selectedGroupID, name: editedGroupName)
                                    }
                                    Button(model.text("删除分组"), role: .destructive) { groupToDelete = group }
                                        .buttonStyle(.bordered)
                                        .tint(.red)
                                } else {
                                    Spacer()
                                    Text(model.text("未分组是默认分类，无需编辑"))
                                        .font(.system(size: 15))
                                        .foregroundStyle(.secondary)
                                }
                            }

                            if let error = model.accountGroupError {
                                Label(error, systemImage: "exclamationmark.circle.fill")
                                    .font(.system(size: 15))
                                    .foregroundStyle(.red)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(model.text("选择要移动到此分组的账号"))
                                .font(.headline)
                            Spacer()
                            Text(model.text("已选择 %d 个", selectedAccounts.count))
                                .font(.system(size: 15))
                                .foregroundStyle(.secondary)
                        }

                        LazyVGrid(columns: accountColumns, spacing: 10) {
                            ForEach(model.accounts) { account in
                                accountSelectionCard(account)
                            }
                        }
                    }
                    .padding(16)
                    .background(AppStyle.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(.secondary.opacity(0.16), lineWidth: 1)
                    }
                }
                .padding(.horizontal, 30)
                .padding(.vertical, 14)
            }

            Divider()
            HStack {
                Button(model.text("全选")) { selectedAccounts = Set(model.accounts.map(\.name)) }
                Button(model.text("清空")) { selectedAccounts.removeAll() }
                    .disabled(selectedAccounts.isEmpty)
                Spacer()
                if let batchResult {
                    Label(batchResult, systemImage: "checkmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.green)
                        .transition(.opacity)
                }
                Button(model.text("批量应用")) {
                    if model.replaceAccounts(in: selectedGroupID, with: selectedAccounts) {
                        showBatchResult(model.text("已应用到 %d 个账号", selectedAccounts.count))
                        loadSelection(selectedGroupID, clearsResult: false)
                    } else {
                        batchResult = nil
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(accent)
                .disabled(selectedAccounts.isEmpty)
            }
            .padding(.horizontal, 30)
            .padding(.vertical, 14)
            .background(.bar)
        }
        .frame(width: 640, height: 560)
        .onAppear {
            selectGroup(model.accountGroupState.groups.first?.id)
            Task { @MainActor in
                await Task.yield()
                focusedField = nil
            }
        }
        .onDisappear { batchResultTask?.cancel() }
        .alert(
            model.text("删除分组"),
            isPresented: Binding(get: { groupToDelete != nil }, set: { if !$0 { groupToDelete = nil } })
        ) {
            Button(model.text("删除"), role: .destructive) {
                guard let group = groupToDelete else { return }
                model.deleteAccountGroup(id: group.id)
                groupToDelete = nil
                selectGroup(model.accountGroupState.groups.first?.id)
            }
            Button(model.text("取消"), role: .cancel) { groupToDelete = nil }
        } message: {
            Text(model.text("删除分组后，组内账号将变为未分组，账号不会被删除。"))
        }
    }

    private func groupCard<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            content()
        }
        .padding(14)
        .background(AppStyle.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.secondary.opacity(0.14), lineWidth: 1)
        }
    }

    private func accountSelectionCard(_ account: AccountUsage) -> some View {
        let isSelected = selectedAccounts.contains(account.name)
        let assignedGroupName = model.accountGroupState.groups
            .first(where: { $0.id == model.groupID(for: account.name) })?.name ?? model.text("未分组")

        return Button {
            if isSelected { selectedAccounts.remove(account.name) }
            else { selectedAccounts.insert(account.name) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(isSelected ? accent : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.displayName(for: account.name))
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(assignedGroupName)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(height: 46)
            .background(isSelected ? accent.opacity(0.10) : AppStyle.background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isSelected ? accent.opacity(0.48) : .secondary.opacity(0.14), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    private func selectGroup(_ id: UUID?) {
        selectedGroupID = id
        loadSelection(id)
    }

    private func loadSelection(_ id: UUID?, clearsResult: Bool = true) {
        if clearsResult {
            batchResultTask?.cancel()
            batchResult = nil
        }
        editedGroupName = model.accountGroupState.groups.first(where: { $0.id == id })?.name ?? ""
        selectedAccounts = Set(model.accounts.filter { model.groupID(for: $0.name) == id }.map(\.name))
    }

    private func showBatchResult(_ message: String) {
        batchResultTask?.cancel()
        withAnimation(.easeInOut(duration: 0.15)) { batchResult = message }
        batchResultTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.15)) { batchResult = nil }
        }
    }
}

private struct AccountDashboardRow: View {
    @EnvironmentObject private var model: AppModel
    @State private var showingActions = false
    private let accent = AppStyle.accent
    let account: AccountUsage
    let displayName: String
    let identityHelp: String
    let isCurrent: Bool
    let isRecommended: Bool
    let usesCompactLayout: Bool
    let isRefreshing: Bool
    let isSwitching: Bool
    let refreshAction: () -> Void
    let switchAction: () -> Void
    let aliasAction: () -> Void
    let removeAction: () -> Void
    let reauthenticateAction: () -> Void
    let allowsDragging: Bool
    let isBeingDragged: Bool
    let dragChanged: (CGSize) -> Void
    let dragEnded: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            dragControl
            if usesCompactLayout {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 12) {
                        accountIdentity
                        Spacer(minLength: 8)
                        accountActions
                    }
                    quotaColumns
                }
            } else {
                accountIdentity.frame(width: 170, alignment: .leading)
                quotaColumns
                accountActions.frame(width: 144, alignment: .trailing)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(isCurrent ? accent.opacity(0.06) : AppStyle.surface)
        .overlay(alignment: .bottom) { Divider().padding(.leading, 40) }
        .opacity(isBeingDragged ? 0 : 1)
    }

    private var quotaColumns: some View {
        HStack(alignment: .top, spacing: 24) {
            QuotaBar(title: model.text("5 小时剩余"), value: account.fiveHourRemaining,
                     reset: account.fiveHourReset, isHistorical: account.authInvalid)
            QuotaBar(title: model.text("周额度剩余"), value: account.weeklyRemaining,
                     reset: account.weeklyReset, isHistorical: account.authInvalid)
        }
        .frame(maxWidth: .infinity)
    }

    private var accountIdentity: some View {
        VStack(alignment: .leading, spacing: 5) {
            HoverAccountName(name: displayName, identityHelp: identityHelp, font: .system(size: 14, weight: .semibold))
                .lineLimit(1)
            if account.authInvalid {
                InvalidAccountBadge(reauthenticateAction: reauthenticateAction)
            } else if isCurrent {
                Text(model.text("正在使用")).font(.system(size: 12)).foregroundStyle(accent)
            } else if isRecommended {
                Text(model.text("推荐备用")).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if account.resetCards > 0 {
                Text(model.text("重置卡 %d 张", account.resetCards))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var dragControl: some View {
        DragHandle()
            .frame(width: 14, height: 20)
            .contentShape(Rectangle())
            .handCursor()
            .allowsHitTesting(allowsDragging)
            .opacity(allowsDragging ? 1 : 0.28)
            .gesture(
                DragGesture(minimumDistance: 3, coordinateSpace: .named("account-list"))
                    .onChanged { dragChanged($0.translation) }
                    .onEnded { _ in dragEnded() }
            )
            .help(model.text(allowsDragging ? "拖动排序" : "清空排序条件后可拖动"))
            .accessibilityLabel(model.text("拖动排序"))
    }

    private var accountActions: some View {
        HStack(spacing: 6) {
            Button(action: refreshAction) {
                ZStack {
                    if isRefreshing { ProgressView().controlSize(.small) }
                    else { Image(systemName: "arrow.clockwise") }
                }
                .frame(width: 26, height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel(model.text("刷新"))
            .help(model.text(account.authInvalid ? "重新登录后手动查询此账号" : "立即查询此账号，不等待"))
            .disabled(isRefreshing || isSwitching)

            Menu {
                Button(model.text("设置别名"), action: aliasAction)
                Menu(model.text("更换分组")) {
                    ForEach(model.accountGroupState.groups) { group in
                        Button {
                            model.assignAccounts([account.name], to: group.id)
                        } label: {
                            if model.groupID(for: account.name) == group.id {
                                Label(group.name, systemImage: "checkmark")
                            } else { Text(group.name) }
                        }
                    }
                    Button(model.text("未分组")) { model.assignAccounts([account.name], to: nil) }
                }
                Button(model.text("查看账号信息")) { showingActions = true }
                Divider()
                Button(model.text("移除账号"), role: .destructive, action: removeAction)
                    .disabled(isCurrent)
            } label: {
                Image(systemName: "ellipsis").frame(width: 22, height: 26)
            }
            .menuIndicator(.hidden)
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel(model.text("账号操作"))
            .help(model.text("账号操作"))
            .disabled(isSwitching)
            .popover(isPresented: $showingActions) {
                Text(identityHelp).textSelection(.enabled)
                    .font(.system(size: 13)).padding(18)
                    .frame(minWidth: 240, maxWidth: 420, alignment: .leading)
            }
            if !isCurrent {
                Button(model.text("切换"), action: switchAction)
                    .buttonStyle(.bordered)
                    .disabled(isSwitching)
            }
        }
        .controlSize(.regular)
        .fixedSize()
    }
}

private struct QuotaBar: View {
    @EnvironmentObject private var model: AppModel
    let title: String
    let value: Int
    let reset: String
    var isHistorical = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text("\(value)%").font(.system(size: 14, weight: .medium)).monospacedDigit()
                    .foregroundStyle(isHistorical ? Color.secondary : Color.primary)
            }
            GeometryReader { geometry in
                Capsule().fill(Color.primary.opacity(0.07))
                Capsule().fill(isHistorical ? Color.secondary.opacity(0.4) : Color.secondary)
                    .frame(width: geometry.size.width * Double(max(0, min(value, 100))) / 100)
            }
            .frame(height: 4)
            .accessibilityHidden(true)
            Text(model.text(isHistorical ? "上次记录 · 重置 %@" : "重置 %@", compactReset))
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var compactReset: String {
        reset.count >= 16 ? String(reset.dropFirst(5)) : reset
    }
}

private struct HoverAccountName: View {
    let name: String
    let identityHelp: String
    let font: Font
    @State private var isPresented = false
    @State private var dismissTask: Task<Void, Never>?

    var body: some View {
        Text(name)
            .font(font)
            .onHover { hovering in
                if hovering {
                    showPopover()
                } else {
                    scheduleDismiss()
                }
            }
            .popover(
                isPresented: $isPresented,
                attachmentAnchor: .rect(.bounds),
                arrowEdge: .top
            ) {
                Text(identityHelp)
                    .font(.system(size: 15))
                    .foregroundColor(Color(nsColor: .labelColor))
                    .lineLimit(nil)
                    .lineSpacing(4)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .onHover { hovering in
                        if hovering {
                            dismissTask?.cancel()
                        } else {
                            scheduleDismiss()
                        }
                    }
            }
            .onDisappear { dismissTask?.cancel() }
    }

    private func showPopover() {
        dismissTask?.cancel()
        isPresented = true
    }

    private func scheduleDismiss() {
        dismissTask?.cancel()
        dismissTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            isPresented = false
        }
    }
}

private struct InvalidAccountBadge: View {
    @EnvironmentObject private var model: AppModel
    let reauthenticateAction: () -> Void

    var body: some View {
        Button(model.text("重新登录"), action: reauthenticateAction)
            .buttonStyle(.link)
            .font(.system(size: 12))
            .fixedSize()
            .help(model.text("账号登录已失效，点击重新登录"))

    }
}

private struct DragHandle: View {
    private let columns = [GridItem(.fixed(2), spacing: 2), GridItem(.fixed(2), spacing: 2)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 2) {
            ForEach(0..<6, id: \.self) { _ in
                Circle().frame(width: 2, height: 2)
            }
        }
        .foregroundStyle(.secondary)
        .frame(width: 8, height: 14)
    }
}

private struct AccountRowFramePreferenceKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, newest in newest })
    }
}

private struct HoverHintModifier: ViewModifier {
    let text: String
    @State private var isVisible = false
    @State private var revealTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                revealTask?.cancel()
                if hovering {
                    revealTask = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(400))
                        guard !Task.isCancelled else { return }
                        isVisible = true
                    }
                } else {
                    isVisible = false
                }
            }
            .overlay(alignment: .top) {
                if isVisible {
                    Text(text)
                        .font(.system(size: 14))
                        .foregroundStyle(.primary)
                        .fixedSize()
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                        .shadow(radius: 3, y: 1)
                        .offset(y: -31)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.12), value: isVisible)
            .zIndex(isVisible ? 10 : 0)
            .onDisappear { revealTask?.cancel() }
    }
}

private struct HandCursorModifier: ViewModifier {
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                if hovering && !isHovering {
                    NSCursor.openHand.push()
                    isHovering = true
                } else if !hovering && isHovering {
                    NSCursor.pop()
                    isHovering = false
                }
            }
            .onDisappear {
                if isHovering {
                    NSCursor.pop()
                    isHovering = false
                }
            }
    }
}

private extension View {
    func hoverHint(_ text: String) -> some View {
        modifier(HoverHintModifier(text: text))
    }

    func handCursor() -> some View {
        modifier(HandCursorModifier())
    }
}
