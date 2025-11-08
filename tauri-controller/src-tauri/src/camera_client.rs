//! HTTP and WebSocket client for camera communication

use anyhow::{Context, Result};
use reqwest::Client;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::{mpsc, RwLock};
use tokio_tungstenite::{connect_async, tungstenite::Message};
use futures_util::StreamExt;

use crate::models::*;

const HTTP_TIMEOUT: Duration = Duration::from_secs(5);
const WS_RECONNECT_DELAY: Duration = Duration::from_secs(2);
const MAX_RECONNECT_ATTEMPTS: u32 = 100; // High limit, effectively unlimited
const MAX_RECONNECT_DELAY: Duration = Duration::from_secs(30); // Cap backoff at 30s

pub struct CameraClient {
    base_url: String,
    token: String,
    http_client: Client,
    ws_tx: Option<mpsc::UnboundedSender<WebSocketTelemetryMessage>>,
    connected: Arc<RwLock<bool>>,
}

impl CameraClient {
    pub fn new(ip: String, port: u16, token: String) -> Self {
        let base_url = format!("http://{}:{}", ip, port);

        let http_client = Client::builder()
            .timeout(HTTP_TIMEOUT)
            .build()
            .expect("Failed to create HTTP client");

        Self {
            base_url,
            token,
            http_client,
            ws_tx: None,
            connected: Arc::new(RwLock::new(false)),
        }
    }

    // MARK: - HTTP Requests

    async fn get(&self, path: &str) -> Result<reqwest::Response> {
        self.http_client
            .get(format!("{}{}", self.base_url, path))
            .header("Authorization", format!("Bearer {}", self.token))
            .send()
            .await
            .context("HTTP GET request failed")
    }

    async fn post<T: serde::Serialize>(&self, path: &str, body: &T) -> Result<reqwest::Response> {
        self.http_client
            .post(format!("{}{}", self.base_url, path))
            .header("Authorization", format!("Bearer {}", self.token))
            .json(body)
            .send()
            .await
            .context("HTTP POST request failed")
    }

    // MARK: - API Methods

    pub async fn get_status(&self) -> Result<StatusResponse> {
        let response = self.get("/api/v1/status").await?;

        if !response.status().is_success() {
            let error: ErrorResponse = response.json().await
                .context("Failed to parse error response")?;
            anyhow::bail!("{}: {}", error.code, error.message);
        }

        response.json().await
            .context("Failed to parse status response")
    }

    pub async fn get_capabilities(&self) -> Result<Vec<Capability>> {
        let response = self.get("/api/v1/capabilities").await?;

        if !response.status().is_success() {
            let error: ErrorResponse = response.json().await
                .context("Failed to parse error response")?;
            anyhow::bail!("{}: {}", error.code, error.message);
        }

        response.json().await
            .context("Failed to parse capabilities response")
    }

    pub async fn start_stream(&self, request: StreamStartRequest) -> Result<()> {
        let response = self.post("/api/v1/stream/start", &request).await?;

        if !response.status().is_success() {
            let error: ErrorResponse = response.json().await
                .context("Failed to parse error response")?;
            anyhow::bail!("{}: {}", error.code, error.message);
        }

        Ok(())
    }

    pub async fn stop_stream(&self) -> Result<()> {
        let response = self.post("/api/v1/stream/stop", &()).await?;

        if !response.status().is_success() {
            let error: ErrorResponse = response.json().await
                .context("Failed to parse error response")?;
            anyhow::bail!("{}: {}", error.code, error.message);
        }

        Ok(())
    }

    pub async fn update_camera_settings(&self, settings: CameraSettingsRequest) -> Result<()> {
        let response = self.post("/api/v1/camera", &settings).await?;

        if !response.status().is_success() {
            let error: ErrorResponse = response.json().await
                .context("Failed to parse error response")?;
            anyhow::bail!("{}: {}", error.code, error.message);
        }

        Ok(())
    }

    pub async fn measure_white_balance(&self) -> Result<WhiteBalanceMeasureResponse> {
        let response = self.post("/api/v1/camera/wb/measure", &()).await?;

        if !response.status().is_success() {
            let error: ErrorResponse = response.json().await
                .context("Failed to parse error response")?;
            anyhow::bail!("{}: {}", error.code, error.message);
        }

        response.json().await
            .context("Failed to parse white balance measure response")
    }

