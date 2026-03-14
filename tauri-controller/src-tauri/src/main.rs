// Prevents additional console window on Windows in release builds
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod models;
mod camera_discovery;
mod camera_client;
mod camera_manager;
mod midi_manager;

use std::sync::Arc;
use tauri::{Manager, State, AppHandle};
use tokio::sync::RwLock;

use camera_manager::CameraManager;
use futures_util::future::join_all;
use midi_manager::{MidiManager, MidiCommand};
use models::*;

// MARK: - MIDI Dispatcher Thread

/// MIDI dispatcher loop - processes incoming MIDI commands and routes to cameras
async fn midi_dispatcher_loop(
    mut rx: tokio::sync::mpsc::Receiver<MidiCommand>,
    camera_manager: Arc<RwLock<CameraManager>>,
    midi_manager: Arc<RwLock<MidiManager>>,
    learn_mode_tx: Arc<RwLock<Option<tokio::sync::oneshot::Sender<u8>>>>,
) {
    log::info!("MIDI dispatcher thread started");

    while let Some(cmd) = rx.recv().await {
        // Check if we're in learn mode - capture any note and exit learn mode
        if let MidiCommand::NoteOn { note, .. } | MidiCommand::NoteOff { note, .. } = cmd {
            let mut learn_tx = learn_mode_tx.write().await;
            if let Some(tx) = learn_tx.take() {
                log::info!("Learn mode: captured note {}", note);
                let _ = tx.send(note);
                continue; // Don't process this command normally
            }
        }

        if let Err(e) = handle_midi_command(cmd, &camera_manager, &midi_manager).await {
            log::error!("Failed to handle MIDI command: {}", e);
        }
    }

    log::info!("MIDI dispatcher thread stopped");
}

/// Handle a single MIDI command
async fn handle_midi_command(
    cmd: MidiCommand,
    camera_manager: &Arc<RwLock<CameraManager>>,
    midi_manager: &Arc<RwLock<MidiManager>>,
) -> Result<(), String> {
    // Load configured note for focus toggle
    let focus_toggle_note = {
        let manager = camera_manager.read().await;
        manager.get_midi_notes_config().await
            .map(|config| config.focus_toggle_note)
            .unwrap_or(60) // Default to C3 if config unavailable
    };

    match cmd {
        MidiCommand::NoteOn { channel, note, .. } if note == focus_toggle_note => {
            // Focus toggle Note On = Switch to manual focus mode
            log::debug!("MIDI: Note On {} on channel {}", note, channel);

            let manager = camera_manager.read().await;
            if let Some(camera_id) = manager.get_camera_id_by_midi_channel(channel) {
                drop(manager); // Release read lock before write operation

                let mut manager = camera_manager.write().await;
                let settings = CameraSettingsRequest {
                    focus_mode: Some(FocusMode::Manual),
                    ..Default::default()
                };

                if let Err(e) = manager.update_camera_settings(&camera_id, settings).await {
                    log::error!("Failed to set manual focus mode for camera {}: {}", camera_id, e);
                } else {
                    // Send feedback to confirm mode change
                    drop(manager); // Release lock before acquiring MIDI manager lock
                    if let Ok(mut midi_mgr) = midi_manager.try_write() {
                        let _ = midi_mgr.send_note_feedback(channel, focus_toggle_note, true);
                    }
                }
            } else {
                log::debug!("No camera assigned to MIDI channel {}", channel);
            }
        }

        MidiCommand::NoteOff { channel, note } if note == focus_toggle_note => {
            // Focus toggle Note Off = Switch to auto focus mode
            log::debug!("MIDI: Note Off {} on channel {}", note, channel);

            let manager = camera_manager.read().await;
            if let Some(camera_id) = manager.get_camera_id_by_midi_channel(channel) {
                drop(manager); // Release read lock

                let mut manager = camera_manager.write().await;
                let settings = CameraSettingsRequest {
                    focus_mode: Some(FocusMode::Auto),
                    ..Default::default()
                };

                if let Err(e) = manager.update_camera_settings(&camera_id, settings).await {
                    log::error!("Failed to set auto focus mode for camera {}: {}", camera_id, e);
                } else {
                    // Send feedback to confirm mode change
                    drop(manager); // Release lock before acquiring MIDI manager lock
                    if let Ok(mut midi_mgr) = midi_manager.try_write() {
                        let _ = midi_mgr.send_note_feedback(channel, focus_toggle_note, false);
                    }
                }
            }
        }

        MidiCommand::PitchBend { channel, value } => {
            // Pitch Bend = Zoom control (only in manual mode)
            log::debug!("MIDI: Pitch Bend {} on channel {}", value, channel);

            let manager = camera_manager.read().await;
            if let Some(camera_id) = manager.get_camera_id_by_midi_channel(channel) {
                // Check if camera is in manual focus mode (use cached info, no HTTP)
                let camera = manager.get_cached_camera_info(&camera_id);

                if let Some(camera_info) = camera {
                    let is_manual = camera_info.status
                        .as_ref()
                        .map(|s| s.current.focus_mode == FocusMode::Manual)
                        .unwrap_or(false);

                    if !is_manual {
                        log::debug!("Ignoring pitch bend for camera {} (not in manual mode)", camera_id);
                        return Ok(());
                    }

                    // Get max_zoom from capabilities
                    let max_zoom = camera_info.capabilities
                        .as_ref()
                        .and_then(|caps| caps.iter().find_map(|c| c.max_zoom))
                        .unwrap_or(10.0); // Safe fallback

                    let zoom_factor = MidiManager::pitch_bend_to_zoom(value, max_zoom);

                    drop(manager); // Release read lock

                    let mut manager = camera_manager.write().await;
                    let settings = CameraSettingsRequest {
                        zoom_factor: Some(zoom_factor),
                        ..Default::default()
                    };

                    if let Err(e) = manager.update_camera_settings(&camera_id, settings).await {
                        log::error!("Failed to set zoom for camera {}: {}", camera_id, e);
                    }
                }
            }
        }

        _ => {
            // Ignore other MIDI messages
        }
    }

    Ok(())
}

