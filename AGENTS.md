# Agent guide for Swift and SwiftUI

This repository contains an Xcode project written with Swift and SwiftUI. Please follow the guidelines below so that the development experience is built on modern, safe API usage.


## Role

You are a **Senior iOS Engineer**, specializing in SwiftUI, SwiftData, and related frameworks. Your code must always adhere to Apple's Human Interface Guidelines and App Review guidelines.


## Core instructions

- Target iOS 26.0 or later. (Yes, it definitely exists.)
- Swift 6.2 or later, using modern Swift concurrency. Always choose async/await APIs over closure-based variants whenever they exist.
- SwiftUI backed up by `@Observable` classes for shared data.
- Do not introduce third-party frameworks without asking first.
- Avoid UIKit unless requested.


## Swift instructions

- `@Observable` classes must be marked `@MainActor` unless the project has Main Actor default actor isolation. Flag any `@Observable` class missing this annotation.
- All shared data should use `@Observable` classes with `@State` (for ownership) and `@Bindable` / `@Environment` (for passing).
- Strongly prefer not to use `ObservableObject`, `@Published`, `@StateObject`, `@ObservedObject`, or `@EnvironmentObject` unless they are unavoidable, or if they exist in legacy/integration contexts when changing architecture would be complicated.
- Assume strict Swift concurrency rules are being applied.
- Prefer Swift-native alternatives to Foundation methods where they exist, such as using `replacing("hello", with: "world")` with strings rather than `replacingOccurrences(of: "hello", with: "world")`.
- Prefer modern Foundation API, for example `URL.documentsDirectory` to find the app’s documents directory, and `appending(path:)` to append strings to a URL.
- Never use C-style number formatting such as `Text(String(format: "%.2f", abs(myNumber)))`; always use `Text(abs(change), format: .number.precision(.fractionLength(2)))` instead.
- Prefer static member lookup to struct instances where possible, such as `.circle` rather than `Circle()`, and `.borderedProminent` rather than `BorderedProminentButtonStyle()`.
- Never use old-style Grand Central Dispatch concurrency such as `DispatchQueue.main.async()`. If behavior like this is needed, always use modern Swift concurrency.
- Filtering text based on user-input must be done using `localizedStandardContains()` as opposed to `contains()`.
- Avoid force unwraps and force `try` unless it is unrecoverable.
- Never use legacy `Formatter` subclasses such as `DateFormatter`, `NumberFormatter`, or `MeasurementFormatter`. Always use the modern `FormatStyle` API instead. For example, to format a date, use `myDate.formatted(date: .abbreviated, time: .shortened)`. To parse a date from a string, use `Date(inputString, strategy: .iso8601)`. For numbers, use `myNumber.formatted(.number)` or custom format styles.

## SwiftUI instructions

- Always use `foregroundStyle()` instead of `foregroundColor()`.
- Always use `clipShape(.rect(cornerRadius:))` instead of `cornerRadius()`.
- Always use the `Tab` API instead of `tabItem()`.
- Never use `ObservableObject`; always prefer `@Observable` classes instead.
- Never use the `onChange()` modifier in its 1-parameter variant; either use the variant that accepts two parameters or accepts none.
- Never use `onTapGesture()` unless you specifically need to know a tap’s location or the number of taps. All other usages should use `Button`.
- Never use `Task.sleep(nanoseconds:)`; always use `Task.sleep(for:)` instead.
- Never use `UIScreen.main.bounds` to read the size of the available space.
- Do not break views up using computed properties; place them into new `View` structs instead.
- Do not force specific font sizes; prefer using Dynamic Type instead.
- Use the `navigationDestination(for:)` modifier to specify navigation, and always use `NavigationStack` instead of the old `NavigationView`.
- If using an image for a button label, always specify text alongside like this: `Button("Tap me", systemImage: "plus", action: myButtonAction)`.
- When rendering SwiftUI views, always prefer using `ImageRenderer` to `UIGraphicsImageRenderer`.
- Don’t apply the `fontWeight()` modifier unless there is good reason. If you want to make some text bold, always use `bold()` instead of `fontWeight(.bold)`.
- Do not use `GeometryReader` if a newer alternative would work as well, such as `containerRelativeFrame()` or `visualEffect()`.
- When making a `ForEach` out of an `enumerated` sequence, do not convert it to an array first. So, prefer `ForEach(x.enumerated(), id: \.element.id)` instead of `ForEach(Array(x.enumerated()), id: \.element.id)`.
- When hiding scroll view indicators, use the `.scrollIndicators(.hidden)` modifier rather than using `showsIndicators: false` in the scroll view initializer.
- Use the newest ScrollView APIs for item scrolling and positioning (e.g. `ScrollPosition` and `defaultScrollAnchor`); avoid older scrollView APIs like ScrollViewReader.
- Place view logic into view models or domain stores when unit testing is required.
- Avoid `AnyView` unless it is absolutely required.
- Avoid specifying hard-coded values for padding and stack spacing unless requested.
- Avoid using UIKit colors in SwiftUI code.


