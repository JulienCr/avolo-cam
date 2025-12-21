//! MIDI Manager for bidirectional camera control via MIDI
//!
//! Handles MIDI input (Note On/Off, Pitch Bend) and output (feedback to motorized faders)
//! with anti-echo protection and device reconnection support.

use anyhow::{Context, Result};
use midir::{MidiInput, MidiInputConnection, MidiOutput, MidiOutputConnection};
use std::collections::HashMap;
use std::time::Instant;
use tokio::sync::mpsc;

// MIDI constants
const PITCH_BEND_EPSILON: i16 = 50; // ~0.3% deadband to avoid jitter
const FEEDBACK_DEBOUNCE_MS: u64 = 100; // Anti-echo debounce time

/// MIDI command parsed from input messages
#[derive(Debug, Clone)]
pub enum MidiCommand {
    NoteOn { channel: u8, note: u8, #[allow(dead_code)] velocity: u8 },
    NoteOff { channel: u8, note: u8 },
    PitchBend { channel: u8, value: i16 },
}

/// MIDI Manager for input/output control
pub struct MidiManager {
    // Input
    input_connection: Option<MidiInputConnection<()>>,
    input_device_name: Option<String>,
    command_tx: mpsc::Sender<MidiCommand>,
    command_rx: Option<mpsc::Receiver<MidiCommand>>,

    // Output
    output_connection: Option<MidiOutputConnection>,
    output_device_name: Option<String>,

    // Anti-echo state
    last_sent_feedback: HashMap<u8, (i16, Instant)>, // channel -> (pitch_bend_value, timestamp)
}

impl MidiManager {
    /// Create a new MIDI manager
    pub fn new() -> (Self, mpsc::Receiver<MidiCommand>) {
        let (tx, rx) = mpsc::channel(100);

        let manager = Self {
            input_connection: None,
            input_device_name: None,
            command_tx: tx,
            command_rx: Some(rx),

            output_connection: None,
            output_device_name: None,

            last_sent_feedback: HashMap::new(),
        };

        // Extract receiver for dispatcher thread
        let _dispatcher_rx = manager.command_rx.as_ref().unwrap();
        
        // We need to return ownership, so we'll reconstruct this differently
        let (tx2, rx2) = mpsc::channel(100);
        let manager2 = Self {
            input_connection: None,
            input_device_name: None,
            command_tx: tx2.clone(),
            command_rx: None, // Receiver given to dispatcher

            output_connection: None,
            output_device_name: None,

            last_sent_feedback: HashMap::new(),
        };

        (manager2, rx2)
    }

    // MARK: - Device Enumeration

    /// List available MIDI input devices
    pub fn list_input_devices() -> Result<Vec<String>> {
        let midi_in = MidiInput::new("AvoCam Input Enumerator")
            .context("Failed to create MIDI input for enumeration")?;

        let ports = midi_in.ports();
        let mut devices = Vec::new();

        for port in ports {
            if let Ok(name) = midi_in.port_name(&port) {
                devices.push(name);
            }
        }

        log::info!("Found {} MIDI input devices", devices.len());
        Ok(devices)
    }

    /// List available MIDI output devices
    pub fn list_output_devices() -> Result<Vec<String>> {
        let midi_out = MidiOutput::new("AvoCam Output Enumerator")
            .context("Failed to create MIDI output for enumeration")?;

        let ports = midi_out.ports();
        let mut devices = Vec::new();

        for port in ports {
            if let Ok(name) = midi_out.port_name(&port) {
                devices.push(name);
            }
        }

        log::info!("Found {} MIDI output devices", devices.len());
        Ok(devices)
    }

    /// Find device port by name (exact or fuzzy match)
    fn find_device_by_name(devices: &[String], persisted_name: &str) -> Option<usize> {
        // Exact match first
        if let Some(pos) = devices.iter().position(|d| d == persisted_name) {
            return Some(pos);
        }

        // Fuzzy match (case-insensitive substring)
        let lower_persisted = persisted_name.to_lowercase();
        devices.iter().position(|d| {
            let lower_device = d.to_lowercase();
            lower_device.contains(&lower_persisted) || lower_persisted.contains(&lower_device)
        })
    }

    // MARK: - Input Connection

