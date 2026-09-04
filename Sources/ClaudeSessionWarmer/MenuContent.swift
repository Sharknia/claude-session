import AppKit
import SwiftUI

struct MenuContent: View {
    @ObservedObject var state: AppState
    @State private var draftTime: Date
    @State private var draftWeekdays: Set<Int>
    @State private var draftExcludeHolidays: Bool
    @State private var draftLaunchAtLogin: Bool
    @State private var didSave = false

    private let weekdays = [
        (1, "일"), (2, "월"), (3, "화"), (4, "수"), (5, "목"), (6, "금"), (7, "토")
    ]

    init(state: AppState) {
        self.state = state
        _draftTime = State(initialValue: state.firstWarmupDate)
        _draftWeekdays = State(initialValue: state.settings.weekdays)
        _draftExcludeHolidays = State(initialValue: state.settings.excludeKoreanHolidays)
        _draftLaunchAtLogin = State(initialValue: state.settings.launchAtLogin)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            scheduleSettings
            Divider()
            actions
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 372)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Claude Session Warmer")
                    .font(.headline)
                Spacer()
                if state.isWorking {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            infoRow(label: "상태", value: state.statusMessage)

            HStack(spacing: 10) {
                Text("오늘 처리")
                    .foregroundStyle(.secondary)
                    .frame(width: 72, alignment: .leading)
                ProgressView(
                    value: Double(state.handledWindowsToday),
                    total: Double(ScheduleEngine.maximumWindowsPerDay)
                )
                Text("\(state.handledWindowsToday)/3")
                    .monospacedDigit()
                    .frame(width: 28, alignment: .trailing)
            }
            .font(.caption)

            infoRow(label: "다음", value: state.nextEvent.map { "워밍 · \(formatted($0.date))" } ?? "없음")
            infoRow(
                label: "리셋",
                value: (state.currentQuota?.resetsAt ?? state.cycle.nextResetAt).map(formatted) ?? "없음"
            )
            infoRow(
                label: "사용량",
                value: state.currentQuota?.usedPercent.map { String(format: "%.0f%%", $0) } ?? "확인 전"
            )
        }
    }

    private var scheduleSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
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
                "로그인 시 실행",
                isOn: Binding(
                    get: { draftLaunchAtLogin },
                    set: {
                        draftLaunchAtLogin = $0
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
                    .disabled((!hasDraftChanges && didSave) || draftWeekdays.isEmpty || state.isWorking)
            }
        }
    }

    private var actions: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                actionButton("지금 워밍", prominent: true) { state.manualWarmup() }
                actionButton("새로고침") { state.refresh() }
            }
            .disabled(state.isWorking)

            HStack(spacing: 8) {
                actionButton("오늘 정지", tint: .orange) { state.pauseToday() }
                    .disabled(state.cycle.pausedToday)
                actionButton("다음 건너뛰기", tint: .secondary) { state.skipNextWarmup() }
                    .disabled(state.cycle.skipNext)
            }
        }
    }

    private var footer: some View {
        HStack(alignment: .bottom, spacing: 12) {
            if let record = state.cycle.lastRecord {
                VStack(alignment: .leading, spacing: 2) {
                    Text("최근 결과")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("\(formatted(record.timestamp)) · \(record.message)")
                        .font(.caption)
                        .lineLimit(2)
                }
            }
            Spacer()
            Button("종료") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
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

    private func saveDraft() {
        Task { @MainActor in
            guard await state.prepareAndApplySettings(
                firstWarmupDate: draftTime,
                weekdays: draftWeekdays,
                excludeKoreanHolidays: draftExcludeHolidays,
                launchAtLogin: draftLaunchAtLogin
            ) else { return }

            draftTime = state.firstWarmupDate
            draftWeekdays = state.settings.weekdays
            draftExcludeHolidays = state.settings.excludeKoreanHolidays
            draftLaunchAtLogin = state.settings.launchAtLogin
            didSave = true
        }
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)
            Text(value)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
        .font(.caption)
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

    @ViewBuilder
    private func actionButton(
        _ title: String,
        prominent: Bool = false,
        tint: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        if prominent {
            Button(action: action) {
                Text(title).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(tint)
            .controlSize(.large)
        } else {
            Button(action: action) {
                Text(title).frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(tint)
            .controlSize(.large)
        }
    }

    private func formatted(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}
