# MIDI Control Bidirectionnel - Spécifications d'Implémentation

## ✅ Décisions Confirmées

1. **Manual Mode Ownership** : Pitch Bend **IGNORÉ** si caméra pas en mode manuel (sécurité) ✅
2. **Feedback Rate** : Coalescing par delta significatif (epsilon-based, pas de 20Hz fixe) ✅  
3. **Device Reconnection** : Fuzzy match par nom (substring case-insensitive) ✅

## Vue d'ensemble

Contrôle MIDI bidirectionnel pour zoom des caméras :
- **Input** : Note On/Off (C3) pour mode manual, Pitch Bend pour zoom
- **Output** : Feedback vers faders motorisés (Pitch Bend + Note LED)
- **Channels** : 1-8 (une caméra par channel)
- **Protection** : Anti-echo, loop prevention, device reconnection

## Architecture

```
MIDI Input Device
  ↓ (raw bytes)
midir callback
  ↓ (send)
mpsc::channel<MidiCommand>
  ↓ (recv)
Dispatcher Thread
  ↓ (parse + route)
Camera Manager (check manual mode)
  ↓ (HTTP/WS)
Camera iOS
  ↓ (telemetry 1Hz)
Feedback Logic (manual mode only)
  ↓ (anti-echo check)
MIDI Output Device
```

## Gaps Critiques Résolus

### 1. Loop Protection ✅

```rust
const PITCH_BEND_EPSILON: i16 = 50; // ~0.3% deadband
const FEEDBACK_DEBOUNCE_MS: u64 = 100;

struct MidiManager {
    last_sent_feedback: HashMap<u8, (i16, Instant)>, // channel -> (value, time)
}

fn should_send_feedback(&self, channel: u8, new_value: i16) -> bool {
    if let Some((last_value, last_time)) = self.last_sent_feedback.get(&channel) {
        let delta = (new_value - last_value).abs();
        let elapsed = last_time.elapsed().as_millis() as u64;
        
        // Skip if too similar or too soon
        if delta < PITCH_BEND_EPSILON || elapsed < FEEDBACK_DEBOUNCE_MS {
            return false;
        }
    }
    true
}
```

### 2. Manual Mode Security ✅

```rust
fn handle_pitch_bend(channel: u8, value: i16, camera_manager: &CameraManager) {
    if let Some(camera) = camera_manager.get_camera_by_midi_channel(channel) {
        // SECURITY: Ignore if not in manual mode
        if camera.status.current.focus_mode != FocusMode::Manual {
            log::debug!("Ignoring pitch bend for camera {} (not in manual mode)", camera.id);
            return;
        }
        
        // Apply zoom change
        let zoom_factor = pitch_bend_to_zoom(value, get_max_zoom(camera));
        camera_manager.update_camera_settings(camera.id, CameraSettingsRequest {
            zoom_factor: Some(zoom_factor),
            ..Default::default()
        }).await;
    }
}
```

### 3. Capabilities Availability ✅

```rust
pub struct CameraInfo {
    // ... existing fields ...
    pub midi_channel: Option<u8>,
    pub capabilities: Option<Vec<Capability>>, // Cache for max_zoom
}

fn get_max_zoom(camera: &CameraInfo) -> f64 {
    camera.capabilities
        .as_ref()
        .and_then(|caps| caps.iter().find_map(|c| c.max_zoom))
        .unwrap_or(10.0) // Safe fallback
}
```

### 4. Pitch Bend Encoding (14-bit) ✅

```rust
// Output (Controller → Fader)
fn zoom_to_pitch_bend(zoom_factor: f64, max_zoom: f64) -> i16 {
    let normalized = (zoom_factor - 1.0) / (max_zoom - 1.0); // 0.0-1.0
    let value = (normalized * 16383.0).round() as i16;
    value.clamp(0, 16383)
}

fn encode_pitch_bend(value: i16, channel: u8) -> [u8; 3] {
    let lsb = (value & 0x7F) as u8;
    let msb = ((value >> 7) & 0x7F) as u8;
    let status = 0xE0 | (channel - 1); // 0xE0-0xE7 for channels 1-8
    [status, lsb, msb]
}

// Input (Fader → Controller)
fn decode_pitch_bend(lsb: u8, msb: u8) -> i16 {
    ((msb as i16) << 7) | (lsb as i16)
}

fn pitch_bend_to_zoom(value: i16, max_zoom: f64) -> f64 {
    let normalized = value as f64 / 16383.0; // 0.0-1.0
    1.0 + normalized * (max_zoom - 1.0)
}
```

