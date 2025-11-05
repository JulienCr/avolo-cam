# SwiftNIO Server Testing Guide

## Overview

The NetworkServer implementation provides:
- HTTP REST API on port 8888
- WebSocket connections for real-time telemetry
- Bearer token authentication
- Rate limiting for camera settings
- Concurrent request handling

## Architecture

### Components

1. **NetworkServer** - Main server class that manages:
   - SwiftNIO EventLoopGroup and ServerBootstrap
   - HTTP request routing
   - WebSocket client connections
   - Telemetry broadcasting

2. **HTTPServerHandler** - Channel handler for HTTP requests:
   - Parses HTTP request parts (head, body, end)
   - Detects WebSocket upgrade requests
   - Routes to appropriate endpoints
   - Sends HTTP responses

3. **WebSocketServerHandler** - Channel handler for WebSocket connections:
   - Manages WebSocket frame encoding/decoding
   - Handles ping/pong keepalive
   - Processes text and binary frames
   - Receives camera control commands

4. **WebSocketClient** - Wrapper for WebSocket channels:
   - Sends telemetry updates
   - Manages connection lifecycle

## Testing HTTP Endpoints

### Prerequisites
1. iOS app running on device or simulator
2. Note the bearer token from app logs or settings
3. Device/simulator accessible on network

### Test Status Endpoint

```bash
# Get current camera status
curl -X GET http://<device-ip>:8888/api/v1/status \
  -H "Authorization: Bearer <token>"

# Expected response:
{
  "alias": "AVOLO-CAM-XX",
  "ndi_state": "idle",
  "current": {
    "resolution": "1920x1080",
    "fps": 30,
    "bitrate": 10000000,
    "codec": "h264",
    "wb_mode": "auto",
    "wb_kelvin": null,
    "iso": 0,
    "shutter_s": 0.0,
    "focus_mode": "auto",
    "zoom_factor": 1.0
  },
  "telemetry": {
    "fps": 0.0,
    "bitrate": 0,
    "battery": 1.0,
    "temp_c": 25.0,
    "wifi_rssi": -50
  },
  "capabilities": [...]
}
```

### Test Capabilities Endpoint

```bash
curl -X GET http://<device-ip>:8888/api/v1/capabilities \
  -H "Authorization: Bearer <token>"
```

### Test Stream Start

```bash
curl -X POST http://<device-ip>:8888/api/v1/stream/start \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  -d '{
    "resolution": "1920x1080",
    "framerate": 30,
    "bitrate": 10000000,
    "codec": "h264"
  }'

# Expected response:
{"success": true, "message": "Stream started"}
```

### Test Stream Stop

```bash
curl -X POST http://<device-ip>:8888/api/v1/stream/stop \
  -H "Authorization: Bearer <token>"

# Expected response:
{"success": true, "message": "Stream stopped"}
```

### Test Camera Settings

```bash
curl -X POST http://<device-ip>:8888/api/v1/camera \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  -d '{
    "wb_mode": "manual",
    "wb_kelvin": 5000,
    "iso": 400,
    "zoom_factor": 2.0
  }'

# Expected response:
{"success": true, "message": "Camera settings updated"}
```

### Test Force Keyframe

```bash
curl -X POST http://<device-ip>:8888/api/v1/encoder/force_keyframe \
  -H "Authorization: Bearer <token>"

# Expected response:
{"success": true, "message": "Keyframe forced"}
```

### Test Authentication

```bash
# Without token - should return 401
curl -X GET http://<device-ip>:8888/api/v1/status

# With invalid token - should return 401
curl -X GET http://<device-ip>:8888/api/v1/status \
  -H "Authorization: Bearer invalid-token"

# Expected response:
{"code": "UNAUTHORIZED", "message": "Invalid or missing bearer token"}
```

### Test Rate Limiting

