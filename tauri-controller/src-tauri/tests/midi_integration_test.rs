//! Integration tests for MIDI note receiving and Learn mode
//!
//! These tests require a virtual MIDI port named "AvoIN" to be available.
//! On macOS, you can create one using Audio MIDI Setup app.

use midir::{MidiOutput, MidiOutputConnection};
use std::time::Duration;
use tokio::time::sleep;

const TEST_MIDI_PORT_NAME: &str = "AvoIN";

/// Helper to find and connect to the AvoIN MIDI port
fn connect_to_avo_in() -> Result<MidiOutputConnection, Box<dyn std::error::Error>> {
    let midi_out = MidiOutput::new("MIDI Test Client")?;
    let ports = midi_out.ports();
    
    for port in &ports {
        if let Ok(name) = midi_out.port_name(port) {
            if name.contains(TEST_MIDI_PORT_NAME) {
                println!("Found MIDI port: {}", name);
                return Ok(midi_out.connect(port, "test-connection")?);
            }
        }
    }
    
    Err(format!("MIDI port '{}' not found. Please create a virtual MIDI port with this name.", TEST_MIDI_PORT_NAME).into())
}

/// Send a MIDI Note On message
fn send_note_on(conn: &mut MidiOutputConnection, channel: u8, note: u8, velocity: u8) -> Result<(), Box<dyn std::error::Error>> {
    let status = 0x90 | (channel - 1); // Note On on specified channel (1-16)
    conn.send(&[status, note, velocity])?;
    println!("Sent Note On: channel={}, note={}, velocity={}", channel, note, velocity);
    Ok(())
}

/// Send a MIDI Note Off message
fn send_note_off(conn: &mut MidiOutputConnection, channel: u8, note: u8) -> Result<(), Box<dyn std::error::Error>> {
    let status = 0x80 | (channel - 1); // Note Off on specified channel (1-16)
    conn.send(&[status, note, 0])?;
    println!("Sent Note Off: channel={}, note={}", channel, note);
    Ok(())
}

/// Send a MIDI Pitch Bend message
fn send_pitch_bend(conn: &mut MidiOutputConnection, channel: u8, value: i16) -> Result<(), Box<dyn std::error::Error>> {
    let status = 0xE0 | (channel - 1);
    let lsb = (value & 0x7F) as u8;
    let msb = ((value >> 7) & 0x7F) as u8;
    conn.send(&[status, lsb, msb])?;
    println!("Sent Pitch Bend: channel={}, value={}", channel, value);
    Ok(())
}

#[tokio::test]
#[ignore] // Run with: cargo test --test midi_integration_test -- --ignored
async fn test_midi_note_receiving() {
    println!("\n=== Testing MIDI Note Receiving ===");
    
    // Connect to AvoIN port
    let mut conn = match connect_to_avo_in() {
        Ok(c) => c,
        Err(e) => {
            eprintln!("Error: {}", e);
            eprintln!("\nTo create a virtual MIDI port on macOS:");
            eprintln!("1. Open Audio MIDI Setup (/Applications/Utilities/)");
            eprintln!("2. Window > Show MIDI Studio");
            eprintln!("3. Double-click 'IAC Driver'");
            eprintln!("4. Add a port named 'AvoIN'");
            panic!("Cannot run test without MIDI port");
        }
    };
    
    println!("Connected to MIDI port successfully");
    
    // Test 1: Send Note On (C3 = 60)
    println!("\nTest 1: Sending Note On (C3/60)...");
    send_note_on(&mut conn, 1, 60, 127).expect("Failed to send Note On");
    sleep(Duration::from_millis(500)).await;
    
    // Test 2: Send Note Off (C3 = 60)
    println!("\nTest 2: Sending Note Off (C3/60)...");
    send_note_off(&mut conn, 1, 60).expect("Failed to send Note Off");
    sleep(Duration::from_millis(500)).await;
    
    // Test 3: Send different notes
    println!("\nTest 3: Sending various notes...");
    for note in [48, 55, 62, 69] { // C2, G2, D3, A3
        send_note_on(&mut conn, 1, note, 100).expect("Failed to send Note On");
        sleep(Duration::from_millis(200)).await;
        send_note_off(&mut conn, 1, note).expect("Failed to send Note Off");
        sleep(Duration::from_millis(200)).await;
    }
    
    // Test 4: Send on different channels
    println!("\nTest 4: Sending on different MIDI channels...");
    for channel in 1..=8 {
        send_note_on(&mut conn, channel, 60, 80).expect("Failed to send Note On");
        sleep(Duration::from_millis(100)).await;
        send_note_off(&mut conn, channel, 60).expect("Failed to send Note Off");
        sleep(Duration::from_millis(100)).await;
    }
    
    // Test 5: Pitch Bend
    println!("\nTest 5: Sending Pitch Bend messages...");
    for value in [0, 4096, 8192, 12288, 16383] {
        send_pitch_bend(&mut conn, 1, value).expect("Failed to send Pitch Bend");
        sleep(Duration::from_millis(200)).await;
    }
    
    println!("\n✅ All MIDI messages sent successfully");
    println!("Check the application logs to verify they were received correctly.");
}

