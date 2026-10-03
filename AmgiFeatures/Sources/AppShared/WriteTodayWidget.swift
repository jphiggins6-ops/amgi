//
//  WriteTodayWidget.swift
//  AppShared
//

public import AppCore
import Foundation
import WidgetKit

/// Saves where today's minimum stands for the Today widget and asks
/// WidgetKit to redraw it. Cheap: one small value in the app group and a
/// reload of one widget kind, so the Library calls it on every load.
public func writeTodayWidget(_ snapshot: TodaySnapshot) {
    // Not from unit tests: they'd leave numbers in the shared defaults.
    if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
        return
    }
    guard TodaySnapshotStore.read() != snapshot else { return }
    TodaySnapshotStore.write(snapshot)
    WidgetCenter.shared.reloadTimelines(ofKind: TodaySnapshot.widgetKind)
}