### 5. Device Reconnection (Fuzzy Match) ✅

```rust
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
```

Persist dans `settings.json` :
```json
{
  "midi": {
    "input_device_name": "Behringer X-Touch Mini",
    "output_device_name": "Behringer X-Touch Mini"
  }
}
```

### 6. Channel ↔ Camera Ownership ✅

```rust
struct MidiManager {
    channel_to_camera: HashMap<u8, String>, // channel -> camera_id
}

fn rebuild_routing_table(&mut self, cameras: &[CameraInfo]) {
    self.channel_to_camera.clear();
    for camera in cameras {
        if let Some(channel) = camera.midi_channel {
            self.channel_to_camera.insert(channel, camera.id.clone());
        }
    }
}
```

Source of truth : `cameras.json` (rebuild au startup)

### 7. Feedback Rate (Delta-Based) ✅

**PAS de rate limiter 20 Hz**, juste coalescing intelligent :
- Envoyer feedback **seulement si delta > epsilon**
- Combiné avec debounce anti-echo (100ms)
- Résultat : fluide + pas de spam

```rust
// Dans should_send_feedback() - déjà implémenté ci-dessus
// Pas besoin de RateLimiter struct séparé
```

### 8. Thread-Safe MIDI ✅

```rust
enum MidiCommand {
    NoteOn { channel: u8, note: u8, velocity: u8 },
    NoteOff { channel: u8, note: u8 },
    PitchBend { channel: u8, value: i16 },
}

struct MidiManager {
    command_tx: mpsc::Sender<MidiCommand>,
    command_rx: Option<mpsc::Receiver<MidiCommand>>,
    last_sent_feedback: HashMap<u8, (i16, Instant)>,
    channel_to_camera: HashMap<u8, String>,
    input_connection: Option<MidiInputConnection<()>>,
    output_connection: Option<MidiOutputConnection>,
}

// Callback (no locks)
fn midi_input_callback(stamp: u64, message: &[u8], tx: &mpsc::Sender<MidiCommand>) {
    if let Some(cmd) = parse_midi_message(message) {
        let _ = tx.send(cmd);
    }
}

// Dispatcher thread
async fn midi_dispatcher_loop(
    mut rx: mpsc::Receiver<MidiCommand>,
    camera_manager: Arc<RwLock<CameraManager>>,
) {
    while let Some(cmd) = rx.recv().await {
        match cmd {
            MidiCommand::NoteOn { channel, note, .. } if note == 60 => {
                // Set focus_mode: manual
            }
            MidiCommand::NoteOff { channel, note } if note == 60 => {
                // Set focus_mode: auto
            }
            MidiCommand::PitchBend { channel, value } => {
                // Check manual mode + update zoom
            }
            _ => {}
        }
    }
}
```

## Mapping MIDI

### Input → Actions

| Message MIDI | Channel | Action |
|--------------|---------|--------|
| **Note On** C3 (60, vel>0) | 1-8 | Set `focus_mode: "manual"` |
| **Note Off** C3 (60) | 1-8 | Set `focus_mode: "auto"` |
| **Pitch Bend** (14-bit) | 1-8 | Set `zoom_factor` **SI en mode manual** (sinon ignoré) |

### Output → Feedback

| État Caméra | Channel | Message MIDI |
|-------------|---------|--------------|
| Passage en manual | 1-8 | Note On C3 (60, vel=127) → LED on |
| Passage en auto | 1-8 | Note Off C3 (60) → LED off |
| `zoom_factor` change (manual only) | 1-8 | Pitch Bend (14-bit) |

**Anti-echo** : Skip si `abs(new - last) < 50` OU `elapsed < 100ms`

