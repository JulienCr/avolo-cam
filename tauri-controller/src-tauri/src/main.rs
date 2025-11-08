// Prevents additional console window on Windows in release builds
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod models;
mod camera_discovery;
mod camera_client;
mod camera_manager;

use std::sync::Arc;
use tauri::{Manager, State};
use tokio::sync::RwLock;

use camera_manager::CameraManager;
use models::*;

// MARK: - Application State

struct AppState {
    camera_manager: Arc<RwLock<CameraManager>>,
}

// MARK: - Tauri Commands

#[tauri::command]
async fn discover_cameras(
    state: State<'_, AppState>,
) -> Result<Vec<DiscoveredCamera>, String> {
    let manager = state.camera_manager.read().await;
    manager.get_discovered_cameras().await
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn add_camera_manual(
    state: State<'_, AppState>,
    ip: String,
    port: u16,
    token: String,
) -> Result<String, String> {
    let mut manager = state.camera_manager.write().await;
    manager.add_camera_manual(ip, port, token).await
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn remove_camera(
    state: State<'_, AppState>,
    camera_id: String,
) -> Result<(), String> {
    let mut manager = state.camera_manager.write().await;
    manager.remove_camera(&camera_id).await
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn get_cameras(
    state: State<'_, AppState>,
) -> Result<Vec<CameraInfo>, String> {
    let manager = state.camera_manager.read().await;
    Ok(manager.get_all_cameras().await)
}

#[tauri::command]
async fn get_camera_status(
    state: State<'_, AppState>,
    camera_id: String,
) -> Result<StatusResponse, String> {
    let manager = state.camera_manager.read().await;
    manager.get_camera_status(&camera_id).await
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn start_stream(
    state: State<'_, AppState>,
    camera_id: String,
    resolution: String,
    framerate: u32,
    bitrate: u32,
    codec: String,
) -> Result<(), String> {
    let manager = state.camera_manager.read().await;
    let request = StreamStartRequest {
        resolution,
        framerate,
        bitrate,
        codec,
    };
    manager.start_stream(&camera_id, request).await
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn stop_stream(
    state: State<'_, AppState>,
    camera_id: String,
) -> Result<(), String> {
    let manager = state.camera_manager.read().await;
    manager.stop_stream(&camera_id).await
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn update_camera_settings(
    state: State<'_, AppState>,
    camera_id: String,
    settings: CameraSettingsRequest,
) -> Result<(), String> {
    let manager = state.camera_manager.read().await;
    manager.update_camera_settings(&camera_id, settings).await
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn get_capabilities(
    state: State<'_, AppState>,
    camera_id: String,
) -> Result<Vec<Capability>, String> {
    let manager = state.camera_manager.read().await;
    manager.get_capabilities(&camera_id).await
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn measure_white_balance(
    state: State<'_, AppState>,
    camera_id: String,
) -> Result<WhiteBalanceMeasureResponse, String> {
    let manager = state.camera_manager.read().await;
    manager.measure_white_balance(&camera_id).await
        .map_err(|e| e.to_string())
}

// Group commands

#[tauri::command]
async fn group_start_stream(
    state: State<'_, AppState>,
    camera_ids: Vec<String>,
    resolution: String,
    framerate: u32,
    bitrate: u32,
    codec: String,
) -> Result<Vec<GroupCommandResult>, String> {
    let manager = state.camera_manager.read().await;
    let request = StreamStartRequest {
        resolution,
        framerate,
        bitrate,
        codec,
    };
    manager.group_start_stream(&camera_ids, request).await
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn group_stop_stream(
    state: State<'_, AppState>,
    camera_ids: Vec<String>,
) -> Result<Vec<GroupCommandResult>, String> {
    let manager = state.camera_manager.read().await;
    manager.group_stop_stream(&camera_ids).await
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn group_update_settings(
    state: State<'_, AppState>,
    camera_ids: Vec<String>,
    settings: CameraSettingsRequest,
) -> Result<Vec<GroupCommandResult>, String> {
    let manager = state.camera_manager.read().await;
    manager.group_update_settings(&camera_ids, settings).await
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn update_camera_alias(
    state: State<'_, AppState>,
    camera_id: String,
    alias: String,
) -> Result<(), String> {
    let mut manager = state.camera_manager.write().await;
    manager.update_camera_alias(&camera_id, alias).await
        .map_err(|e| e.to_string())
}

// Profile management commands

#[tauri::command]
async fn save_profile(
    state: State<'_, AppState>,
    name: String,
    settings: CameraSettingsRequest,
) -> Result<(), String> {
    let mut manager = state.camera_manager.write().await;
    manager.save_profile(name, settings).await
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn get_profiles(
    state: State<'_, AppState>,
) -> Result<Vec<CameraProfile>, String> {
    let manager = state.camera_manager.read().await;
    manager.get_profiles().await
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn delete_profile(
    state: State<'_, AppState>,
    name: String,
) -> Result<(), String> {
    let mut manager = state.camera_manager.write().await;
    manager.delete_profile(&name).await
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn apply_profile(
    state: State<'_, AppState>,
    profile_name: String,
    camera_ids: Vec<String>,
) -> Result<Vec<GroupCommandResult>, String> {
    let manager = state.camera_manager.read().await;
    manager.apply_profile(&profile_name, &camera_ids).await
        .map_err(|e| e.to_string())
}

// App settings commands

#[tauri::command]
async fn get_app_settings(
    state: State<'_, AppState>,
) -> Result<AppSettings, String> {
    let manager = state.camera_manager.read().await;
    manager.get_app_settings().await
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn save_app_settings(
    state: State<'_, AppState>,
    settings: AppSettings,
) -> Result<(), String> {
    let mut manager = state.camera_manager.write().await;
    manager.save_app_settings(settings).await
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn delete_cameras_data(
    state: State<'_, AppState>,
) -> Result<(), String> {
    let mut manager = state.camera_manager.write().await;
    manager.delete_cameras_data().await
        .map_err(|e| e.to_string())
}

// MARK: - Main

fn main() {
    env_logger::init();

    tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .plugin(tauri_plugin_notification::init())
        .setup(|app| {
            // Initialize camera manager
            let camera_manager = Arc::new(RwLock::new(CameraManager::new()));

            // Set up persistence path
            let manager_clone = camera_manager.clone();
            let app_handle = app.handle().clone();
            tauri::async_runtime::spawn(async move {
                // Get app data directory
                if let Ok(app_data_dir) = app_handle.path().app_data_dir() {
                    // Create directory if it doesn't exist
                    if let Err(e) = std::fs::create_dir_all(&app_data_dir) {
                        log::error!("Failed to create app data directory: {}", e);
                        return;
                    }

                    // Set persistence path to cameras.json in app data dir
                    let cameras_file = app_data_dir.join("cameras.json");
                    log::info!("Setting camera persistence path to: {:?}", cameras_file);

                    if let Err(e) = manager_clone.write().await.set_persistence_path(cameras_file).await {
                        log::error!("Failed to set persistence path: {}", e);
                    }
                } else {
                    log::warn!("Failed to get app data directory, camera persistence disabled");
                }
            });

            // Start mDNS discovery in background
            let manager_clone = camera_manager.clone();
            tauri::async_runtime::spawn(async move {
                if let Err(e) = manager_clone.write().await.start_discovery().await {
                    log::error!("Failed to start mDNS discovery: {}", e);
                }
            });

            // Set app state
            app.manage(AppState {
                camera_manager,
            });

            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            discover_cameras,
            add_camera_manual,
            remove_camera,
            get_cameras,
            get_camera_status,
            get_capabilities,
            start_stream,
            stop_stream,
            update_camera_settings,
            measure_white_balance,
            group_start_stream,
            group_stop_stream,
            group_update_settings,
            update_camera_alias,
            save_profile,
            get_profiles,
            delete_profile,
            apply_profile,
            get_app_settings,
            save_app_settings,
            delete_cameras_data,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