// MARK: - Application State

struct AppState {
    camera_manager: Arc<RwLock<CameraManager>>,
    midi_manager: Arc<RwLock<MidiManager>>,
    learn_mode_tx: Arc<RwLock<Option<tokio::sync::oneshot::Sender<u8>>>>,
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
    // Brief read lock: snapshot camera info + client handles (no HTTP, instant)
    let snapshots = {
        let manager = state.camera_manager.read().await;
        manager.get_camera_snapshots()
    };

    // Poll all cameras in parallel WITHOUT holding any lock
    let futures: Vec<_> = snapshots.into_iter().map(|(id, mut info, client)| {
        async move {
            match client.read().await.get_status().await {
                Ok(status) => {
                    info.status = Some(status);
                    info.connection_state = ConnectionState::Connected;
                }
                Err(e) => {
                    log::warn!("Failed to get status for camera {}: {}", id, e);
                    info.connection_state = ConnectionState::Error;
                }
            }
            info
        }
    }).collect();

    let cameras = join_all(futures).await;

    // Brief write lock only to update connection states and auto-apply on reconnect
    {
        let mut manager = state.camera_manager.write().await;
        manager.apply_reconnect_settings(&cameras).await;
    }
    Ok(cameras)
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
    streaming_mode: Option<String>,
    srt_port: Option<u32>,
    srt_latency: Option<u32>,
    srt_rcv_latency: Option<u32>,
    srt_peer_latency: Option<u32>,
    srt_tlpktdrop: Option<bool>,
    srt_gop_size: Option<u32>,
    flash_destination_host: Option<String>,
    flash_destination_port: Option<u32>,
    flash_jitter_mode: Option<String>,
) -> Result<(), String> {
    let mut manager = state.camera_manager.write().await;

    // Parse streaming_mode string to enum
    let mode = streaming_mode.as_deref().and_then(|m| match m {
        "ndi" => Some(StreamingMode::Ndi),
        "srt" => Some(StreamingMode::Srt),
        "flash" => Some(StreamingMode::Flash),
        _ => None,
    });

    let request = StreamStartRequest {
        resolution,
        framerate,
        bitrate,
        codec,
        streaming_mode: mode,
        srt_port,
        srt_latency,
        srt_rcv_latency,
        srt_peer_latency,
        srt_tlpktdrop,
        srt_gop_size,
        flash_destination_host,
        flash_destination_port,
        flash_jitter_mode,
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
    let mut manager = state.camera_manager.write().await;
    manager.update_camera_settings(&camera_id, settings).await
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn update_stream_settings(
    state: State<'_, AppState>,
    camera_id: String,
    resolution: String,
    framerate: u32,
    bitrate: u32,
    codec: String,
    streaming_mode: Option<String>,
    srt_port: Option<u32>,
    srt_latency: Option<u32>,
    srt_rcv_latency: Option<u32>,
    srt_peer_latency: Option<u32>,
    srt_tlpktdrop: Option<bool>,
    srt_gop_size: Option<u32>,
    flash_destination_host: Option<String>,
    flash_destination_port: Option<u32>,
    flash_jitter_mode: Option<String>,
) -> Result<(), String> {
    let mut manager = state.camera_manager.write().await;

    // Parse streaming_mode string to enum
    let mode = streaming_mode.as_deref().and_then(|m| match m {
        "ndi" => Some(StreamingMode::Ndi),
        "srt" => Some(StreamingMode::Srt),
        "flash" => Some(StreamingMode::Flash),
        _ => None,
    });

    let request = StreamStartRequest {
        resolution,
        framerate,
        bitrate,
        codec,
        streaming_mode: mode,
        srt_port,
        srt_latency,
        srt_rcv_latency,
        srt_peer_latency,
        srt_tlpktdrop,
        srt_gop_size,
        flash_destination_host,
        flash_destination_port,
        flash_jitter_mode,
    };
    manager.update_stream_settings(&camera_id, request).await
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
    streaming_mode: Option<String>,
    srt_port: Option<u32>,
    srt_latency: Option<u32>,
    srt_rcv_latency: Option<u32>,
    srt_peer_latency: Option<u32>,
    srt_tlpktdrop: Option<bool>,
    srt_gop_size: Option<u32>,
    flash_destination_host: Option<String>,
    flash_destination_port: Option<u32>,
    flash_jitter_mode: Option<String>,
) -> Result<Vec<GroupCommandResult>, String> {
    let mut manager = state.camera_manager.write().await;

    // Parse streaming_mode string to enum
    let mode = streaming_mode.as_deref().and_then(|m| match m {
        "ndi" => Some(StreamingMode::Ndi),
        "srt" => Some(StreamingMode::Srt),
        "flash" => Some(StreamingMode::Flash),
        _ => None,
    });

    let request = StreamStartRequest {
        resolution,
        framerate,
        bitrate,
        codec,
        streaming_mode: mode,
        srt_port,
        srt_latency,
        srt_rcv_latency,
        srt_peer_latency,
        srt_tlpktdrop,
        srt_gop_size,
        flash_destination_host,
        flash_destination_port,
        flash_jitter_mode,
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
    let mut manager = state.camera_manager.write().await;
    manager.group_update_settings(&camera_ids, settings).await
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn start_all_cameras(
    state: State<'_, AppState>,
) -> Result<Vec<GroupCommandResult>, String> {
    let manager = state.camera_manager.read().await;
    manager.start_all_cameras().await
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn stop_all_cameras(
    state: State<'_, AppState>,
) -> Result<Vec<GroupCommandResult>, String> {
    let manager = state.camera_manager.read().await;
    manager.stop_all_cameras().await
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
    let mut manager = state.camera_manager.write().await;
    manager.apply_profile(&profile_name, &camera_ids).await
        .map_err(|e| e.to_string())
}

// MARK: - MIDI Commands

#[tauri::command]
async fn list_midi_input_devices() -> Result<Vec<String>, String> {
    MidiManager::list_input_devices()
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn list_midi_output_devices() -> Result<Vec<String>, String> {
    MidiManager::list_output_devices()
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn connect_midi_input(
    state: State<'_, AppState>,
    device_name: String,
) -> Result<(), String> {
    let mut manager = state.midi_manager.write().await;
    manager.connect_input(&device_name)
        .map_err(|e| e.to_string())?;

    // Persist device name in settings
    let mut camera_manager = state.camera_manager.write().await;
    if let Ok(mut settings) = camera_manager.get_app_settings().await {
        if settings.midi.is_none() {
            settings.midi = Some(MidiSettings {
                input_device_name: None,
                output_device_name: None,
                notes: MidiNoteConfig::default(),
            });
        }
        settings.midi.as_mut().unwrap().input_device_name = Some(device_name);
        let _ = camera_manager.save_app_settings(settings).await;
    }

    Ok(())
}

#[tauri::command]
async fn connect_midi_output(
    state: State<'_, AppState>,
    device_name: String,
) -> Result<(), String> {
    let mut manager = state.midi_manager.write().await;
    manager.connect_output(&device_name)
        .map_err(|e| e.to_string())?;

    // Persist device name in settings
    let mut camera_manager = state.camera_manager.write().await;
    if let Ok(mut settings) = camera_manager.get_app_settings().await {
        if settings.midi.is_none() {
            settings.midi = Some(MidiSettings {
                input_device_name: None,
                output_device_name: None,
                notes: MidiNoteConfig::default(),
            });
        }
        settings.midi.as_mut().unwrap().output_device_name = Some(device_name);
        let _ = camera_manager.save_app_settings(settings).await;
    }

    Ok(())
}

#[tauri::command]
async fn disconnect_midi_input(
    state: State<'_, AppState>,
) -> Result<(), String> {
    let mut manager = state.midi_manager.write().await;
    manager.disconnect_input();
    Ok(())
}

#[tauri::command]
async fn disconnect_midi_output(
    state: State<'_, AppState>,
) -> Result<(), String> {
    let mut manager = state.midi_manager.write().await;
    manager.disconnect_output();
    Ok(())
}

#[tauri::command]
async fn update_camera_midi_channel(
    state: State<'_, AppState>,
    camera_id: String,
    channel: Option<u8>,
) -> Result<(), String> {
    let mut manager = state.camera_manager.write().await;
    manager.update_midi_channel(&camera_id, channel).await
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn get_midi_connection_status(
    state: State<'_, AppState>,
) -> Result<(bool, bool, Option<String>, Option<String>), String> {
    let manager = state.midi_manager.read().await;
    Ok((
        manager.is_input_connected(),
        manager.is_output_connected(),
        manager.input_device_name().map(|s| s.to_string()),
        manager.output_device_name().map(|s| s.to_string()),
    ))
}

#[tauri::command]
async fn get_midi_notes_config(
    state: State<'_, AppState>,
) -> Result<MidiNoteConfig, String> {
    let manager = state.camera_manager.read().await;
    manager.get_midi_notes_config().await
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn update_midi_notes_config(
    state: State<'_, AppState>,
    notes: MidiNoteConfig,
) -> Result<(), String> {
    let mut manager = state.camera_manager.write().await;
    manager.update_midi_notes_config(notes).await
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn start_midi_learn_mode(
    state: State<'_, AppState>,
) -> Result<u8, String> {
    // Create a oneshot channel to receive the learned note
    let (tx, rx) = tokio::sync::oneshot::channel();
    
    // Store the sender in app state
    {
        let mut learn_tx = state.learn_mode_tx.write().await;
        if learn_tx.is_some() {
            return Err("Learn mode already active".to_string());
        }
        *learn_tx = Some(tx);
    }
    
    log::info!("MIDI Learn mode activated - waiting for note...");
    
    // Wait for note to be captured (with timeout)
    match tokio::time::timeout(std::time::Duration::from_secs(10), rx).await {
        Ok(Ok(note)) => {
            log::info!("MIDI Learn mode: captured note {}", note);
            Ok(note)
        }
        Ok(Err(_)) => {
            // Channel closed without sending (shouldn't happen)
            Err("Learn mode channel closed unexpectedly".to_string())
        }
        Err(_) => {
            // Timeout - cleanup
            let mut learn_tx = state.learn_mode_tx.write().await;
            *learn_tx = None;
            Err("Learn mode timeout - no note received within 10 seconds".to_string())
        }
    }
}

#[tauri::command]
async fn cancel_midi_learn_mode(
    state: State<'_, AppState>,
) -> Result<(), String> {
    let mut learn_tx = state.learn_mode_tx.write().await;
    *learn_tx = None;
    log::info!("MIDI Learn mode cancelled");
    Ok(())
}

// Offline camera settings persistence

#[tauri::command]
async fn persist_camera_settings(
    state: State<'_, AppState>,
    camera_id: String,
    settings: CameraSettingsRequest,
) -> Result<(), String> {
    let mut manager = state.camera_manager.write().await;
    manager.persist_camera_settings(&camera_id, settings).await
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn get_persisted_camera_settings(
    state: State<'_, AppState>,
    camera_id: String,
) -> Result<Option<CameraSettingsRequest>, String> {
    let manager = state.camera_manager.read().await;
    Ok(manager.get_persisted_camera_settings(&camera_id))
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

// Notification permission commands

#[tauri::command]
async fn check_notification_permission(app: AppHandle) -> Result<bool, String> {
    use tauri_plugin_notification::NotificationExt;

    app.notification()
        .permission_state()
        .map(|state| state == tauri_plugin_notification::PermissionState::Granted)
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn request_notification_permission(app: AppHandle) -> Result<bool, String> {
    use tauri_plugin_notification::NotificationExt;

    app.notification()
        .request_permission()
        .map(|state| state == tauri_plugin_notification::PermissionState::Granted)
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn send_test_notification(app: AppHandle, title: String, body: String) -> Result<(), String> {
    use tauri_plugin_notification::NotificationExt;

    log::info!("Sending test notification: {} - {}", title, body);

    // Try to get permission state first
    let permission = app.notification().permission_state();
    log::info!("Current permission state: {:?}", permission);

    let result = app.notification()
        .builder()
        .title(&title)
        .body(&body)
        .show();

    match &result {
        Ok(notification_id) => {
            log::info!("Notification sent successfully with ID: {:?}", notification_id);
        },
        Err(e) => {
            log::error!("Failed to send notification: {}", e);
        }
    }

    result.map(|_| ()).map_err(|e| e.to_string())
}

// MARK: - Network Utilities

#[tauri::command]
async fn get_local_ip() -> Result<String, String> {
    local_ip_address::local_ip()
        .map(|ip| ip.to_string())
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

            // Create MIDI manager and spawn dispatcher thread
            let (midi_manager, midi_rx) = MidiManager::new();
            let midi_manager = Arc::new(RwLock::new(midi_manager));

            // Connect MIDI manager to camera manager (in async context)
            let camera_manager_for_midi = camera_manager.clone();
            let midi_manager_for_setup = midi_manager.clone();
            tauri::async_runtime::spawn(async move {
                camera_manager_for_midi.write().await.set_midi_manager(midi_manager_for_setup);
            });

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

            // Spawn MIDI dispatcher thread
            let camera_manager_clone = camera_manager.clone();
            let midi_manager_clone = midi_manager.clone();
            let learn_mode_tx = Arc::new(RwLock::new(None));
            let learn_mode_tx_clone = learn_mode_tx.clone();
            tauri::async_runtime::spawn(async move {
                midi_dispatcher_loop(midi_rx, camera_manager_clone, midi_manager_clone, learn_mode_tx_clone).await;
            });

            // Restore MIDI connections from saved settings
            let camera_manager_for_midi_restore = camera_manager.clone();
            let midi_manager_for_restore = midi_manager.clone();
            tauri::async_runtime::spawn(async move {
                // Small delay to ensure app data directory is ready
                tokio::time::sleep(tokio::time::Duration::from_millis(500)).await;
                
                if let Ok(settings) = camera_manager_for_midi_restore.read().await.get_app_settings().await {
                    if let Some(midi_settings) = settings.midi {
                        let mut midi_mgr = midi_manager_for_restore.write().await;
                        
                        // Restore input device connection
                        if let Some(input_device) = midi_settings.input_device_name {
                            log::info!("Restoring MIDI input connection to: {}", input_device);
                            if let Err(e) = midi_mgr.connect_input(&input_device) {
                                log::warn!("Failed to restore MIDI input connection: {}", e);
                            } else {
                                log::info!("✅ MIDI input restored: {}", input_device);
                            }
                        }
                        
                        // Restore output device connection
                        if let Some(output_device) = midi_settings.output_device_name {
                            log::info!("Restoring MIDI output connection to: {}", output_device);
                            if let Err(e) = midi_mgr.connect_output(&output_device) {
                                log::warn!("Failed to restore MIDI output connection: {}", e);
                            } else {
                                log::info!("✅ MIDI output restored: {}", output_device);
                            }
                        }
                        
                        log::info!("✅ MIDI note config: focus_toggle={}", midi_settings.notes.focus_toggle_note);
                    }
                }
            });

            // Set app state
            app.manage(AppState {
                camera_manager,
                midi_manager,
                learn_mode_tx,
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
            update_stream_settings,
            measure_white_balance,
            group_start_stream,
            group_stop_stream,
            group_update_settings,
            start_all_cameras,
            stop_all_cameras,
            update_camera_alias,
            save_profile,
            get_profiles,
            delete_profile,
            apply_profile,
            persist_camera_settings,
            get_persisted_camera_settings,
            get_app_settings,
            save_app_settings,
            delete_cameras_data,
            check_notification_permission,
            request_notification_permission,
            send_test_notification,
            list_midi_input_devices,
            list_midi_output_devices,
            connect_midi_input,
            connect_midi_output,
            disconnect_midi_input,
            disconnect_midi_output,
            update_camera_midi_channel,
            get_midi_connection_status,
            get_midi_notes_config,
            update_midi_notes_config,
            start_midi_learn_mode,
            cancel_midi_learn_mode,
            get_local_ip,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
