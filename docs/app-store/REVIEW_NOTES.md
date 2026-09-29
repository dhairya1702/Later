# App Review Notes

Submitted with version 1.0 build `2026092901` on September 29, 2026.

Later is a screenshot organization app. It uses Photos access to find screenshots and Apple Vision for on-device OCR. A resized image is sent to our authenticated analysis service for transient processing by Google Vertex AI; neither screenshots nor analysis results are retained by our backend.

No account or sign-in is required. There are no purchases, subscriptions, advertisements, or cross-app tracking.

## Suggested review flow

1. Launch Later and continue through onboarding.
2. Grant full or limited Photos access containing at least one screenshot.
3. Allow the initial scan to finish and open an item from the home list.
4. Use an action such as Mark as Done, Add Reminder, or Add to Calendar. iOS requests the applicable permission only when needed.
5. From Photos, share an image to Later. The extension queues it and dismisses; analysis continues in a background URL session. A notification may report completion.
6. Open Settings in Later to review the in-app Privacy and Support information.

The Cleanup screen can delete an item from Later. If the item is linked to Photos, the app clearly labels the action and iOS presents its standard deletion confirmation.

App Attest is used for service authentication. A temporary legacy bearer-token fallback remains enabled only so older distributed builds continue working during migration.
