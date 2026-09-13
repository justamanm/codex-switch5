import CodexSwitcherCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        DashboardView()
            .font(.system(size: 15))
            .controlSize(.large)
            .dynamicTypeSize(.xxLarge)
    }

    private var sidebar: some View {
        List(selection: $model.selectedAccount) {
            Section {
                currentCard
            }
            Section(model.text("账号")) {
                ForEach(model.accounts) { account in
                    AccountRow(
                        account: account,
                        isCurrent: model.currentType == "account" && model.currentName == account.name,
                        isRecommended: model.recommendation?.name == account.name
                    )
                    .tag(account.name)
                }
            }
        }
        .navigationTitle("Codex Switch5")
        .listStyle(.sidebar)
        .frame(minWidth: 280)
    }

    private var currentCard: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(model.text("当前使用")).font(.system(size: 14)).foregroundStyle(.secondary)
            HStack {
                Image(systemName: model.currentType == "hub" ? "network" : "person.crop.circle.fill")
                    .foregroundStyle(.tint)
                Text(model.currentName.isEmpty ? model.text("未识别") : model.currentName)
                    .font(.headline)
                Spacer()
                Text(model.text(model.currentType == "hub" ? "中转站" : "账号"))
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder private var detail: some View {
        if let account = model.selected {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header(account)
                    quotaGrid(account)
                    settings
                    if let error = model.lastError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    }
                }
                .padding(30)
            }
        } else {
            ContentUnavailableView(
                model.text("暂无账号数据"),
                systemImage: "person.crop.circle.badge.questionmark",
                description: Text(model.text("点击“立即刷新”读取账号限额。"))
            )
        }
    }

    private func header(_ account: AccountUsage) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 9) {
                    Text(account.name).font(.system(size: 30, weight: .bold, design: .rounded))
                    if model.recommendation?.name == account.name {
                        Label(model.text("推荐"), systemImage: "sparkles")
                            .font(.system(size: 14, weight: .semibold)).foregroundStyle(.green)
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .background(.green.opacity(0.1), in: Capsule())
                    }
                }
                Text(model.text("最近更新：%@", formattedTimestamp(account.notedAt)))
                    .font(.system(size: 15)).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                model.requestSwitch(to: account.name)
            } label: {
                Label(model.text(model.recommendation?.name == account.name ? "切换到推荐账号" : "切换账号"), systemImage: "arrow.left.arrow.right")
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.currentType == "account" && model.currentName == account.name)
        }
    }

    private func quotaGrid(_ account: AccountUsage) -> some View {
        HStack(spacing: 16) {
            QuotaCard(title: model.text("5 小时额度"), value: account.fiveHourRemaining, reset: account.fiveHourReset, icon: "clock")
            QuotaCard(title: model.text("周额度"), value: account.weeklyRemaining, reset: account.weeklyReset, icon: "calendar")
            VStack(alignment: .leading, spacing: 12) {
                Label(model.text("重置卡"), systemImage: "arrow.counterclockwise.circle")
                    .font(.headline).foregroundStyle(.secondary)
                Text("\(account.resetCards)").font(.system(size: 42, weight: .bold, design: .rounded))
                Text(model.text(account.resetCards > 0 ? "需要时可使用" : "当前没有可用重置卡"))
                    .font(.system(size: 14)).foregroundStyle(.secondary)
            }
            .padding(18).frame(maxWidth: .infinity, minHeight: 160, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(.quaternary))
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(model.text("自动查询")).font(.headline)
            Toggle(model.text("启用自动刷新"), isOn: $model.automaticRefresh)
                .onChange(of: model.automaticRefresh) { _, _ in model.configureAutomaticRefresh() }
            HStack {
                Text(model.text("刷新间隔"))
                Spacer()
                TextField(model.text("间隔"), value: $model.refreshIntervalValue, format: .number)
                    .frame(width: 70)
                Picker(model.text("时间单位"), selection: $model.refreshIntervalUnit) {
                    Text(model.text("秒")).tag("seconds")
                    Text(model.text("分钟")).tag("minutes")
                }
                .pickerStyle(.segmented)
                .labelsHidden().frame(width: 120)
                .onChange(of: model.refreshIntervalUnit) { _, _ in model.configureAutomaticRefresh() }
            }
            Text(model.text("自动查询默认每 1 分钟执行；可自定义秒或分钟。全量查询时账号之间间隔 1 秒。"))
                .font(.system(size: 14)).foregroundStyle(.secondary)
        }
        .padding(18).background(.background, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.quaternary))
    }

    private var statusPill: some View {
        HStack(spacing: 7) {
            if model.isRefreshing { ProgressView().controlSize(.small) }
            Circle().fill(model.lastError == nil ? .green : .orange).frame(width: 7, height: 7)
            Text(model.status).font(.system(size: 14)).lineLimit(1)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.thinMaterial, in: Capsule())
    }

    private func formattedTimestamp(_ value: String) -> String {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: value) else { return value }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

private struct AccountRow: View {
    @EnvironmentObject private var model: AppModel
    let account: AccountUsage
    let isCurrent: Bool
    let isRecommended: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(account.name).font(.headline)
                if isCurrent { Circle().fill(.green).frame(width: 7, height: 7).help(model.text("当前账号")) }
                Spacer()
                if isRecommended { Image(systemName: "sparkles").foregroundStyle(.green) }
            }
            HStack(spacing: 10) {
                Label("\(account.fiveHourRemaining)%", systemImage: "clock")
                Label("\(account.weeklyRemaining)%", systemImage: "calendar")
            }
            .font(.system(size: 14)).foregroundStyle(.secondary)
        }
        .padding(.vertical, 5)
    }
}

private struct QuotaCard: View {
    @EnvironmentObject private var model: AppModel
    let title: String
    let value: Int
    let reset: String
    let icon: String

    private var color: Color {
        value == 0 ? .red : value < 25 ? .orange : .green
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon).font(.headline).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text("\(value)").font(.system(size: 42, weight: .bold, design: .rounded))
                Text("%").font(.title3).foregroundStyle(.secondary)
            }
            ProgressView(value: Double(value), total: 100).tint(color)
            Text(model.text("重置：%@", reset)).font(.system(size: 14)).foregroundStyle(.secondary)
        }
        .padding(18).frame(maxWidth: .infinity, minHeight: 160, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.quaternary))
    }
}
