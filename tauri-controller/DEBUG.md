# Debugging Guide for AvoCam Controller

## Running in Development Mode

### From project root:
```bash
pnpm tauri:dev          # Normal dev mode with debug logging
pnpm tauri:dev:verbose  # Verbose mode with full debug output
```

### From tauri-controller directory:
```bash
cd tauri-controller
pnpm tauri:dev          # Normal dev mode
pnpm tauri:dev:verbose  # Verbose mode
```

## Browser DevTools

The development build has **DevTools enabled** automatically. To access:

- **macOS**: `Cmd + Option + I`
- **Windows/Linux**: `Ctrl + Shift + I` or `F12`
- **Right-click** anywhere in the app and select "Inspect Element"

## Rust Backend Logging

The app uses `env_logger` for Rust logging. Log levels are configured via `RUST_LOG`:

### Log Levels (in order of verbosity)
1. `error` - Only errors
2. `warn` - Warnings and errors
3. `info` - Informational messages (default for dependencies)
4. `debug` - Debug info (default for our app)
5. `trace` - Very detailed trace information

### Default Configuration
- **Normal dev**: `RUST_LOG=info,avocam_controller=debug`
  - Shows info level for all dependencies
  - Shows debug level for our app code

- **Verbose dev**: `RUST_LOG=debug`
  - Shows debug level for everything

### Custom Logging Examples

```bash
# Trace level for camera manager only
RUST_LOG=avocam_controller::camera_manager=trace pnpm tauri:dev

# Debug WebSocket and HTTP client
RUST_LOG=tokio_tungstenite=debug,reqwest=debug pnpm tauri:dev

# Debug mDNS discovery
RUST_LOG=mdns_sd=trace pnpm tauri:dev

# Multiple modules
RUST_LOG=info,avocam_controller::camera_client=debug,reqwest=debug pnpm tauri:dev
```

## Where Logs Appear

- **Console output**: Rust logs appear in the terminal where you ran `pnpm tauri:dev`
- **Browser console**: JavaScript/Svelte logs appear in DevTools console
- **Both**: Tauri command errors appear in both places

## Debugging Workflow

1. **Start dev mode**: `pnpm tauri:dev` from project root
2. **Open DevTools**: `Cmd+Opt+I` (macOS) or `F12` (Windows/Linux)
3. **Monitor logs**:
   - Backend logs in terminal
   - Frontend logs in DevTools console
4. **Use Network tab**: Check HTTP/WebSocket communication
5. **Use Elements tab**: Inspect UI components and styling

## Common Debugging Scenarios

### Camera Discovery Issues
```bash
RUST_LOG=mdns_sd=debug,avocam_controller::camera_discovery=debug pnpm tauri:dev
```

### Connection/Network Issues
```bash
RUST_LOG=reqwest=debug,tokio_tungstenite=debug,avocam_controller::camera_client=debug pnpm tauri:dev
```

### State Management Issues
```bash
RUST_LOG=avocam_controller::camera_manager=trace pnpm tauri:dev
```

## Browser DevTools Tips

- **Console**: Filter by log level, search messages
- **Network**: Monitor all HTTP/WS requests, inspect headers/payloads
- **Sources**: Set breakpoints in Svelte/JS code
- **Application**: Inspect localStorage/sessionStorage
- **Performance**: Profile app performance issues

## Tauri-Specific Debugging

### Inspect Tauri Commands
All Tauri command invocations are logged. Check:
- Terminal for Rust-side execution
- DevTools console for invoke calls and responses

### WebView Errors
JavaScript errors in the frontend appear in both:
- Terminal (via Tauri)
- DevTools console (with full stack traces)

## Production Builds

Production builds have DevTools **disabled** and minimal logging for performance.
To debug production-like builds, use:

```bash
cargo build --release
RUST_LOG=warn ./target/release/avocam-controller
```