```bash
# Send multiple camera updates rapidly
for i in {1..10}; do
  curl -X POST http://<device-ip>:8888/api/v1/camera \
    -H "Authorization: Bearer <token>" \
    -H "Content-Type: application/json" \
    -d '{"iso": 400}'
done

# Some requests should return 429
{"code": "RATE_LIMITED", "message": "Too many camera updates, wait 50ms"}
```

### Test Web UI

```bash
# Access web interface
curl http://<device-ip>:8888/

# Or open in browser:
open http://<device-ip>:8888/
```

## Testing WebSocket Connection

### Using wscat (Node.js)

```bash
# Install wscat
npm install -g wscat

# Connect to WebSocket
wscat -c ws://<device-ip>:8888/ws

# You should immediately start receiving telemetry updates every second:
{
  "fps": 29.97,
  "bitrate": 9800000,
  "queue_ms": 5,
  "battery": 0.82,
  "temp_c": 38.4,
  "wifi_rssi": -55,
  "ndi_state": "streaming",
  "dropped_frames": 0,
  "charging_state": "unplugged"
}

# Send camera control command:
{"op": "set", "camera": {"iso": 800, "wb_mode": "manual", "wb_kelvin": 5000}}
```

### Using Python

```python
import asyncio
import websockets
import json

async def test_websocket():
    uri = "ws://<device-ip>:8888/ws"

    async with websockets.connect(uri) as websocket:
        # Receive telemetry
        for i in range(10):
            message = await websocket.recv()
            telemetry = json.loads(message)
            print(f"Telemetry: fps={telemetry['fps']}, "
                  f"bitrate={telemetry['bitrate']}, "
                  f"battery={telemetry['battery']}")

        # Send camera command
        command = {
            "op": "set",
            "camera": {
                "iso": 800,
                "zoom_factor": 1.5
            }
        }
        await websocket.send(json.dumps(command))

        # Continue receiving
        message = await websocket.recv()
        print(f"After command: {message}")

asyncio.run(test_websocket())
```

### Using JavaScript (Browser)

```javascript
const ws = new WebSocket('ws://<device-ip>:8888/ws');

ws.onopen = () => {
    console.log('Connected to AvoCam');
};

ws.onmessage = (event) => {
    const telemetry = JSON.parse(event.data);
    console.log('Telemetry:', telemetry);

    // Update UI with telemetry data
    document.getElementById('fps').textContent = telemetry.fps.toFixed(2);
    document.getElementById('bitrate').textContent =
        (telemetry.bitrate / 1000000).toFixed(1) + ' Mbps';
    document.getElementById('battery').textContent =
        (telemetry.battery * 100).toFixed(0) + '%';
    document.getElementById('temp').textContent =
        telemetry.temp_c.toFixed(1) + '°C';
};

ws.onerror = (error) => {
    console.error('WebSocket error:', error);
};

ws.onclose = () => {
    console.log('Disconnected from AvoCam');
};

// Send camera command
function updateCamera(settings) {
    ws.send(JSON.stringify({
        op: 'set',
        camera: settings
    }));
}

// Example usage:
updateCamera({ iso: 800, zoom_factor: 2.0 });
```

## Performance Testing

### Concurrent HTTP Requests

```bash
# Install Apache Bench
# apt-get install apache2-utils (Linux)
# brew install apache2 (macOS)

# Test concurrent requests
ab -n 100 -c 10 \
  -H "Authorization: Bearer <token>" \
  http://<device-ip>:8888/api/v1/status

# Monitor response times and throughput
```

### Multiple WebSocket Clients

```bash
# Connect multiple clients simultaneously
for i in {1..5}; do
  (wscat -c ws://<device-ip>:8888/ws &)
done

# Verify all clients receive telemetry updates
```

### Load Testing

