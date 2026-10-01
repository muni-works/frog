import SwiftUI
import WidgetKit

/// frog on the watch face: the same status widget as the iPhone's lock screen, fed by the watch
/// app from what the phone tells it.
@main
struct FrogWatchWidgets: WidgetBundle {
    var body: some Widget {
        StatusWidget()
    }
}
