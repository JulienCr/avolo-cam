//! Manager for multiple camera clients with group control

use anyhow::{Context, Result};
use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::{RwLock, Semaphore};

use crate::camera_client::CameraClient;
use crate::camera_discovery::CameraDiscovery;
use crate::models::*;

const MAX_CONCURRENT_OPERATIONS: usize = 10;

pub struct CameraManager {
    cameras: HashMap<String, Camera>,
    discovery: Option<CameraDiscovery>,
    operation_semaphore: Arc<Semaphore>,
}

struct Camera {
    info: CameraInfo,
    client: Arc<RwLock<CameraClient>>,
}

impl CameraManager {
    pub fn new() -> Self {
        Self {
            cameras: HashMap::new(),
            discovery: None,
            operation_semaphore: Arc::new(Semaphore::new(MAX_CONCURRENT_OPERATIONS)),
        }
    }

    // MARK: - Discovery

    pub async fn start_discovery(&mut self) -> Result<()> {
        let discovery = CameraDiscovery::new()
            .context("Failed to create camera discovery")?;

        discovery.start_browsing().await
            .context("Failed to start mDNS browsing")?;

        self.discovery = Some(discovery);

        log::info!("Camera discovery started");
        Ok(())
    }

    pub async fn get_discovered_cameras(&self) -> Result<Vec<DiscoveredCamera>> {
        if let Some(discovery) = &self.discovery {
            Ok(discovery.get_discovered().await)
        } else {
            Ok(Vec::new())
        }
    }

    // MARK: - Camera Management

    pub async fn add_camera_manual(&mut self, ip: String, port: u16, token: String) -> Result<String> {
        let id = format!("{}:{}", ip, port);

        // Create client
        let client = CameraClient::new(ip.clone(), port, token.clone());

        // Try to get status to verify connectivity
        let status = client.get_status().await
            .context("Failed to connect to camera")?;

        // Connect WebSocket for telemetry
        let client_arc = Arc::new(RwLock::new(client));
        let id_clone = id.clone();

        client_arc.write().await.connect_websocket(move |telemetry| {
            // Update telemetry in camera info
            // This would require additional synchronization in production
            log::debug!("Received telemetry for {}: FPS={:.1}, Bitrate={}", id_clone, telemetry.fps, telemetry.bitrate);
        }).await
            .context("Failed to connect WebSocket")?;

        // Create camera info
        let info = CameraInfo {
            id: id.clone(),
            alias: status.alias.clone(),
            ip,
            port,
            token,
            status: Some(status),
            connection_state: ConnectionState::Connected,
        };

        // Store camera
        self.cameras.insert(id.clone(), Camera {
            info,
            client: client_arc,
        });

        log::info!("Added camera: {}", id);

        Ok(id)
    }

    pub async fn remove_camera(&mut self, camera_id: &str) -> Result<()> {
        if let Some(camera) = self.cameras.remove(camera_id) {
            // Disconnect WebSocket
            camera.client.read().await.disconnect_websocket().await;
            log::info!("Removed camera: {}", camera_id);
            Ok(())
        } else {
            anyhow::bail!("Camera not found: {}", camera_id);
        }
    }

    pub async fn get_all_cameras(&self) -> Vec<CameraInfo> {
        let mut result = Vec::new();

        for (id, camera) in &self.cameras {
            let mut info = camera.info.clone();

            // Fetch fresh status from camera
            match camera.client.read().await.get_status().await {
                Ok(status) => {
                    info.status = Some(status);
                    info.connection_state = ConnectionState::Connected;
                }
                Err(e) => {
                    log::warn!("Failed to get status for camera {}: {}", id, e);
                    info.connection_state = ConnectionState::Error;
                    // Keep existing status if available
                }
            }

            result.push(info);
        }

        result
    }

    pub async fn update_camera_alias(&mut self, camera_id: &str, alias: String) -> Result<()> {
        if let Some(camera) = self.cameras.get_mut(camera_id) {
            camera.info.alias = alias;
            Ok(())
        } else {
            anyhow::bail!("Camera not found: {}", camera_id);
        }
    }

    // MARK: - Single Camera Operations

    pub async fn get_camera_status(&self, camera_id: &str) -> Result<StatusResponse> {
        let camera = self.cameras.get(camera_id)
            .ok_or_else(|| anyhow::anyhow!("Camera not found: {}", camera_id))?;

        camera.client.read().await.get_status().await
    }