    /// Connect to MIDI input device by name
    pub fn connect_input(&mut self, device_name: &str) -> Result<()> {
        // Disconnect existing connection
        self.disconnect_input();

        let midi_in = MidiInput::new("AvoCam MIDI Input")
            .context("Failed to create MIDI input")?;

        let ports = midi_in.ports();
        let device_names: Vec<String> = ports
            .iter()
            .filter_map(|p| midi_in.port_name(p).ok())
            .collect();

        let port_idx = Self::find_device_by_name(&device_names, device_name)
            .ok_or_else(|| anyhow::anyhow!("MIDI input device not found: {}", device_name))?;

        let port = &ports[port_idx];
        let tx = self.command_tx.clone();

        let connection = midi_in
            .connect(
                port,
                "avocam-input",
                move |_stamp, message, _| {
                    if let Some(cmd) = Self::parse_midi_message(message) {
                        let _ = tx.try_send(cmd); // Non-blocking send
                    }
                },
                (),
            )
            .context("Failed to connect to MIDI input port")?;

        self.input_connection = Some(connection);
        self.input_device_name = Some(device_name.to_string());

        log::info!("Connected to MIDI input: {}", device_name);
        Ok(())
    }

    /// Disconnect MIDI input
    pub fn disconnect_input(&mut self) {
        if self.input_connection.take().is_some() {
            log::info!("Disconnected MIDI input: {:?}", self.input_device_name);
            self.input_device_name = None;
        }
    }

    /// Parse MIDI message bytes into MidiCommand
    fn parse_midi_message(message: &[u8]) -> Option<MidiCommand> {
        if message.len() < 2 {
            return None;
        }

        let status = message[0];
        let msg_type = status & 0xF0;
        let channel = (status & 0x0F) + 1; // Convert 0-15 to 1-16

        match msg_type {
            0x90 => {
                // Note On
                let note = message[1];
                let velocity = message.get(2).copied().unwrap_or(0);
                if velocity > 0 {
                    Some(MidiCommand::NoteOn { channel, note, velocity })
                } else {
                    // Note On with velocity 0 is Note Off
                    Some(MidiCommand::NoteOff { channel, note })
                }
            }
            0x80 => {
                // Note Off
                let note = message[1];
                Some(MidiCommand::NoteOff { channel, note })
            }
            0xE0 => {
                // Pitch Bend
                if message.len() < 3 {
                    return None;
                }
                let lsb = message[1];
                let msb = message[2];
                let value = Self::decode_pitch_bend(lsb, msb);
                Some(MidiCommand::PitchBend { channel, value })
            }
            _ => None, // Ignore other message types
        }
    }

    // MARK: - Output Connection

    /// Connect to MIDI output device by name
    pub fn connect_output(&mut self, device_name: &str) -> Result<()> {
        // Disconnect existing connection
        self.disconnect_output();

        let midi_out = MidiOutput::new("AvoCam MIDI Output")
            .context("Failed to create MIDI output")?;

        let ports = midi_out.ports();
        let device_names: Vec<String> = ports
            .iter()
            .filter_map(|p| midi_out.port_name(p).ok())
            .collect();

        let port_idx = Self::find_device_by_name(&device_names, device_name)
            .ok_or_else(|| anyhow::anyhow!("MIDI output device not found: {}", device_name))?;

        let port = &ports[port_idx];

        let connection = midi_out
            .connect(port, "avocam-output")
            .context("Failed to connect to MIDI output port")?;

        self.output_connection = Some(connection);
        self.output_device_name = Some(device_name.to_string());

        log::info!("Connected to MIDI output: {}", device_name);
        Ok(())
    }

    /// Disconnect MIDI output
    pub fn disconnect_output(&mut self) {
        if let Some(conn) = self.output_connection.take() {
            let _ = conn.close();
            log::info!("Disconnected MIDI output: {:?}", self.output_device_name);
            self.output_device_name = None;
        }
    }

    // MARK: - Pitch Bend Codec (14-bit)

    /// Decode pitch bend from LSB/MSB bytes (14-bit)
    fn decode_pitch_bend(lsb: u8, msb: u8) -> i16 {
        ((msb as i16) << 7) | (lsb as i16)
    }

