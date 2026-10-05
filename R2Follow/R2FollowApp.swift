import SwiftUI

@main
struct R2FollowApp: App {
    @StateObject private var model = FollowAppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
        }
    }
}
