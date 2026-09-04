import AppKit
import SwiftUI

struct MenuContent: View {
    @ObservedObject var state: AppState

    private let weekdays = [
        (1, "일"), (2, "월"), (3, "화"), (4, "수"), (5, "목"), (6, "금"), (7, "토")
    ]

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
        .padding(14)
        .frame(width: 340)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Claude Session Warmer")
                    .font(.headline)
                Spacer()
                if state.isWorking {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            Text(state.statusMessage)
                .font(.subheadline)
            Text("오늘 처리 \(state.handledWindowsToday)/3")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let next = state.nextEvent {
                Text("다음: 워밍 · \(formatted(next.date))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let reset = state.currentQuota?.resetsAt ?? state.cycle.nextResetAt {
                Text("리셋: \(formatted(reset))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let percent = state.currentQuota?.usedPercent {
                Text("5시간 사용량: \(percent, specifier: "%.0f")%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var scheduleSettings: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("첫 워밍")
                Spacer()
                DatePicker(
                    "",
                    selection: Binding(
                        get: { state.firstWarmupDate },
                        set: { state.updateFirstWarmupTime($0) }
                    ),
                    displayedComponents: .hourAndMinute
                )
                .labelsHidden()
                .frame(width: 95)
            }

            HStack(spacing: 5) {
                ForEach(weekdays, id: \.0) { weekday, title in
                    Button(title) {
                        state.toggleWeekday(weekday)
                    }
                    .buttonStyle(.bordered)
                    .tint(state.settings.weekdays.contains(weekday) ? .accentColor : .gray)
                    .controlSize(.small)
                }
            }

            Toggle(
                "대한민국 공휴일 제외",
                isOn: Binding(
                    get: { state.settings.excludeKoreanHolidays },
                    set: { state.setExcludeKoreanHolidays($0) }
                )
            )
            Toggle(
                "로그인 시 실행",
                isOn: Binding(
                    get: { state.settings.launchAtLogin },
                    set: { state.setLaunchAtLogin($0) }
                )
            )
        }
    }

    private var actions: some View {
        VStack(spacing: 7) {
            HStack {
                Button("새로고침") { state.refresh() }
                Button("지금 워밍") { state.manualWarmup() }
            }
            .disabled(state.isWorking)

            HStack {
                Button("오늘 정지") { state.pauseToday() }
                    .disabled(state.cycle.pausedToday)
                Button("다음 건너뛰기") { state.skipNextWarmup() }
                    .disabled(state.cycle.skipNext)
            }
        }
    }

    private var footer: some View {
        HStack {
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
        }
    }

    private func formatted(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}