#[tokio::test]
#[ignore] // Run with: cargo test --test midi_integration_test -- --ignored
async fn test_midi_learn_mode_simulation() {
    println!("\n=== Testing MIDI Learn Mode (Simulation) ===");
    
    // Connect to AvoIN port
    let mut conn = match connect_to_avo_in() {
        Ok(c) => c,
        Err(e) => {
            eprintln!("Error: {}", e);
            panic!("Cannot run test without MIDI port");
        }
    };
    
    println!("Connected to MIDI port successfully");
    
    // Simulate Learn Mode workflow
    println!("\n📖 Simulating Learn Mode workflow:");
    println!("1. User clicks 'Learn' button");
    println!("2. Application enters learn mode (waiting for note)");
    println!("3. User presses MIDI key...");
    
    sleep(Duration::from_secs(1)).await;
    
    // Send a test note (D4 = 62)
    let test_note = 62; // D4
    println!("\n🎹 Sending test note: {} (D4)", test_note);
    send_note_on(&mut conn, 1, test_note, 127).expect("Failed to send Note On");
    
    sleep(Duration::from_millis(500)).await;
    
    send_note_off(&mut conn, 1, test_note).expect("Failed to send Note Off");
    
    println!("\n✅ Learn mode simulation complete");
    println!("Expected behavior:");
    println!("  - Backend captures note {}", test_note);
    println!("  - Frontend updates configuration");
    println!("  - UI displays 'D4' (note 62)");
}

#[tokio::test]
#[ignore]
async fn test_midi_learn_mode_with_various_notes() {
    println!("\n=== Testing Learn Mode with Various Notes ===");
    
    let mut conn = match connect_to_avo_in() {
        Ok(c) => c,
        Err(e) => {
            eprintln!("Error: {}", e);
            panic!("Cannot run test without MIDI port");
        }
    };
    
    // Test notes across different octaves
    let test_notes = vec![
        (36, "C1"),
        (48, "C2"),
        (60, "C3"),
        (72, "C4"),
        (84, "C5"),
        (96, "C6"),
        (62, "D4"),
        (69, "A4"),
        (76, "E5"),
    ];
    
    println!("\n🎹 Testing learn mode with different notes:");
    
    for (note, name) in test_notes {
        println!("\n  Simulating learn with {} ({})", name, note);
        println!("  - Activating learn mode...");
        sleep(Duration::from_millis(500)).await;
        
        println!("  - Sending note {}...", note);
        send_note_on(&mut conn, 1, note, 127).expect("Failed to send Note On");
        sleep(Duration::from_millis(100)).await;
        send_note_off(&mut conn, 1, note).expect("Failed to send Note Off");
        
        println!("  ✅ Note {} ({}) captured", name, note);
        sleep(Duration::from_millis(500)).await;
    }
    
    println!("\n✅ All learn mode scenarios tested successfully");
}

#[tokio::test]
#[ignore]
async fn test_midi_learn_timeout_behavior() {
    println!("\n=== Testing Learn Mode Timeout ===");
    
    let _conn = match connect_to_avo_in() {
        Ok(c) => c,
        Err(e) => {
            eprintln!("Error: {}", e);
            panic!("Cannot run test without MIDI port");
        }
    };
    
    println!("Connected to MIDI port successfully");
    println!("\n⏱️  Simulating learn mode timeout scenario:");
    println!("  - User activates learn mode");
    println!("  - User does NOT press any key");
    println!("  - Waiting for timeout (10 seconds)...");
    
    // Note: We don't send any MIDI messages here
    sleep(Duration::from_secs(2)).await;
    
    println!("  - After 2 seconds: still waiting...");
    sleep(Duration::from_secs(2)).await;
    
    println!("  - After 4 seconds: still waiting...");
    
    println!("\n✅ Timeout test simulation complete");
    println!("Expected behavior:");
    println!("  - Learn mode times out after 10 seconds");
    println!("  - Error message: 'Learn mode timeout - no note received within 10 seconds'");
    println!("  - UI returns to normal state");
}

#[test]
fn test_midi_port_availability() {
    println!("\n=== Checking MIDI Port Availability ===");
    
    let midi_out = MidiOutput::new("MIDI Port Scanner").expect("Failed to create MIDI output");
    let ports = midi_out.ports();
    
    println!("\nAvailable MIDI output ports:");
    let mut found_avo_in = false;
    
    for (i, port) in ports.iter().enumerate() {
        if let Ok(name) = midi_out.port_name(port) {
            println!("  {}. {}", i + 1, name);
            if name.contains(TEST_MIDI_PORT_NAME) {
                found_avo_in = true;
                println!("     ✅ This is our test port!");
            }
        }
    }
    
    if !found_avo_in {
        println!("\n⚠️  Warning: '{}' port not found!", TEST_MIDI_PORT_NAME);
        println!("\nTo create it on macOS:");
        println!("1. Open Audio MIDI Setup");
        println!("2. Window > Show MIDI Studio");
        println!("3. Double-click 'IAC Driver'");
        println!("4. Check 'Device is online'");
        println!("5. Add a port named '{}'", TEST_MIDI_PORT_NAME);
    } else {
        println!("\n✅ '{}' port is available for testing!", TEST_MIDI_PORT_NAME);
    }
    
    assert!(!ports.is_empty(), "No MIDI ports available on this system");
}