    // MARK: - WebSocket

    pub async fn connect_websocket(
        &mut self,
        telemetry_callback: impl Fn(WebSocketTelemetryMessage) + Send + Sync + 'static,
    ) -> Result<()> {
        let ws_url = self.base_url.replace("http://", "ws://") + "/ws";
        let token = self.token.clone();
        let connected = self.connected.clone();

        let (tx, mut rx) = mpsc::unbounded_channel();
        self.ws_tx = Some(tx);

        // Spawn WebSocket connection task with reconnection logic
        tokio::spawn(async move {
            let mut reconnect_attempts = 0;

            loop {
                log::info!("Connecting to WebSocket: {}", ws_url);

                match connect_websocket_internal(&ws_url, &token, &telemetry_callback).await {
                    Ok(_) => {
                        log::info!("WebSocket connection ended normally");
                        reconnect_attempts = 0;
                    }
                    Err(e) => {
                        log::error!("WebSocket connection error: {}", e);
                        reconnect_attempts += 1;

                        if reconnect_attempts >= MAX_RECONNECT_ATTEMPTS {
                            log::error!("Max reconnection attempts reached, giving up");
                            *connected.write().await = false;
                            break;
                        }
                    }
                }

                // Exponential backoff with cap
                let backoff_multiplier = 2_u32.pow(reconnect_attempts.min(5));
                let calculated_delay = WS_RECONNECT_DELAY * backoff_multiplier;
                let delay = calculated_delay.min(MAX_RECONNECT_DELAY);
                log::info!("Reconnecting in {:?} (attempt {}/{})", delay, reconnect_attempts, MAX_RECONNECT_ATTEMPTS);
                tokio::time::sleep(delay).await;

                // Check if we should stop reconnecting
                if let Ok(_) = rx.try_recv() {
                    log::info!("Stop signal received, ending WebSocket reconnection");
                    break;
                }
            }
        });

        *self.connected.write().await = true;

        Ok(())
    }

    pub async fn disconnect_websocket(&self) {
        *self.connected.write().await = false;
        // Send stop signal through channel if available
    }

    pub async fn is_connected(&self) -> bool {
        *self.connected.read().await
    }
}

// Internal WebSocket connection handler
async fn connect_websocket_internal<F>(
    ws_url: &str,
    token: &str,
    telemetry_callback: &F,
) -> Result<()>
where
    F: Fn(WebSocketTelemetryMessage) + Send + Sync + 'static,
{
    // Build request with Authorization header (Bearer token)
    use tokio_tungstenite::tungstenite::http::Request;

    let request = Request::builder()
        .uri(ws_url)
        .header("Host", ws_url.split("//").nth(1).unwrap_or(ws_url).split('/').next().unwrap_or(ws_url))
        .header("Connection", "Upgrade")
        .header("Upgrade", "websocket")
        .header("Sec-WebSocket-Version", "13")
        .header("Sec-WebSocket-Key", tokio_tungstenite::tungstenite::handshake::client::generate_key())
        .header("Authorization", format!("Bearer {}", token))
        .body(())
        .context("Failed to build WebSocket request")?;

    log::info!("Connecting to WebSocket: {}", ws_url);
    log::debug!("Authorization: Bearer {}", token);

    let (ws_stream, response) = connect_async(request).await
        .context("Failed to connect to WebSocket")?;

    log::info!("WebSocket connected successfully: {} (status: {})", ws_url, response.status());

    let (_write, mut read) = ws_stream.split();

    // Read messages from WebSocket
    while let Some(msg) = read.next().await {
        match msg {
            Ok(Message::Text(text)) => {
                // Parse telemetry message
                match serde_json::from_str::<WebSocketTelemetryMessage>(&text) {
                    Ok(telemetry) => {
                        telemetry_callback(telemetry);
                    }
                    Err(e) => {
                        log::warn!("Failed to parse WebSocket message: {}", e);
                    }
                }
            }
            Ok(Message::Close(_)) => {
                log::info!("WebSocket closed by server");
                break;
            }
            Ok(Message::Ping(_)) => {
                // Pong is sent automatically by tungstenite
            }
            Ok(_) => {}
            Err(e) => {
                log::error!("WebSocket error: {}", e);
                return Err(e.into());
            }
        }
    }

    Ok(())
}
