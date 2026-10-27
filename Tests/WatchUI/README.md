# Watch UI automation

`FootballPerformanceWatchUITests` is a watchOS XCUITest target generated from `project.yml`. The user explicitly requested XCUITest for this Watch task. The existing TesterArmy configuration targets the iPhone.

Generate the project with `xcodegen generate --spec project.yml`. Run the tests on the already booted 42mm Watch only:

```sh
DEVELOPER_DIR=/Applications/Xcode-27.1-beta.app/Contents/Developer \
xcodebuild test \
  -project FootballPerformance.xcodeproj \
  -scheme FootballPerformanceWatchUITests \
  -destination 'platform=watchOS Simulator,id=3BE5CDAE-63E6-48BF-A1F1-DD9DEE7E339C' \
  -derivedDataPath /tmp/fp-redesign-watchui-dd \
  -parallel-testing-enabled NO \
  -resultBundlePath .scratch/qa-20261021/WatchUI-uifix.xcresult
```

Remove an old bundle with this exact name before a repeat run. Keep the specified simulator and its data.

The seven independent tests cover initial Start visibility, countdown and missing metrics, a quick finish tap, a 2.5-second finish hold, navigation, termination after ten active seconds and explicit recovery, and a non-default session type. Scenario B requires a dash for unobserved simulator distance. Scenario A checks the entire Start control before any scroll.

Every captured step retains a screenshot and accessibility tree as `XCTAttachment` objects. Observations also have JSON text attachments. Both DEBUG automation environment hooks are disabled; recording uses real Start and Hold to Finish interactions. The recovery test uses the existing simulator data and the app's Recover Sessions action, which processes all interrupted sessions that it finds. It does not clear that data.

The permission monitor handles Health and motion prompts when shown. Previously granted permissions do not cause a fresh prompt, so such a run does not validate that handler.

Export attachments with the same Xcode selected:

```sh
DEVELOPER_DIR=/Applications/Xcode-27.1-beta.app/Contents/Developer \
xcrun xcresulttool export attachments \
  --path .scratch/qa-20261021/WatchUI-uifix.xcresult \
  --output-path .scratch/qa-20261021/uifix-shots/watch
```

The export includes PNG files and a manifest that maps each attachment to its test and step. The result bundle's simulator UDID and platform identify the target. This Xcode sometimes labels the Watch's `deviceName` as its paired iPhone; its `deviceId`, `modelName`, and `platform` identify the Watch correctly.
