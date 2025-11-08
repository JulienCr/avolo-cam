//! Manager for multiple camera clients with group control

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;
use tokio::sync::{RwLock, Semaphore};

use crate::camera_client::CameraClient;
use crate::camera_discovery::CameraDiscovery;
use crate::models::*;

const MAX_CONCURRENT_OPERATIONS: usize = 10;

// MARK: - Persistence

#[derive(Debug, Clone, Serialize, Deserialize)]
struct PersistedCamera {
    id: String,
    alias: String,
    ip: String,
    port: u16,
    token: String,
}

impl PersistedCamera {
    fn from_camera_info(info: &CameraInfo) -> Self {
        Self {
            id: info.id.clone(),
            alias: info.alias.clone(),
            ip: info.ip.clone(),
            port: info.port,
            token: info.token.clone(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct CamerasPersistence {
    cameras: Vec<PersistedCamera>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct ProfilesPersistence {
    profiles: Vec<CameraProfile>,
}

pub struct CameraManager {
    cameras: HashMap<String, Camera>,
    discovery: Option<CameraDiscovery>,
    operation_semaphore: Arc<Semaphore>,
    persistence_file_path: Option<PathBuf>,
    profiles_file_path: Option<PathBuf>,
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
            persistence_file_path: None,
            profiles_file_path: None,
        }
    }

    /// Set the persistence file path and load any saved cameras
    pub async fn set_persistence_path(&mut self, path: PathBuf) -> Result<()> {
        self.persistence_file_path = Some(path.clone());

        // Set profiles path in same directory
        let profiles_path = path.parent()
            .ok_or_else(|| anyhow::anyhow!("Invalid persistence path"))?
            .join("profiles.json");
        self.profiles_file_path = Some(profiles_path);

        self.load_cameras_from_disk().await?;
        Ok(())
    }

    /// Save all cameras to disk
    async fn save_cameras_to_disk(&self) -> Result<()> {
        let Some(path) = &self.persistence_file_path else {
            return Ok(()); // No persistence path set
        };

        let persisted_cameras: Vec<PersistedCamera> = self.cameras
            .values()
            .map(|camera| PersistedCamera::from_camera_info(&camera.info))
            .collect();

        let persistence = CamerasPersistence {
            cameras: persisted_cameras,
        };

        let json = serde_json::to_string_pretty(&persistence)
            .context("Failed to serialize cameras")?;

        tokio::fs::write(path, json).await
            .context("Failed to write cameras to disk")?;

        log::info!("Saved {} cameras to {:?}", persistence.cameras.len(), path);
        Ok(())
    }

    /// Load cameras from disk and add them to the manager
    async fn load_cameras_from_disk(&mut self) -> Result<()> {
        let Some(path) = &self.persistence_file_path else {
            return Ok(()); // No persistence path set
        };

        if !path.exists() {
            log::info!("No cameras file found at {:?}, starting fresh", path);
            return Ok(());
        }

        let json = tokio::fs::read_to_string(path).await
            .context("Failed to read cameras file")?;

        let persistence: CamerasPersistence = serde_json::from_str(&json)
            .context("Failed to deserialize cameras")?;

        log::info!("Loading {} cameras from {:?}", persistence.cameras.len(), path);

        for persisted in persistence.cameras {
            // Try to add camera, but don't fail if one camera fails
            match self.add_camera_manual(persisted.ip, persisted.port, persisted.token).await {
                Ok(id) => {
                    log::info!("Loaded camera: {} ({})", persisted.alias, id);
                }
                Err(e) => {
                    log::warn!("Failed to load camera {}: {}", persisted.alias, e);
                }
            }
        }

        Ok(())
    }

    // MARK: - Profile Management

    /// Save a camera settings profile
    pub async fn save_profile(&mut self, name: String, settings: CameraSettingsRequest) -> Result<()> {
        let Some(path) = &self.profiles_file_path else {
            anyhow::bail!("Profiles path not set");
        };

        // Load existing profiles
        let mut profiles = self.load_profiles_from_disk().await.unwrap_or_default();

        // Check if profile with this name already exists
        if let Some(existing) = profiles.iter_mut().find(|p| p.name == name) {
            // Update existing profile
            existing.settings = settings;
            log::info!("Updated existing profile: {}", name);
        } else {
            // Add new profile
            profiles.push(CameraProfile { name: name.clone(), settings });
            log::info!("Created new profile: {}", name);
        }

        // Save to disk
        let persistence = ProfilesPersistence { profiles };
        let json = serde_json::to_string_pretty(&persistence)
            .context("Failed to serialize profiles")?;

        tokio::fs::write(path, json).await
            .context("Failed to write profiles to disk")?;

        log::info!("Saved profiles to {:?}", path);
        Ok(())
    }

    /// Get all saved profiles
    pub async fn get_profiles(&self) -> Result<Vec<CameraProfile>> {
        self.load_profiles_from_disk().await
    }

    /// Delete a profile by name
    pub async fn delete_profile(&mut self, name: &str) -> Result<()> {
        let Some(path) = &self.profiles_file_path else {
            anyhow::bail!("Profiles path not set");
        };

        // Load existing profiles
        let mut profiles = self.load_profiles_from_disk().await.unwrap_or_default();

        // Remove the profile
        let initial_len = profiles.len();
        profiles.retain(|p| p.name != name);

        if profiles.len() == initial_len {
            anyhow::bail!("Profile not found: {}", name);
        }

        // Save updated list
        let persistence = ProfilesPersistence { profiles };
        let json = serde_json::to_string_pretty(&persistence)
            .context("Failed to serialize profiles")?;

        tokio::fs::write(path, json).await
            .context("Failed to write profiles to disk")?;

        log::info!("Deleted profile: {}", name);
        Ok(())
    }

    /// Apply a profile to selected cameras
    pub async fn apply_profile(&self, profile_name: &str, camera_ids: &[String]) -> Result<Vec<GroupCommandResult>> {
        // Load profile
        let profiles = self.load_profiles_from_disk().await?;
        let profile = profiles.iter()
            .find(|p| p.name == profile_name)
            .ok_or_else(|| anyhow::anyhow!("Profile not found: {}", profile_name))?;

        // Apply settings to all selected cameras
        self.group_update_settings(camera_ids, profile.settings.clone()).await
    }

    /// Load profiles from disk
    async fn load_profiles_from_disk(&self) -> Result<Vec<CameraProfile>> {
        let Some(path) = &self.profiles_file_path else {
            return Ok(Vec::new());
        };

        if !path.exists() {
            log::info!("No profiles file found at {:?}, starting fresh", path);
            return Ok(Vec::new());
        }

        let json = tokio::fs::read_to_string(path).await
            .context("Failed to read profiles file")?;

        let persistence: ProfilesPersistence = serde_json::from_str(&json)
            .context("Failed to deserialize profiles")?;

        log::info!("Loaded {} profiles from {:?}", persistence.profiles.len(), path);
        Ok(persistence.profiles)
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

        // Persist to disk
        if let Err(e) = self.save_cameras_to_disk().await {
            log::warn!("Failed to save cameras to disk: {}", e);
        }

        Ok(id)
    }

    pub async fn remove_camera(&mut self, camera_id: &str) -> Result<()> {
        if let Some(camera) = self.cameras.remove(camera_id) {
            // Disconnect WebSocket
            camera.client.write().await.disconnect_websocket().await;
            log::info!("Removed camera: {}", camera_id);

            // Persist to disk
            if let Err(e) = self.save_cameras_to_disk().await {
                log::warn!("Failed to save cameras to disk: {}", e);
            }

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

    pub async fn get_capabilities(&self, camera_id: &str) -> Result<Vec<Capability>> {
        let camera = self.cameras.get(camera_id)
            .ok_or_else(|| anyhow::anyhow!("Camera not found: {}", camera_id))?;

        camera.client.read().await.get_capabilities().await
    }

    pub async fn measure_white_balance(&self, camera_id: &str) -> Result<WhiteBalanceMeasureResponse> {
        let camera = self.cameras.get(camera_id)
            .ok_or_else(|| anyhow::anyhow!("Camera not found: {}", camera_id))?;

        camera.client.read().await.measure_white_balance().await
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
