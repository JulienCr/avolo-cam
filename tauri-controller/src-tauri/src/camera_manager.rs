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
    // Persisted stream settings (optional for backward compatibility)
    stream_settings: Option<StreamStartRequest>,
    // Persisted camera settings (optional for backward compatibility)
    camera_settings: Option<CameraSettingsRequest>,
}

impl PersistedCamera {
    fn from_camera_info(info: &CameraInfo) -> Self {
        // Extract current settings from status if available
        let (stream_settings, camera_settings) = if let Some(ref status) = info.status {
            let stream = StreamStartRequest {
                resolution: status.current.resolution.clone(),
                framerate: status.current.fps,
                bitrate: status.current.bitrate,
                codec: status.current.codec.clone(),
            };

            let camera = CameraSettingsRequest {
                wb_mode: Some(status.current.wb_mode),
                wb_kelvin: status.current.wb_kelvin,
                wb_tint: status.current.wb_tint,
                iso_mode: Some(status.current.iso_mode),
                iso: Some(status.current.iso),
                shutter_mode: Some(status.current.shutter_mode),
                shutter_s: Some(status.current.shutter_s),
                focus_mode: Some(status.current.focus_mode),
                zoom_factor: Some(status.current.zoom_factor),
                lens: Some(status.current.lens.clone()),
                camera_position: Some(status.current.camera_position.clone()),
                orientation_lock: None,
                torch_level: None, // Not stored in CurrentSettings
            };

            (Some(stream), Some(camera))
        } else {
            (None, None)
        };

        Self {
            id: info.id.clone(),
            alias: info.alias.clone(),
            ip: info.ip.clone(),
            port: info.port,
            token: info.token.clone(),
            stream_settings,
            camera_settings,
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
    settings_file_path: Option<PathBuf>,
    // Store persisted settings for each camera (keyed by camera_id)
    persisted_settings: HashMap<String, (Option<StreamStartRequest>, Option<CameraSettingsRequest>)>,
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
            settings_file_path: None,
            persisted_settings: HashMap::new(),
        }
    }

