# Build and test

- Do not use FlowDeck on this machine — it is license-blocked. Use xcodebuild directly.
- iOS tests:
  `xcodebuild test -project FootballPerformance.xcodeproj -scheme FootballPerformanceTests -destination 'platform=iOS Simulator,id=CD369CF5-53C5-4EB2-9FC4-164D2716AAAC'`
- watchOS tests:
  `xcodebuild test -project FootballPerformance.xcodeproj -scheme FootballPerformanceWatchTests -destination 'platform=watchOS Simulator,id=BD726DC2-42A8-42C6-80E6-064BC09D7288'`