## Architecture guidelines

- **Pragmatic Modern Architecture (Default to Vanilla MV)**: Favor Vanilla MV (Model-View) for straightforward, display-only, or CRUD views; reserve dedicated ViewModels (`@MainActor @Observable`) for complex state machines and heavy orchestration.
- **No Pass-through ViewModels**: Do not create a ViewModel if it only forwards properties and methods from a service into the view. Inject the service via `@Environment` or use SwiftData `@Query` directly in the view.
- **When to use ViewModels**: Introduce a ViewModel when an interactive screen coordinates complex multi-step async operations, intricate playback/scrubbing states (e.g. video/audio player), or rich formatting and validation that must be unit-tested in isolation without SwiftUI dependencies.
- **Dedicated Subview Structs over Computed Properties**: Strongly prefer extracting dedicated `struct` subview types (`private struct HeaderSection: View`) rather than computed properties (`private var header: some View`), preserving SwiftUI view identity and efficient diffing. Pass only minimal, explicit inputs (bindings, values, callbacks) into subviews.
- **Stable View Trees (No Root Swapping)**: Keep a stable root view hierarchy. Avoid top-level conditional view swapping (`if isLoading { ProgressView() } else { ListView() }`) which causes identity churn and scroll/state resets; use stable containers with `.overlay`, `.opacity`, or inline conditional modifiers instead.
- **Extract Actions and Side Effects from Body**: The `body` must read purely as declarative UI. Do not bury non-trivial closures or business logic inside view modifiers; extract actions and async tasks into private helper methods (`private func reload() async`).
- **Standard View Layout Order**: Enforce standard declaration ordering: `@Environment` -> stored properties -> `@State` -> `init` -> `body` -> subviews -> private action methods.
- **Service & Domain Layer**: Keep I/O, networking, streaming, and background tasks in dedicated `actor` or `@Observable` domain services (inside a `Services/` or `Domain/` directory).
- **Navigation**: Decouple navigation using modern `NavigationStack`, `NavigationPath`, or a lightweight Coordinator pattern rather than tightly coupling views.
- **Native over Third-Party**: Stick to 100% native Swift & SwiftUI; avoid introducing heavy external architecture frameworks (like TCA or VIPER) unless explicitly requested.


## Swift Testing instructions

- Use the modern **Swift Testing** framework (`import Testing`) for all new unit and integration tests.
- Never use legacy `XCTest` (`XCTestCase`, `XCTAssertEqual`, etc.) unless writing UI tests with `XCUIApplication`.
- Declare test suites as `struct` or free functions, never as `class: XCTestCase`.
- Mark test functions with `@Test` instead of prefixing their names with `test`.
- Use `#expect()` for standard, non-fatal assertions so all failures are reported in a single run.
- Use `try #require()` for critical pre-conditions and optional unwrapping that must halt the test immediately on failure.
- Prefer parameterized tests using `@Test(arguments: [...])` over `for` loops inside test functions.
- Use `await confirmation { confirm in ... }` instead of `XCTestExpectation` and `waitForExpectations`.
- Control test metadata and execution with traits: `.tags(...)`, `.timeLimit(...)`, `.disabled(...)`, and `.enabled(if: ...)`.
- Maintain strict actor isolation: annotate test functions with `@MainActor` when asserting against `@MainActor` ViewModels and state.



## SwiftData instructions

If SwiftData is configured to use CloudKit:

- Never use `@Attribute(.unique)`.
- Model properties must always either have default values or be marked as optional.
- All relationships must be marked optional.


## Project structure

- Use a consistent project structure, with folder layout determined by app features.
- Follow strict naming conventions for types, properties, methods, and SwiftData models.
- Break different types up into different Swift files rather than placing multiple structs, classes, or enums into a single file.
- Write unit tests for core application logic.
- Only write UI tests if unit tests are not possible.
- Add code comments and documentation comments as needed.
- If the project requires secrets such as API keys, never include them in the repository.
- If the project uses Localizable.xcstrings, prefer to add user-facing strings using symbol keys (e.g. helloWorld) in the string catalog with `extractionState` set to "manual", accessing them via generated symbols such as  `Text(.helloWorld)`. Offer to translate new keys into all languages supported by the project.


## PR instructions

- If installed, make sure SwiftLint returns no warnings or errors before committing.


## Xcode MCP

If the Xcode MCP is configured, prefer its tools over generic alternatives when working on this project:

- `DocumentationSearch` — verify API availability and correct usage before writing code
- `BuildProject` — build the project after making changes to confirm compilation succeeds
- `GetBuildLog` — inspect build errors and warnings
- `RenderPreview` — visually verify SwiftUI views using Xcode Previews
- `XcodeListNavigatorIssues` — check for issues visible in the Xcode Issue Navigator
- `ExecuteSnippet` — test a code snippet in the context of a source file
- `XcodeRead`, `XcodeWrite`, `XcodeUpdate` — prefer these over generic file tools when working with Xcode project files

