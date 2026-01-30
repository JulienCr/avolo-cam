# ServiceContainer Integration Notes

## Created Files

1. `/Users/julien.cruau/dev/avolo-cam/ios-app/AvoCam/AvoCam/Sources/Shared/DI/ServiceContainer.swift`

## Architecture Overview

The `ServiceContainer` provides centralized dependency injection for the AVOLO-CAM iOS app.

### Key Components

#### Configuration
- `AppConfiguration`: Loaded from UserDefaults with camera alias and bearer token

#### Core Services (Direct instances)
- `CaptureManager`: AVFoundation video capture (actor)
- `NDIManager`: NDI video transmission
- `TelemetryCollector`: System metrics collection (actor)

#### Coordinators
- `StreamingCoordinator`: Orchestrates capture → NDI pipeline (actor)
- `TelemetryAggregator`: Aggregates all telemetry sources (actor)
- `ThermalManager`: Monitors thermal state

#### Network Services
- `NetworkServer`: HTTP REST + WebSocket server (SwiftNIO)
- `BonjourService`: mDNS service advertisement

#### NDI Utilities
- `NDITallyPoller`: Polls tally state for torch control

### Dependency Graph

```
ServiceContainer (@MainActor)
│
├── configuration (AppConfiguration)
│
├── Core Services
│   ├── captureManager
│   ├── ndiManager
│   └── telemetryCollector
│
├── Coordinators
│   ├── streamingCoordinator
│   │   ├── depends on: captureManager
│   │   ├── depends on: ndiManager
│   │   └── receives: tallyPoller (post-init)
│   │
│   ├── telemetryAggregator
│   │   ├── depends on: telemetryCollector
│   │   └── receives: streamingCoordinator (post-init)
│   │
│   └── thermalManager
│
├── Network
│   ├── networkServer
│   │   └── requestHandler: set externally by AppCoordinator
│   │
│   └── bonjourService
│
└── NDI Utilities
    └── tallyPoller
        └── depends on: ndiManager
```

## Usage Pattern

### 1. Initialization (in AppDelegate or AvoCamApp)

```swift
@MainActor
class AppDelegate: NSObject, UIApplicationDelegate {
    let container = ServiceContainer.shared
    
    func application(_ application: UIApplication, 
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // ServiceContainer is already initialized as singleton
        // Start network services
        container.start()
        return true
    }
    
    func applicationWillTerminate(_ application: UIApplication) {
        container.stop()
    }
}
```

### 2. Access Services (Protocol-typed)

```swift
// In AppCoordinator or ViewModels
let container = ServiceContainer.shared

// Access via protocols for loose coupling
let streaming: StreamingService = container.streaming
let telemetry: TelemetryProvider = container.telemetry

// Or access concrete types directly
let streamingCoord = container.streamingCoordinator
let telemetryAgg = container.telemetryAggregator
```

### 3. Set Request Handler

AppCoordinator still needs to implement `NetworkRequestHandler` and wire itself to the server:

```swift
// In AppCoordinator
private func setupNetworking() {
    let server = ServiceContainer.shared.networkServer
    // TODO: Add method to set request handler
    // server.setRequestHandler(self)
}
```

## Lifecycle Methods

### Start Services
```swift
container.start()
```
- Starts Bonjour service
- Starts NetworkServer (HTTP/WS)

### Stop Services
```swift
container.stop()
```
- Stops telemetry collection
- Stops streaming if active
- Stops tally poller
- Stops Bonjour
- Stops NetworkServer

### Update Configuration
```swift
await container.updateAlias("AVOLO-CAM-NEW")
```
- Stops streaming if active
- Updates AppConfiguration
- Recreates Bonjour with new alias
- Note: Full implementation would recreate NDI + streaming coordinator

## Protocol-Oriented Access

The container provides protocol-typed accessors for key services:

```swift
var streaming: StreamingService { streamingCoordinator }
var telemetry: TelemetryProvider { telemetryAggregator }
```

This allows controllers and view models to depend on protocols rather than concrete types.

## Thread Safety & Actor Isolation

- ServiceContainer: `@MainActor` (UI initialization)
- CaptureManager: `actor` (camera operations)
- StreamingCoordinator: `actor` (streaming pipeline)
- TelemetryAggregator: `actor` (telemetry collection)
- TelemetryCollector: `actor` (system metrics)
- ThermalManager: `class` (main thread)
- NetworkServer: `class` (NIO event loops)

## Next Steps

1. **Update NetworkServer** to add `setRequestHandler()` method
2. **Update AppCoordinator** to use ServiceContainer instead of creating services directly
3. **Add Testing Support** - Create `ServiceContainer.test(...)` factory for dependency injection in tests
4. **Refactor Controllers** to receive services via initializer instead of creating them

## Design Decisions

### Singleton Pattern
- Single source of truth for all services
- Easy access from anywhere: `ServiceContainer.shared`
- Can be replaced with instance injection for testing

### @MainActor Isolation
- Ensures UI-related initialization on main thread
- Safe access to UIKit components
- Prevents data races on shared state

### Lazy Initialization
- Some components initialized in `setupComponents()` due to circular dependencies
- Uses implicitly unwrapped optionals (`!`) for post-init services
- Alternative: make them optional and handle gracefully

### Protocol-Typed Accessors
- `streaming: StreamingService` instead of direct `streamingCoordinator`
- Enables loose coupling and easier testing
- Controllers depend on protocols, not concrete types

### Configuration-Driven
- All settings loaded from `AppConfiguration`
- Single source of truth for camera alias, token, etc.
- Easy to persist and restore settings

## Known Limitations

1. **Request Handler Wiring**: NetworkServer's requestHandler is nil at init, must be set by AppCoordinator
2. **Alias Update Incomplete**: `updateAlias()` doesn't fully recreate NDI pipeline
3. **No Test Support**: Singleton pattern makes unit testing harder (need factory method)
4. **Circular References**: Some services have weak references to avoid retain cycles
5. **No Scopes**: All services are singletons (no request-scoped or session-scoped services)

## Future Enhancements

1. Add `ServiceContainer.test(...)` factory for dependency injection
2. Add `setRequestHandler()` to NetworkServer
3. Complete `updateAlias()` to fully recreate NDI pipeline
4. Add service registration/resolution pattern for extensibility
5. Add lifecycle hooks for services (onStart, onStop, onPause)
