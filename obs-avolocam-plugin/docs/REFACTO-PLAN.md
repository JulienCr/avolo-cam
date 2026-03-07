# Refacto maintenabilite du plugin OBS (4 phases)

## Phase 1 : Split du monolithe `avolocam-source.cpp`

- [x] Creer `src/test-pattern.h` + `src/test-pattern.cpp` (~370 lignes)
- [x] Creer `src/avolocam-source-data.h` (~250 lignes)
- [x] Creer `src/avolocam-pipeline.cpp` (~300 lignes)
- [x] Creer `src/avolocam-receive.cpp` (~320 lignes)
- [x] Creer `src/avolocam-decode.cpp` (~320 lignes)
- [x] Nettoyer `avolocam-source.cpp` (491 lignes restantes, -75%)
- [x] Mettre a jour `CMakeLists.txt`
- [x] Build + tests (73/73 pass)

## Phase 2 : Dedupliquer le traitement de paquets

- [x] Extraire `process_nal_units()` methode commune
- [x] Simplifier `process_packet_direct()` (35 -> 6 lignes) et `process_jitter_buffer()` (47 -> 9 lignes)
- [x] Build + tests (73/73 pass)

## Phase 3 : Unifier la gestion d'erreurs

- [x] Creer `src/source-error.h` + `src/source-error.cpp`
- [x] Migrer `init_pipeline()` -> `Result<void>`
- [x] Migrer `start()` -> `Result<void>`
- [x] Migrer `UdpReceiver::bind()` -> `Result<void>`
- [x] Mettre a jour callers dans avolocam-source.cpp
- [x] Mettre a jour `CMakeLists.txt`
- [x] Build + tests pass

## Phase 4 : Nettoyage secondaire

### 4A. Magic numbers -> constantes nommees
- [x] Creer `src/pipeline-config.h` (12 constantes)
- [x] Remplacer les litteraux dans avolocam-pipeline.cpp, avolocam-receive.cpp, avolocam-decode.cpp, udp-receiver.cpp

### 4B. Extraire logique tally
- [x] Ajouter `TallyTimers` struct + `tick_tally()` methode
- [x] Simplifier `receive_loop()`

### 4C. Securiser double buffering
- [x] Ajouter `frame_mutex` lock dans `store_cpu_frame()`
- [x] Ajouter `frame_mutex` lock dans `output_latest_frame()`

### 4D. Tests supplementaires
- [x] `tests/test_timestamp_mapper.cpp` (17 tests)
- [x] `tests/test_pipeline_integration.cpp` (14 tests)

### 4E. Simplifier CMakeLists.txt
- [x] timestamp-mapper deplace dans CORE_SOURCES pour tests
- [x] Build + tests finaux (104/104 pass)