## Backend Rust

### Nouveaux fichiers

**`src-tauri/src/midi_manager.rs`**
```rust
pub struct MidiManager {
    // Input
    command_tx: mpsc::Sender<MidiCommand>,
    command_rx: Option<mpsc::Receiver<MidiCommand>>,
    input_connection: Option<MidiInputConnection<()>>,
    
    // Output
    output_connection: Option<MidiOutputConnection>,
    last_sent_feedback: HashMap<u8, (i16, Instant)>,
    
    // Routing
    channel_to_camera: HashMap<u8, String>,
}

impl MidiManager {
    pub fn new() -> Self;
    
    // Device enumeration
    pub fn list_input_devices() -> Result<Vec<String>>;
    pub fn list_output_devices() -> Result<Vec<String>>;
    
    // Connection
    pub fn connect_input(&mut self, device_name: &str) -> Result<()>;
    pub fn connect_output(&mut self, device_name: &str) -> Result<()>;
    pub fn disconnect_input(&mut self);
    pub fn disconnect_output(&mut self);
    
    // Output (feedback)
    pub fn send_pitch_bend_feedback(&mut self, channel: u8, zoom: f64, max_zoom: f64);
    pub fn send_note_feedback(&mut self, channel: u8, is_manual: bool);
    
    // Routing
    pub fn rebuild_routing_table(&mut self, cameras: &[CameraInfo]);
    pub fn get_camera_id_by_channel(&self, channel: u8) -> Option<&String>;
}
```

### Modifications fichiers existants

**`src-tauri/src/models.rs`**
```rust
pub struct CameraInfo {
    // ... existing fields ...
    pub midi_channel: Option<u8>, // 1-8
    pub capabilities: Option<Vec<Capability>>,
}

pub struct PersistedCamera {
    // ... existing fields ...
    midi_channel: Option<u8>,
}
```

**`src-tauri/src/camera_manager.rs`**
```rust
impl CameraManager {
    // Hook telemetry updates
    async fn on_telemetry_update(&mut self, camera_id: &str, telemetry: Telemetry) {
        // ... update status ...
        
        // Trigger MIDI feedback if manual mode
        if let Some(camera) = self.cameras.get(camera_id) {
            if camera.info.status.current.focus_mode == FocusMode::Manual {
                if let Some(channel) = camera.info.midi_channel {
                    let zoom = camera.info.status.current.zoom_factor;
                    let max_zoom = get_max_zoom(&camera.info);
                    self.midi_manager.send_pitch_bend_feedback(channel, zoom, max_zoom);
                }
            }
        }
    }
    
    pub async fn update_midi_channel(&mut self, camera_id: &str, channel: Option<u8>) -> Result<()>;
    pub fn find_next_available_midi_channel(&self) -> Option<u8>;
}
```

**`src-tauri/src/main.rs`**
```rust
#[tauri::command]
async fn list_midi_input_devices() -> Result<Vec<String>, String>;

#[tauri::command]
async fn list_midi_output_devices() -> Result<Vec<String>, String>;

#[tauri::command]
async fn connect_midi_input(device_name: String, state: State<'_, AppState>) -> Result<(), String>;

#[tauri::command]
async fn connect_midi_output(device_name: String, state: State<'_, AppState>) -> Result<(), String>;

#[tauri::command]
async fn disconnect_midi_input(state: State<'_, AppState>) -> Result<(), String>;

#[tauri::command]
async fn disconnect_midi_output(state: State<'_, AppState>) -> Result<(), String>;

#[tauri::command]
async fn update_camera_midi_channel(
    camera_id: String,
    channel: Option<u8>,
    state: State<'_, AppState>
) -> Result<(), String>;

// Spawn dispatcher thread
#[tokio::main]
async fn main() {
    // ...
    let (tx, rx) = mpsc::channel(100);
    tokio::spawn(midi_dispatcher_loop(rx, app_state.camera_manager.clone()));
    // ...
}
```

**`src-tauri/Cargo.toml`**
```toml
[dependencies]
midir = "0.10"
```