    /// Set the persistence file path and load any saved cameras
    pub async fn set_persistence_path(&mut self, path: PathBuf) -> Result<()> {
        self.persistence_file_path = Some(path.clone());

        // Set profiles and settings paths in same directory
        let parent_dir = path.parent()
            .ok_or_else(|| anyhow::anyhow!("Invalid persistence path"))?;

        self.profiles_file_path = Some(parent_dir.join("profiles.json"));
        self.settings_file_path = Some(parent_dir.join("settings.json"));

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
            let camera_id = persisted.id.clone();
            let stream_settings = persisted.stream_settings.clone();
            let camera_settings = persisted.camera_settings.clone();

            // Try to add camera, but don't fail if one camera fails
            match self.add_camera_manual(persisted.ip, persisted.port, persisted.token).await {
                Ok(id) => {
                    log::info!("Loaded camera: {} ({})", persisted.alias, id);

                    // Store persisted settings for this camera
                    if stream_settings.is_some() || camera_settings.is_some() {
                        self.persisted_settings.insert(camera_id, (stream_settings, camera_settings));
                        log::info!("Stored persisted settings for camera: {}", id);
                    }
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
    pub async fn apply_profile(&mut self, profile_name: &str, camera_ids: &[String]) -> Result<Vec<GroupCommandResult>> {
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

    // MARK: - App Settings Management

    /// Get app settings from disk (or defaults if not found)
    pub async fn get_app_settings(&self) -> Result<AppSettings> {
        let Some(path) = &self.settings_file_path else {
            log::warn!("Settings path not set, returning defaults");
            return Ok(AppSettings::default());
        };

        if !path.exists() {
            log::info!("No settings file found at {:?}, returning defaults", path);
            return Ok(AppSettings::default());
        }

        let json = tokio::fs::read_to_string(path).await
            .context("Failed to read settings file")?;

        let settings: AppSettings = serde_json::from_str(&json)
            .context("Failed to deserialize settings")?;

        log::info!("Loaded app settings from {:?}", path);
        Ok(settings)
    }

    /// Save app settings to disk
    pub async fn save_app_settings(&mut self, settings: AppSettings) -> Result<()> {
        let Some(path) = &self.settings_file_path else {
            anyhow::bail!("Settings path not set");
        };

        let json = serde_json::to_string_pretty(&settings)
            .context("Failed to serialize settings")?;

        tokio::fs::write(path, json).await
            .context("Failed to write settings to disk")?;

        log::info!("Saved app settings to {:?}", path);
        Ok(())
    }

    /// Delete cameras.json file (useful for resetting the app)
    pub async fn delete_cameras_data(&mut self) -> Result<()> {
        let Some(path) = &self.persistence_file_path else {
            anyhow::bail!("Cameras persistence path not set");
        };

        if path.exists() {
            tokio::fs::remove_file(path).await
                .context("Failed to delete cameras file")?;
            log::info!("Deleted cameras data file: {:?}", path);
        } else {
            log::info!("Cameras data file does not exist: {:?}", path);
        }

        // Clear in-memory cameras
        self.cameras.clear();

        Ok(())
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
            //log::debug!("Received telemetry for {}: FPS={:.1}, Bitrate={}", id_clone, telemetry.fps, telemetry.bitrate);
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
            camera.info.alias = alias.clone();
            log::info!("Updated camera {} alias to: {}", camera_id, alias);

            // Persist to disk
            if let Err(e) = self.save_cameras_to_disk().await {
                log::warn!("Failed to save cameras to disk after alias update: {}", e);
            }

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

    pub async fn start_stream(&mut self, camera_id: &str, request: StreamStartRequest) -> Result<()> {
        let camera = self.cameras.get(camera_id)
            .ok_or_else(|| anyhow::anyhow!("Camera not found: {}", camera_id))?;

        // Store settings in persisted_settings before starting stream
        self.persisted_settings
            .entry(camera_id.to_string())
            .and_modify(|(stream, _)| *stream = Some(request.clone()))
            .or_insert((Some(request.clone()), None));

        camera.client.read().await.start_stream(request).await?;

        // Save to disk after successful start
        if let Err(e) = self.save_cameras_to_disk().await {
            log::warn!("Failed to save cameras to disk after starting stream: {}", e);
        }

        Ok(())
    }

    pub async fn stop_stream(&self, camera_id: &str) -> Result<()> {
        let camera = self.cameras.get(camera_id)
            .ok_or_else(|| anyhow::anyhow!("Camera not found: {}", camera_id))?;

        camera.client.read().await.stop_stream().await
    }

    pub async fn update_camera_settings(&mut self, camera_id: &str, settings: CameraSettingsRequest) -> Result<()> {
        let camera = self.cameras.get(camera_id)
            .ok_or_else(|| anyhow::anyhow!("Camera not found: {}", camera_id))?;

        // Store settings in persisted_settings before updating camera
        self.persisted_settings
            .entry(camera_id.to_string())
            .and_modify(|(_, camera)| *camera = Some(settings.clone()))
            .or_insert((None, Some(settings.clone())));

        camera.client.read().await.update_camera_settings(settings).await?;

        // Save to disk after successful update
        if let Err(e) = self.save_cameras_to_disk().await {
            log::warn!("Failed to save cameras to disk after updating settings: {}", e);
        }

        Ok(())
    }

    /// Update stream settings for a camera (persists to disk but doesn't start stream)
    pub async fn update_stream_settings(&mut self, camera_id: &str, settings: StreamStartRequest) -> Result<()> {
        // Verify camera exists
        if !self.cameras.contains_key(camera_id) {
            anyhow::bail!("Camera not found: {}", camera_id);
        }

        // Store settings in persisted_settings
        self.persisted_settings
            .entry(camera_id.to_string())
            .and_modify(|(stream, _)| *stream = Some(settings.clone()))
            .or_insert((Some(settings.clone()), None));

        // Save to disk
        if let Err(e) = self.save_cameras_to_disk().await {
            log::warn!("Failed to save cameras to disk after updating stream settings: {}", e);
        }

        log::info!("Updated stream settings for camera: {}", camera_id);
        Ok(())
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
        &mut self,
        camera_ids: &[String],
        request: StreamStartRequest,
    ) -> Result<Vec<GroupCommandResult>> {
        // Store settings for each camera before starting streams
        for camera_id in camera_ids {
            self.persisted_settings
                .entry(camera_id.to_string())
                .and_modify(|(stream, _)| *stream = Some(request.clone()))
                .or_insert((Some(request.clone()), None));
        }

        let result = self.execute_group_operation(camera_ids, move |client| {
            let req = request.clone();
            async move {
                client.read().await.start_stream(req).await
            }
        }).await;

        // Save to disk after successful group start
        if let Err(e) = self.save_cameras_to_disk().await {
            log::warn!("Failed to save cameras to disk after group start: {}", e);
        }

        result
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
        &mut self,
        camera_ids: &[String],
        settings: CameraSettingsRequest,
    ) -> Result<Vec<GroupCommandResult>> {
        // Store settings for each camera before updating
        for camera_id in camera_ids {
            self.persisted_settings
                .entry(camera_id.to_string())
                .and_modify(|(_, camera)| *camera = Some(settings.clone()))
                .or_insert((None, Some(settings.clone())));
        }

        let result = self.execute_group_operation(camera_ids, move |client| {
            let settings = settings.clone();
            async move {
                client.read().await.update_camera_settings(settings).await
            }
        }).await;

        // Save to disk after successful group update
        if let Err(e) = self.save_cameras_to_disk().await {
            log::warn!("Failed to save cameras to disk after group update: {}", e);
        }

        result
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

    // MARK: - Persisted Settings

    /// Get persisted settings for a camera
    pub fn get_persisted_settings(&self, camera_id: &str) -> Option<(Option<StreamStartRequest>, Option<CameraSettingsRequest>)> {
        self.persisted_settings.get(camera_id).cloned()
    }

    // MARK: - Start/Stop All Operations

    /// Start all cameras with their persisted settings (or default settings if not available)
    pub async fn start_all_cameras(&self) -> Result<Vec<GroupCommandResult>> {
        let camera_ids: Vec<String> = self.cameras.keys().cloned().collect();

        if camera_ids.is_empty() {
            return Ok(Vec::new());
        }

        let mut tasks = Vec::new();

        for camera_id in camera_ids {
            let camera = match self.cameras.get(&camera_id) {
                Some(c) => c,
                None => continue,
            };

            // Get persisted stream settings or use defaults
            let stream_settings = self.persisted_settings
                .get(&camera_id)
                .and_then(|(stream, _)| stream.clone())
                .unwrap_or_else(|| StreamStartRequest {
                    resolution: "1920x1080".to_string(),
                    framerate: 30,
                    bitrate: 10_000_000,
                    codec: "h264".to_string(),
                });

            let client = camera.client.clone();
            let camera_id_clone = camera_id.clone();
            let semaphore = self.operation_semaphore.clone();

            // Spawn task with semaphore for bounded concurrency
            tasks.push(tokio::spawn(async move {
                // Acquire semaphore permit
                let _permit = semaphore.acquire().await.unwrap();

                // Execute start stream
                let result = client.read().await.start_stream(stream_settings).await;

                // Return result
                GroupCommandResult {
                    camera_id: camera_id_clone.clone(),
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
                    log::error!("Start all cameras task failed: {}", e);
                }
            }
        }

        Ok(results)
    }

    /// Stop all cameras
    pub async fn stop_all_cameras(&self) -> Result<Vec<GroupCommandResult>> {
        let camera_ids: Vec<String> = self.cameras.keys().cloned().collect();

        if camera_ids.is_empty() {
            return Ok(Vec::new());
        }

        self.group_stop_stream(&camera_ids).await
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
