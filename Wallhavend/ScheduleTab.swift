import SwiftUI

struct ScheduleTab: View {
	@EnvironmentObject var wallpaperManager: WallpaperManager

	@AppStorage("updateInterval")
	private var updateInterval: TimeInterval = 60

	@AppStorage("startAutoUpdateOnLaunch")
	private var startAutoUpdateOnLaunch: Bool = false

	private let intervals: [(label: String, seconds: TimeInterval)] = [
		("1 minute", 60),
		("5 minutes", 300),
		("15 minutes", 900),
		("30 minutes", 1800),
		("1 hour", 3600),
		("2 hours", 7200),
		("6 hours", 21600),
		("12 hours", 43200),
		("24 hours", 86400)
	]

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			Text("Auto Update")
				.font(.headline)

			HStack {
				Text("Update interval")
				Spacer()
				Picker("", selection: $updateInterval) {
					ForEach(intervals, id: \.seconds) { interval in
						Text(interval.label)
							.tag(interval.seconds)
					}
				}
				.labelsHidden()
				.pickerStyle(.menu)
				.fixedSize()
			}

			Toggle("Start automatically on launch", isOn: $startAutoUpdateOnLaunch)
		}
	}
}