    pub async fn start_stream(&self, camera_id: &str, request: StreamStartRequest) -> Result<()> {
        let camera = self.cameras.get(camera_id)
            .ok_or_else(|| anyhow::anyhow!("Camera not found: {}", camera_id))?;

        camera.client.read().await.start_stream(request).await
    }

    pub async fn stop_stream(&self, camera_id: &str) -> Result<()> {
        let camera = self.cameras.get(camera_id)
            .ok_or_else(|| anyhow::anyhow!("Camera not found: {}", camera_id))?;

        camera.client.read().await.stop_stream().await
    }

    pub async fn update_camera_settings(&self, camera_id: &str, settings: CameraSettingsRequest) -> Result<()> {
        let camera = self.cameras.get(camera_id)
            .ok_or_else(|| anyhow::anyhow!("Camera not found: {}", camera_id))?;

        camera.client.read().await.update_camera_settings(settings).await
    }

    pub async fn force_keyframe(&self, camera_id: &str) -> Result<()> {
        let camera = self.cameras.get(camera_id)
            .ok_or_else(|| anyhow::anyhow!("Camera not found: {}", camera_id))?;

        camera.client.read().await.force_keyframe().await
    }

    pub async fn get_capabilities(&self, camera_id: &str) -> Result<Vec<Capability>> {
        let camera = self.cameras.get(camera_id)
            .ok_or_else(|| anyhow::anyhow!("Camera not found: {}", camera_id))?;

        camera.client.read().await.get_capabilities().await
    }

    // MARK: - Group Operations (Parallel with Bounded Concurrency)

    pub async fn group_start_stream(
        &self,
        camera_ids: &[String],
        request: StreamStartRequest,
    ) -> Result<Vec<GroupCommandResult>> {
        self.execute_group_operation(camera_ids, move |client| {
            let req = request.clone();
            async move {
                client.read().await.start_stream(req).await
            }
        }).await
    }

    pub async fn group_stop_stream(
        &self,
        camera_ids: &[String],
    ) -> Result<Vec<GroupCommandResult>> {
        self.execute_group_operation(camera_ids, |client| {
            async move {
                client.read().await.stop_stream().await
            }
        }).await
    }

    pub async fn group_update_settings(
        &self,
        camera_ids: &[String],
        settings: CameraSettingsRequest,
    ) -> Result<Vec<GroupCommandResult>> {
        self.execute_group_operation(camera_ids, move |client| {
            let settings = settings.clone();
            async move {
                client.read().await.update_camera_settings(settings).await
            }
        }).await
    }

    // Generic group operation executor with bounded concurrency
    async fn execute_group_operation<F, Fut>(
        &self,
        camera_ids: &[String],
        operation: F,
    ) -> Result<Vec<GroupCommandResult>>
    where
        F: Fn(Arc<RwLock<CameraClient>>) -> Fut + Send + Sync + 'static,
        Fut: std::future::Future<Output = Result<()>> + Send,
    {
        let operation = Arc::new(operation);
        let mut tasks = Vec::new();

        for camera_id in camera_ids {
            let camera_id_owned = camera_id.clone();
            let camera = match self.cameras.get(camera_id) {
                Some(c) => c,
                None => {
                    // Camera not found, add error result
                    let error_msg = format!("Camera not found: {}", camera_id_owned);
                    tasks.push(tokio::spawn(async move {
                        GroupCommandResult {
                            camera_id: camera_id_owned,
                            success: false,
                            error: Some(error_msg),
                        }
                    }));
                    continue;
                }
            };

            let client = camera.client.clone();
            let camera_id = camera_id.clone();
            let operation = operation.clone();
            let semaphore = self.operation_semaphore.clone();

            // Spawn task with semaphore for bounded concurrency
            tasks.push(tokio::spawn(async move {
                // Acquire semaphore permit
                let _permit = semaphore.acquire().await.unwrap();

                // Execute operation
                let result = operation(client).await;

                // Return result
                GroupCommandResult {
                    camera_id: camera_id.clone(),
                    success: result.is_ok(),
                    error: result.err().map(|e| e.to_string()),
                }
            }));
        }

        // Wait for all tasks to complete
        let mut results = Vec::new();
        for task in tasks {
            match task.await {
                Ok(result) => results.push(result),
                Err(e) => {
                    log::error!("Group operation task failed: {}", e);
                }
            }
        }

        Ok(results)
    }
}

impl Drop for CameraManager {
    fn drop(&mut self) {
        // Clean up cameras
        for (_, _camera) in self.cameras.drain() {
            // WebSocket disconnection happens in camera client drop
        }

        // Stop discovery
        if let Some(discovery) = &self.discovery {
            discovery.stop();
        }
    }
}
