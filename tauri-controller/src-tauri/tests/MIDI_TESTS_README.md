# MIDI Integration Tests

Tests fonctionnels pour vérifier la réception de notes MIDI et le mode Learn.

## Prérequis

### macOS: Créer un port MIDI virtuel "AvoIN"

1. Ouvrir **Audio MIDI Setup** (`/Applications/Utilities/Audio MIDI Setup.app`)
2. Menu **Window** > **Show MIDI Studio**
3. Double-cliquer sur **IAC Driver**
4. Cocher **Device is online**
5. Cliquer sur **+** pour ajouter un port
6. Nommer le port: **AvoIN**
7. Cliquer sur **Apply**

### Linux: Créer un port MIDI virtuel

```bash
# Installer ALSA utilities si nécessaire
sudo apt-get install alsa-utils

# Créer un port virtuel
sudo modprobe snd-virmidi
```

### Windows: Utiliser loopMIDI

1. Télécharger et installer [loopMIDI](https://www.tobias-erichsen.de/software/loopmidi.html)
2. Créer un nouveau port virtuel nommé "AvoIN"

## Exécution des tests

### Lancer tous les tests MIDI

```bash
cd tauri-controller/src-tauri
cargo test --test midi_integration_test -- --ignored --nocapture
```

### Lancer un test spécifique

```bash
# Test de réception de notes
cargo test --test midi_integration_test test_midi_note_receiving -- --ignored --nocapture

# Test du mode Learn
cargo test --test midi_integration_test test_midi_learn_mode_simulation -- --ignored --nocapture

# Test avec diverses notes
cargo test --test midi_integration_test test_midi_learn_mode_with_various_notes -- --ignored --nocapture

# Test du timeout
cargo test --test midi_integration_test test_midi_learn_timeout_behavior -- --ignored --nocapture

# Vérifier la disponibilité du port MIDI
cargo test --test midi_integration_test test_midi_port_availability -- --nocapture
```

## Tests disponibles

### 1. `test_midi_note_receiving`
Teste la réception de différents messages MIDI :
- Note On/Off sur la note C3 (60)
- Plusieurs notes différentes (C2, G2, D3, A4)
- Messages sur différents canaux MIDI (1-8)
- Messages Pitch Bend

**Durée:** ~5 secondes

### 2. `test_midi_learn_mode_simulation`
Simule le workflow du mode Learn :
1. Activation du mode Learn
2. Envoi d'une note test (D4/62)
3. Vérification de la capture

**Durée:** ~2 secondes

### 3. `test_midi_learn_mode_with_various_notes`
Teste le mode Learn avec plusieurs notes à travers différentes octaves :
- C1, C2, C3, C4, C5, C6
- D4, A4, E5

**Durée:** ~5 secondes

### 4. `test_midi_learn_timeout_behavior`
Simule le comportement du timeout du mode Learn (10 secondes).

**Durée:** ~4 secondes (simulation raccourcie)

### 5. `test_midi_port_availability`
Liste tous les ports MIDI disponibles et vérifie la présence d'AvoIN.

**Durée:** <1 seconde

## Test manuel avec l'application

1. Démarrer l'application AvoCam Controller
2. Connecter le device MIDI Input à "AvoIN"
3. Lancer les tests (les messages seront reçus par l'application)
4. Observer les logs de l'application pour voir les messages reçus

```bash
# Dans un terminal: lancer l'app
cd tauri-controller
pnpm tauri dev

# Dans un autre terminal: lancer les tests
cd tauri-controller/src-tauri
cargo test --test midi_integration_test test_midi_note_receiving -- --ignored --nocapture
```

## Sortie attendue

```
=== Testing MIDI Note Receiving ===
Found MIDI port: IAC Driver AvoIN
Connected to MIDI port successfully

Test 1: Sending Note On (C3/60)...
Sent Note On: channel=1, note=60, velocity=127

Test 2: Sending Note Off (C3/60)...
Sent Note Off: channel=1, note=60

Test 3: Sending various notes...
Sent Note On: channel=1, note=48, velocity=100
...

✅ All MIDI messages sent successfully
```

## Troubleshooting

### "MIDI port 'AvoIN' not found"
- Vérifier que le port virtuel est créé et online
- Lancer `cargo test test_midi_port_availability -- --nocapture` pour voir tous les ports disponibles

### "Device or resource busy"
- Un autre programme utilise déjà le port MIDI
- Fermer les autres applications MIDI ou créer un nouveau port virtuel

### Les tests passent mais l'application ne reçoit rien
- Vérifier que l'application est connectée au bon device MIDI Input
- Vérifier les logs de l'application pour voir si les messages arrivent

## Notes

- Les tests sont marqués `#[ignore]` pour ne pas s'exécuter par défaut avec `cargo test`
- Utilisez `--ignored` pour les exécuter explicitement
- Utilisez `--nocapture` pour voir les messages de debug
- Les tests nécessitent que le port MIDI "AvoIN" existe et soit disponible