```python
import asyncio
import aiohttp
import time

async def benchmark_http(session, url, token, n_requests):
    headers = {'Authorization': f'Bearer {token}'}

    start = time.time()
    tasks = []

    for _ in range(n_requests):
        tasks.append(session.get(url, headers=headers))

    responses = await asyncio.gather(*tasks)
    elapsed = time.time() - start

    success = sum(1 for r in responses if r.status == 200)
    print(f"Completed {success}/{n_requests} requests in {elapsed:.2f}s")
    print(f"Throughput: {n_requests/elapsed:.2f} req/s")

async def main():
    url = "http://<device-ip>:8888/api/v1/status"
    token = "<your-token>"

    async with aiohttp.ClientSession() as session:
        await benchmark_http(session, url, token, 100)

asyncio.run(main())
```

## Troubleshooting

### Server Won't Start

1. Check port 8888 is not already in use:
   ```bash
   lsof -i :8888
   ```

2. Verify network permissions in Info.plist:
   - NSLocalNetworkUsageDescription
   - NSAppTransportSecurity settings

3. Check iOS device logs for errors:
   - Xcode -> Window -> Devices and Simulators -> View Device Logs

### WebSocket Connection Fails

1. Verify HTTP endpoint works first
2. Check for proxy or firewall blocking WebSocket
3. Ensure WebSocket upgrade headers are correct:
   ```
   Upgrade: websocket
   Connection: Upgrade
   Sec-WebSocket-Key: <base64-key>
   ```

### Authentication Errors

1. Verify bearer token from app logs
2. Check Authorization header format:
   ```
   Authorization: Bearer <token-without-spaces>
   ```
3. Token is case-sensitive

### Rate Limiting Triggered

1. Check requests are spaced 50ms+ apart for camera settings
2. Reduce request frequency
3. Batch multiple settings into single request

### No Telemetry Updates

1. Verify WebSocket connection established
2. Check encoder is running (stream started)
3. Monitor app logs for telemetry collection errors

## Monitoring

### Server Metrics

Monitor these metrics during operation:

- Active WebSocket connections
- HTTP request rate
- Response times
- Error rates (401, 429, 500)
- Memory usage
- CPU usage

### Logging

The server logs important events:

- `🌐 Starting HTTP/WebSocket server on port 8888`
- `✅ Server started on port 8888`
- `🔌 WebSocket client connected (total: N)`
- `🔌 WebSocket client disconnected (total: N)`
- `🔌 WebSocket upgrade complete`
- `📥 WS camera command: {...}`
- `❌ HTTP handler error: ...`
- `❌ WebSocket handler error: ...`

### Common Error Codes

- **401 Unauthorized** - Missing or invalid bearer token
- **400 Bad Request** - Invalid JSON or request format
- **404 Not Found** - Endpoint doesn't exist
- **429 Too Many Requests** - Rate limit exceeded
- **500 Internal Server Error** - Server-side error
- **501 Not Implemented** - Feature not yet implemented

## Integration with OBS

Once streaming is active, add NDI source in OBS:

1. Sources -> Add -> NDI Source
2. Select "AVOLO-CAM-XX" from source list
3. Configure:
   - Bandwidth: Highest
   - Sync: Internal
4. Verify video appears with correct color space

## Next Steps

1. Test all endpoints systematically
2. Verify WebSocket telemetry updates
3. Load test with multiple concurrent connections
4. Integrate with Tauri controller for multi-camera management
5. Implement logs download endpoint
6. Add enhanced web UI

## Implementation Notes

### SwiftNIO Pipeline

```
Channel Pipeline:
1. SocketChannel
2. HTTPServerRequestDecoder (automatic)
3. HTTPServerResponseEncoder (automatic)
4. HTTPServerHandler (custom)

On WebSocket upgrade:
1. Remove HTTPServerHandler
2. Add WebSocketFrameEncoder
3. Add WebSocketFrameDecoder
4. Add WebSocketServerHandler (custom)
```

### Thread Safety

- WebSocket clients array protected by NSLock
- Async/await used for request handling
- EventLoop guarantees for channel operations

### Memory Management

- Weak self references in closures
- Proper cleanup in stop() method
- Channel handlers removed on disconnect
