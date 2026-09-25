import UIKit

final class LaterAppDelegate: NSObject, UIApplicationDelegate {
    // The share extension now completes vision analysis before it dismisses, so the
    // app no longer owns a background URLSession to resume here. The delegate stays
    // because the app scene still needs a UIApplicationDelegate adaptor.
}