## Frontend TypeScript/Svelte

### Types (`src/lib/types/camera.ts`)
```typescript
export interface Camera {
  // ... existing fields ...
  midi_channel?: number; // 1-8 or undefined
}

export interface MidiDevice {
  id: string;
  name: string;
}
```

### Store (`src/lib/stores/midi.ts`)
```typescript
export const midiInputDevices = writable<MidiDevice[]>([]);
export const midiOutputDevices = writable<MidiDevice[]>([]);
export const selectedMidiInput = writable<string | null>(null);
export const selectedMidiOutput = writable<string | null>(null);
export const midiInputConnected = writable(false);
export const midiOutputConnected = writable(false);

export async function loadMidiDevices();
export async function connectMidiInput(deviceName: string);
export async function connectMidiOutput(deviceName: string);
export async function disconnectMidiInput();
export async function disconnectMidiOutput();
```

### UI Components

**`MidiSettingsPanel.svelte`** (nouveau)
- Section Input : dropdown devices + bouton Connect/Disconnect + status
- Section Output : dropdown devices + bouton Connect/Disconnect + status
- Note : "Output envoie feedback aux faders motorisés"

**`CameraCard.svelte`** (modifier)
- Ajouter sélecteur MIDI Channel (1-8 ou None)
- Icône MIDI si channel assigné

### API (`src/lib/utils/api.ts`)
```typescript
export async function listMidiInputDevices(): Promise<string[]>;
export async function listMidiOutputDevices(): Promise<string[]>;
export async function connectMidiInput(deviceName: string): Promise<void>;
export async function connectMidiOutput(deviceName: string): Promise<void>;
export async function disconnectMidiInput(): Promise<void>;
export async function disconnectMidiOutput(): Promise<void>;
export async function updateCameraMidiChannel(cameraId: string, channel: number | null): Promise<void>;
```

## Tests Manuels

### Test 1 : Loop Protection
1. Connect input + output
2. Move fader → zoom change
3. ✅ Pas de boucle (fader stable)
4. Move fader rapidement
5. ✅ Pas de spam MIDI

### Test 2 : Manual Mode Security
1. Caméra en mode auto
2. Bouger le fader
3. ✅ Ignoré (zoom ne change pas)
4. Appuyer Note On (C3)
5. Bouger le fader
6. ✅ Zoom change

### Test 3 : Feedback Bidirectionnel
1. Caméra en mode manual
2. Changer zoom depuis UI controller
3. ✅ Fader motorisé se synchronise
4. Appuyer Note Off (C3)
5. ✅ LED s'éteint, fader immobile

### Test 4 : Device Reconnection
1. Assigner devices
2. Déconnecter physiquement
3. ✅ Notification "Disconnected"
4. Reconnecter (peut avoir autre ID)
5. ✅ Fuzzy match réussit

### Test 5 : Persistence
1. Assigner channels aux caméras
2. Redémarrer app
3. ✅ Channels persistés dans cameras.json
4. ✅ Routing table reconstruite

## Ordre d'Implémentation

1. ✅ Persistence : `midi_channel` + `capabilities` dans models
2. ✅ MIDI Manager base : midir, list devices, connect/disconnect
3. ✅ Thread-safe input : mpsc channel + dispatcher
4. ✅ Pitch Bend codec : encode/decode 14-bit
5. ✅ Input routing : parse → route (avec check manual mode)
6. ✅ Anti-echo : last_sent_feedback + epsilon + debounce
7. ✅ Output feedback : send_pitch_bend + send_note
8. ✅ Device reconnection : fuzzy match + persist
9. ✅ Frontend store : midi.ts
10. ✅ UI components : MidiSettingsPanel + CameraCard
11. ✅ Integration : telemetry → feedback hook
12. ✅ Testing : tests manuels complets

## Références

- **Pitch Bend Spec** : 14-bit (0-16383), center=8192, LSB+MSB
- **Note C3** : MIDI note 60
- **Channels** : 1-8 (status bytes 0xE0-0xE7 pour Pitch Bend)
- **midir crate** : https://docs.rs/midir/latest/midir/


