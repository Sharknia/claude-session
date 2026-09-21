import AppKit
import SwiftUI

enum MenuDateFormatting {
    static func currentFiveHourRange(
        endingAt resetsAt: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "HH:mm"
        let startsAt = resetsAt.addingTimeInterval(-ScheduleEngine.quotaWindowDuration)
        return "\(formatter.string(from: startsAt))–\(formatter.string(from: resetsAt))"
    }
}

struct MenuContent: View {
    @ObservedObject var state: AppState
    @ObservedObject var updater: AppUpdater
    @State private var draftTime: Date
    @State private var draftWeekdays: Set<Int>
    @State private var draftExcludeHolidays: Bool
    @State private var draftLaunchAtLogin: Bool
    @State private var loginPreferenceChanged = false
    @State private var didSave = false
    @State private var confirmResend = false
    @State private var confirmRecordRecovery = false

    private let weekdays = [
        (1, "일"), (2, "월"), (3, "화"), (4, "수"), (5, "목"), (6, "금"), (7, "토")
    ]

    init(state: AppState, updater: AppUpdater) {
        self.state = state
        self.updater = updater
        _draftTime = State(initialValue: state.firstWarmupDate)
        _draftWeekdays = State(initialValue: state.settings.weekdays)
        _draftExcludeHolidays = State(initialValue: state.settings.excludeKoreanHolidays)
        _draftLaunchAtLogin = State(initialValue: state.settings.launchAtLogin)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            storageRecovery
            Divider()
            scheduleSettings
                .disabled(!state.canEditSettings)
            Divider()
            actions
                .disabled(state.operationBlockReason != nil)
            if state.hasUnconfirmedWarmup {
                Button("미확인 전송을 해제하고 다시 워밍…") { confirmResend = true }
                    .font(.caption)
                    .disabled(state.hasActiveOperation || state.operationBlockReason != nil)
                    .alert("이전 요청이 이미 전송됐을 수 있습니다.", isPresented: $confirmResend) {
                        Button("취소", role: .cancel) {}
                        Button("확인 후 다시 전송") { state.manualWarmup(allowResend: true) }
                    } message: {
                        Text("현재 세션을 먼저 확인합니다. 비활성이면 이전 전송 기록을 해제하고 한 번 더 워밍합니다.")
                    }
            }
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 372)
        .onAppear {
            state.refreshSilently()
        }
    }

    @ViewBuilder
    private var storageRecovery: some View {
        if let issue = state.storageIssue {
            if issue.area == .settings, issue.kind == .corrupt {
                Text("아래 예약 초안을 저장하면 손상 원본을 보존하고 설정을 복구합니다.")
                    .font(.caption)
            }
            if issue.kind != .unsupported {
                HStack {
                    Button("다시 읽기") { state.reloadStoredState() }
                    if state.canRecoverRuntime {
                        Button("실행 기록 복구…") { confirmRecordRecovery = true }
                            .alert("손상된 실행 기록을 복구할까요?", isPresented: $confirmRecordRecovery) {
                                Button("취소", role: .cancel) {}
                                Button("원본 보존 후 복구") { state.recoverRuntime() }
                            } message: {
                                Text("기존 파일을 보존합니다. 마지막 전송 결과가 불확실하므로 오늘 자동 워밍을 중지하고 미확인 전송 상태를 유지합니다. 복구 후 상태 확인 또는 재전송을 선택할 수 있습니다.")
                            }
                    }
                }.disabled(state.hasActiveOperation)
            }
            if let directory = state.storageDirectory {
                Button("기록 폴더 열기") { NSWorkspace.shared.open(directory) }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Claude Session Warmer")
                    .font(.headline)
                Spacer()
                connectionControl
                    .disabled(state.operationBlockReason != nil)
            }

            HStack(spacing: 9) {
                Image(systemName: statusIcon)
                    .foregroundStyle(statusColor)
                Text(state.statusMessage)
                    .font(.subheadline)
                    .lineLimit(state.operationBlockReason == nil ? 2 : nil)
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))

            HStack(spacing: 8) {
                metricCard(
                    value: state.hasReadableCycle ? "\(state.handledWindowsToday)/3" : "확인 필요",
                    label: state.isRecoveryPausedToday ? "오늘 자동 워밍 중지" : "오늘 확인한 창",
                    progress: state.hasReadableCycle ? Double(state.handledWindowsToday) / 3 : nil
                )
                metricCard(
                    value: usageValue,
                    label: usageCaption,
                    progress: state.currentQuota?.usedPercent.map { $0 / 100 }
                )
            }

            HStack(spacing: 0) {
                scheduleColumn(
                    label: "다음 워밍",
                    value: state.nextEvent.map { smartFormatted($0.date) } ?? "없음"
                )
                Divider()
                    .padding(.vertical, 2)
                scheduleColumn(
                    label: "현재 5시간",
                    value: currentFiveHourValue
                )
            }
            .padding(.vertical, 10)
            .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private var scheduleSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("일정 설정")
                .font(.subheadline.weight(.semibold))

            HStack {
                Text("첫 워밍")
                    .frame(width: 104, alignment: .leading)
                Spacer()
                DatePicker(
                    "",
                    selection: Binding(
                        get: { draftTime },
                        set: {
                            draftTime = $0
                            didSave = false
                        }
                    ),
                    displayedComponents: .hourAndMinute
                )
                .labelsHidden()
                .frame(width: 104)
            }

            HStack(spacing: 5) {
                ForEach(weekdays, id: \.0) { weekday, title in
                    Button {
                        if draftWeekdays.contains(weekday) {
                            draftWeekdays.remove(weekday)
                        } else {
                            draftWeekdays.insert(weekday)
                        }
                        didSave = false
                    } label: {
                        Text(title)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(draftWeekdays.contains(weekday) ? .accentColor : .gray)
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
                }
            }

            settingToggle(
                "대한민국 공휴일 제외",
                isOn: Binding(
                    get: { draftExcludeHolidays },
                    set: {
                        draftExcludeHolidays = $0
                        didSave = false
                    }
                )
            )
            settingToggle(
                "Mac 로그인 시 앱 실행",
                isOn: Binding(
                    get: { draftLaunchAtLogin },
                    set: {
                        draftLaunchAtLogin = $0
                        loginPreferenceChanged = true
                        didSave = false
                    }
                )
            )

            HStack {
                if didSave {
                    Label("저장됨", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else if draftWeekdays.isEmpty {
                    Text("요일을 하나 이상 선택하세요.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Spacer()
                Button("저장") { saveDraft() }
                    .buttonStyle(.borderedProminent)
                    .disabled((!hasDraftChanges && state.storageIssue?.area != .settings) || draftWeekdays.isEmpty)
            }
        }
    }

    private var actions: some View {
        Button {
            state.manualWarmup()
        } label: {
            ZStack {
                Text("지금 워밍")
                    .opacity(state.isManualWarmupRunning ? 0 : 1)
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("워밍 중")
                }
                .opacity(state.isManualWarmupRunning ? 1 : 0)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 18)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .frame(maxWidth: .infinity)
        .accessibilityLabel(state.isManualWarmupRunning ? "워밍 중" : "지금 워밍")
        .disabled(state.isWorking || state.connectionState != .connected)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let record = state.cycle.lastRecord {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Label("최근 결과", systemImage: "clock.arrow.circlepath")
                        Spacer()
                        Text(smartFormatted(record.timestamp))
                            .monospacedDigit()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Text(record.displayMessage)
                        .font(.subheadline)
                        .lineLimit(2)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            }

            HStack {
                Text(appVersionLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("업데이트 확인") { updater.checkForUpdates() }
                    .buttonStyle(.plain)
                    .disabled(!updater.canCheckForUpdates)
                    .help("새 버전 설치를 선택하면 다운로드 후 앱이 다시 시작됩니다.")
                Button("종료") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var appVersionLabel: String {
        guard let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String else {
            return "개발 빌드"
        }
        return "v\(version) (빌드 \(build))"
    }

    private var hasDraftChanges: Bool {
        draftMinutes != state.settings.firstWarmupMinutes
            || draftWeekdays != state.settings.weekdays
            || draftExcludeHolidays != state.settings.excludeKoreanHolidays
            || draftLaunchAtLogin != state.settings.launchAtLogin
    }

    private var draftMinutes: Int {
        let components = Calendar.autoupdatingCurrent.dateComponents([.hour, .minute], from: draftTime)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }

    private var usageValue: String {
        guard let quota = state.currentQuota else { return "확인 필요" }
        guard quota.active else { return "없음" }
        return quota.usedPercent.map { String(format: "%.0f%%", $0) } ?? "—"
    }

    private var usageCaption: String {
        guard let quota = state.currentQuota else {
            switch state.connectionState {
            case .checking:
                return "사용량 확인 중"
            case .disconnected, .failed:
                return "Claude 연결 필요"
            case .connected:
                return "사용량 확인 필요"
            }
        }
        guard quota.active else { return "활성 5시간 창" }
        guard let used = quota.usedPercent else { return "사용량 정보 없음" }
        return String(format: "사용 · %.0f%% 남음", max(0, 100 - used))
    }

    private var currentFiveHourValue: String {
        guard let quota = state.currentQuota else { return "확인 필요" }
        guard quota.active, let resetsAt = quota.resetsAt else { return "없음" }
        return MenuDateFormatting.currentFiveHourRange(endingAt: resetsAt)
    }

    private func saveDraft() {
        guard state.applySettings(
            firstWarmupDate: draftTime,
            weekdays: draftWeekdays,
            excludeKoreanHolidays: draftExcludeHolidays,
            launchAtLogin: loginPreferenceChanged ? draftLaunchAtLogin : nil
        ) else { return }

        draftTime = state.firstWarmupDate
        draftWeekdays = state.settings.weekdays
        draftExcludeHolidays = state.settings.excludeKoreanHolidays
        draftLaunchAtLogin = state.settings.launchAtLogin
        loginPreferenceChanged = false
        didSave = true
    }

    @ViewBuilder
    private var connectionControl: some View {
        switch state.connectionState {
        case .disconnected:
            Button {
                state.connectClaude()
            } label: {
                Label("Claude 로그인", systemImage: "person.crop.circle.badge.plus")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(state.isWorking)

        case .checking:
            HStack(spacing: 5) {
                ProgressView()
                    .controlSize(.mini)
                Text("확인 중")
            }
            .font(.caption)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(.secondary.opacity(0.1), in: Capsule())

        case .connected:
            Label("연결됨", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(.green.opacity(0.1), in: Capsule())

        case .failed:
            Button {
                state.connectClaude()
            } label: {
                Label("다시 연결", systemImage: "exclamationmark.circle")
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .controlSize(.small)
            .disabled(state.isWorking)
        }
    }

    private func metricCard(value: String, label: String, progress: Double?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(value)
                .font(.title2.weight(.semibold))
                .monospacedDigit()
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            ProgressView(value: progress ?? 0)
                .opacity(progress == nil ? 0.25 : 1)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private func scheduleColumn(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.medium))
                .monospacedDigit()
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func settingToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(title)
                .frame(width: 180, alignment: .leading)
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
        }
    }

    private var statusIcon: String {
        switch state.status {
        case .idle: return "clock"
        case .checking: return "arrow.triangle.2.circlepath"
        case .warming: return "flame.fill"
        case .satisfied, .succeeded: return "checkmark.circle.fill"
        case .missed: return "forward.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        switch state.status {
        case .satisfied, .succeeded: return .green
        case .warming, .checking: return .accentColor
        case .missed: return .orange
        case .failed: return .red
        case .idle: return .secondary
        }
    }

    private func smartFormatted(_ date: Date) -> String {
        if Calendar.autoupdatingCurrent.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(.dateTime.month(.defaultDigits).day().hour().minute())
    }

}
