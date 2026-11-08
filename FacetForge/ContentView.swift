import SwiftUI

struct ContentView: View {
    @State private var showingGallery = false

    var body: some View {
        FFAppShell(
            launchRecoveryDemo: FFLaunchFixtures.wantsRecoveryDemo,
            launchBrowserDemo: FFLaunchFixtures.wantsBrowserDemo,
            onOpenGallery: { showingGallery = true }
        )
            .background(
                FFSceneSizeRestrictionsView()
                    .frame(width: 0, height: 0)
            )
            .preferredColorScheme(.dark)
            .sheet(isPresented: $showingGallery) {
                ComponentGalleryView()
            }
    }
}