    /// Encode pitch bend value to LSB/MSB bytes (14-bit)
    fn encode_pitch_bend(value: i16) -> (u8, u8) {
        let lsb = (value & 0x7F) as u8;
        let msb = ((value >> 7) & 0x7F) as u8;
        (lsb, msb)
    }

    /// Convert zoom factor to pitch bend value (0-16383)
    pub fn zoom_to_pitch_bend(zoom_factor: f64, max_zoom: f64) -> i16 {
        let normalized = ((zoom_factor - 1.0) / (max_zoom - 1.0)).clamp(0.0, 1.0);
        let value = (normalized * 16383.0).round() as i16;
        value.clamp(0, 16383)
    }

    /// Convert pitch bend value to zoom factor (1.0 - max_zoom)
    pub fn pitch_bend_to_zoom(value: i16, max_zoom: f64) -> f64 {
        let normalized = (value as f64 / 16383.0).clamp(0.0, 1.0);
        1.0 + normalized * (max_zoom - 1.0)
    }

    // MARK: - Output Feedback

    /// Check if feedback should be sent (anti-echo logic)
    fn should_send_feedback(&self, channel: u8, new_value: i16) -> bool {
        if let Some((last_value, last_time)) = self.last_sent_feedback.get(&channel) {
            let delta = (new_value - last_value).abs();
            let elapsed = last_time.elapsed().as_millis() as u64;

            // Skip if too similar or too soon (anti-echo)
            if delta < PITCH_BEND_EPSILON || elapsed < FEEDBACK_DEBOUNCE_MS {
                return false;
            }
        }
        true
    }

    /// Send pitch bend feedback for zoom position
    pub fn send_zoom_feedback(&mut self, channel: u8, zoom_factor: f64, max_zoom: f64) -> Result<()> {
        if self.output_connection.is_none() {
            return Ok(()); // No output connected, skip silently
        }

        if channel < 1 || channel > 8 {
            return Ok(()); // Invalid channel, skip
        }

        let pitch_bend_value = Self::zoom_to_pitch_bend(zoom_factor, max_zoom);

        // Anti-echo check
        if !self.should_send_feedback(channel, pitch_bend_value) {
            return Ok(()); // Skip feedback (too similar or too soon)
        }

        let status = 0xE0 | (channel - 1); // 0xE0-0xE7 for channels 1-8
        let (lsb, msb) = Self::encode_pitch_bend(pitch_bend_value);

        // Send the message
        if let Some(ref mut conn) = self.output_connection {
            conn.send(&[status, lsb, msb])
                .context("Failed to send pitch bend feedback")?;

            // Record sent feedback
            self.last_sent_feedback.insert(channel, (pitch_bend_value, Instant::now()));

            log::debug!(
                "Sent pitch bend feedback: channel={}, zoom={:.2}, value={}",
                channel,
                zoom_factor,
                pitch_bend_value
            );
        }

        Ok(())
    }

    /// Send note on/off feedback for manual mode LED
    pub fn send_note_feedback(&mut self, channel: u8, note: u8, is_manual: bool) -> Result<()> {
        let Some(ref mut conn) = self.output_connection else {
            return Ok(()); // No output connected, skip silently
        };

        if channel < 1 || channel > 8 {
            return Ok(()); // Invalid channel, skip
        }

        let status = if is_manual {
            0x90 | (channel - 1) // Note On
        } else {
            0x80 | (channel - 1) // Note Off
        };

        let velocity = if is_manual { 127 } else { 0 };

        conn.send(&[status, note, velocity])
            .context("Failed to send note feedback")?;

        log::debug!(
            "Sent note feedback: channel={}, manual={}, note={}",
            channel,
            is_manual,
            note
        );

        Ok(())
    }

    // MARK: - Getters

    pub fn is_input_connected(&self) -> bool {
        self.input_connection.is_some()
    }

    pub fn is_output_connected(&self) -> bool {
        self.output_connection.is_some()
    }

    pub fn input_device_name(&self) -> Option<&str> {
        self.input_device_name.as_deref()
    }

    pub fn output_device_name(&self) -> Option<&str> {
        self.output_device_name.as_deref()
    }
}

impl Drop for MidiManager {
    fn drop(&mut self) {
        self.disconnect_input();
        self.disconnect_output();
    }
}

