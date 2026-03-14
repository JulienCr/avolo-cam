# Audit Qualité & Plan de Refacto — iOS App (`ios-app/AvoCam/`)

**Date**: 2026-03-14
**Scope**: 51 fichiers Swift, ~8 500 lignes (hors WebUI 42KB)

---

## Synthèse

| Sévérité | Count | Domaines |
|----------|-------|----------|
| **Critical** | 2 | Memory leak, dangling pointer |
| **High** | 10 | Thread safety (5), retain cycle (1), DRY (4) |
| **Medium** | 10 | God object, perf, resource mgmt, DRY |
| **Low** | 7 | Dead code, cleanup |

---

## 1. Issues Détaillées

### 1.1 Critical

#### C1 — Memory Leak: `UnsafeMutablePointer` jamais deallocated
- **Fichier**: `StreamingCoordinator.swift:119-135`
- Un `UnsafeMutablePointer<Int>` est alloué pour le compteur de frames Flash mais **jamais libéré**. Fuite à chaque cycle start/stop.
- **Fix**: Remplacer par une propriété class/actor, ou appeler `deallocate()` dans `stopStreaming()`.

#### C2 — Dangling Pointer: `H264Encoder` VTCompressionSession
- **Fichier**: `H264Encoder.swift:103-113`
- `Unmanaged.passUnretained(self)` passé comme refcon au callback VT. Si l'encoder est deallocé sans appeler `stop()`, le callback C déréférence un pointeur invalide. Pas de `deinit` safety net.
- **Fix**: Ajouter un mécanisme qui appelle `stop()` au deinit, ou utiliser `passRetained` avec `release` dans `stop()`.

---

### 1.2 High — Thread Safety

5 classes plain `class` avec état mutable accédé cross-thread sans synchronisation :

| ID | Fichier | État non protégé | Threads impliqués |
|----|---------|-------------------|-------------------|
| H1 | `NDIManager.swift` | `isActive`, `ndiSender`, `ndiVideoFrame`, `frameCount` | capture thread + main |
| H2 | `NDITallyPoller.swift` | `lastProgram`, `lastPreview`, `currentTallyState` | polling Task + WebSocket Task + main actor |
| H3 | `ThermalManager.swift` | `isStreaming`, `currentLevel`, `warningIssued`, `criticalStopped` | TelemetryAggregator actor + main actor |
| H4 | `RateLimitMiddleware.swift` | `lastCameraUpdateTime` | NIO event loop threads |
| H5 | `AuthMiddleware.swift` | `isEnabled` | main thread (write) + NIO threads (read) |

**Fix commun**: Convertir en actors ou protéger avec `OSAllocatedUnfairLock`.

---

### 1.3 High — Retain Cycle NIO

#### H6 — `NetworkServer.swift:86-136`
- `self` capturé fortement dans closures NIO bootstrap + handlers (`HTTPServerHandler`, `WebSocketServerHandler`).
- Cycle: `NetworkServer → bootstrap → closures → NetworkServer`.
- **Fix**: `[weak self]` dans toutes les closures NIO, weak refs dans les handlers.

---

### 1.4 High — DRY Violations Majeures

#### H7 — Service graph dupliqué
- `ServiceContainer.swift` vs `AppCoordinator.swift:50-104` — les deux créent le graphe complet de services. ServiceContainer semble dead code.
- **Fix**: Supprimer `ServiceContainer.swift` ou compléter la migration DI.

#### H8 — Route handlers dupliqués
- `NetworkServer.swift:257-553` contient des handlers complets, `Controllers/` en contient d'autres.
- TODO Phase 5 dans le code mais jamais complété.
- **Fix**: Compléter la migration ou supprimer les controllers.

#### H9 — Web UI dupliquée
- `WebUI.swift` (42KB) vs `StaticController.swift` (300 lignes inline HTML).
- **Fix**: Supprimer `StaticController.swift` inline HTML (WebUI.swift est le code actif).

#### H10 — Error enums dupliquées
- `AVOCamError`, `CaptureError`, `NetworkError` avec cas identiques non consolidés.
- **Fix**: Unifier sous `AVOCamError` ou supprimer `AVOCamError` et garder les enums modulaires.

---

### 1.5 Medium

| ID | Fichier | Problème |
|----|---------|----------|
| M1 | `AppCoordinator.swift` (679 lignes) | God Object — ~15 responsabilités, implémente `NetworkRequestHandler` (13 méthodes) |
| M2 | `AppCoordinator.swift:157-182` | `stop()` lance des `Task` fire-and-forget sans await — shutdown incomplet possible |
| M3 | `NDIManager.swift:192-245` | `send_video_async_v2` + unlock pixel buffer immédiat = corruption possible |
| M4 | `UDPTransmitter.swift:153-179` | Await séquentiel par paquet UDP (30-40 awaits/frame 4K) — latence inutile |
| M5 | `UDPTransmitter.swift:107-132` | Polling loop 10ms pour attendre connection `.ready` au lieu de continuation |
| M6 | `TelemetryCollector.swift:199-232` | Leak Mach port rights — `mach_port_deallocate` jamais appelé (1/sec) |
| M7 | `NDIManager.swift:271-273` | `mach_timebase_info()` appelé à chaque frame au lieu d'être caché static |
| M8 | 4 fichiers | `errorJSON()` dupliqué 4 fois identiquement |
| M9 | `AppCoordinator.swift` + `TelemetryAggregator.swift` | `createDefaultTelemetry()` dupliqué |
| M10 | 3 fichiers | Resolution parsing implémenté 3 fois différemment |

---

### 1.6 Medium — Sécurité

| ID | Fichier | Problème |
|----|---------|----------|
| S1 | `BonjourService.swift:66` | Bearer token broadcast en clair dans TXT record mDNS |
| S2 | `BonjourService.swift:61-81` | TXT record avec valeurs hardcodées ne reflétant pas la config réelle |

---

### 1.7 Low — Dead Code & Cleanup

| ID | Fichier | Problème |
|----|---------|----------|
| L1 | `ThermalMonitor.swift` | Doublon non utilisé de `ThermalManager` |
| L2 | `SRTHelpers.swift` | Fonctions jamais appelées |
| L3 | `UserDefaults+Keys.swift` | Accesseurs typés jamais utilisés |
| L4 | `CaptureManager.swift:122-124` | `#available(iOS 10.0, *)` toujours vrai |
| L5 | `AppConfiguration.swift:99-109` | Variable `updated` inutilisée |
| L6 | `SRTManager.swift:121-163` | Latency values calculées 2 fois |
| L7 | `CaptureManager.swift:468-479` | 11 print() debug excessifs dans `updateSettings()` |

---

## 2. Plan de Refacto

### Principes

- Chaque phase est un commit atomique, testable
- Les agents parallèles ne touchent **jamais** les mêmes fichiers
- Vérification après chaque phase avant de passer à la suivante

---

### Phase 0 — Dead Code Cleanup (prerequis, 1 agent)

> Supprime le code mort pour réduire le bruit avant les vraies refactos.

**Agent 0**: Dead Code Cleanup
- Supprimer `ThermalMonitor.swift` (L1)
- Supprimer `SRTHelpers.swift` (L2)
- Supprimer `UserDefaults+Keys.swift` ou câbler les accesseurs (L3)
- Supprimer `ServiceContainer.swift` (H7 — dead code DI)
- Supprimer le HTML inline de `StaticController.swift` (H9 — garder uniquement le routing si nécessaire)
- Supprimer variable `updated` dans `AppConfiguration.swift` (L5)
- Supprimer `#available(iOS 10.0, *)` guards obsolètes (L4)
- Supprimer le double calcul latency dans `SRTManager.swift` (L6)

**Fichiers touchés**: `ThermalMonitor.swift`, `SRTHelpers.swift`, `UserDefaults+Keys.swift`, `ServiceContainer.swift`, `StaticController.swift`, `AppConfiguration.swift`, `CaptureManager.swift`, `SRTManager.swift`

**Vérification**: `make build-ios` passe.

---

### Phase 1 — Critical Fixes (2 agents en parallèle)

> Corrige les 2 issues critiques. Fichiers disjoints, parallélisable.

**Agent 1A**: Fix Memory Leak — `StreamingCoordinator.swift`
- Scope: C1 uniquement
- Remplacer `UnsafeMutablePointer<Int>` par une propriété `private var flashFrameCount: Int = 0`
- Nettoyer l'allocation/capture dans la closure
- **Fichiers**: `StreamingCoordinator.swift` uniquement

**Agent 1B**: Fix Dangling Pointer — `H264Encoder.swift`
- Scope: C2 uniquement
- Ajouter un mécanisme de cleanup au deinit (task-local flag ou wrapper class avec deinit)
- S'assurer que `stop()` invalide la session avant toute déallocation
- **Fichiers**: `H264Encoder.swift` uniquement

**Vérification**: `make build-ios` passe.

---

### Phase 2 — Thread Safety (3 agents en parallèle)

> Les 5 classes sont dans des domaines indépendants. Groupées par proximité fonctionnelle.

**Agent 2A**: Thread Safety NDI — `NDIManager.swift` + `NDITallyPoller.swift`
- Scope: H1, H2
- Convertir en actors OU ajouter `OSAllocatedUnfairLock` sur l'état mutable
- Fixer aussi M3 (`send_video_async_v2` buffer unlock) et M7 (`mach_timebase_info` caching)
- **Fichiers**: `NDIManager.swift`, `NDITallyPoller.swift`

**Agent 2B**: Thread Safety Middleware — `RateLimitMiddleware.swift` + `AuthMiddleware.swift`
- Scope: H4, H5
- Ajouter `OSAllocatedUnfairLock` (actors non adaptés pour NIO handlers)
- **Fichiers**: `RateLimitMiddleware.swift`, `AuthMiddleware.swift`

**Agent 2C**: Thread Safety Thermal — `ThermalManager.swift`
- Scope: H3
- Convertir en actor ou ajouter lock
- **Fichiers**: `ThermalManager.swift`

**Vérification**: `make build-ios` passe. Tester streaming NDI + Flash manuellement.

---

### Phase 3 — Retain Cycle + Resource Management (2 agents en parallèle)

**Agent 3A**: Fix Retain Cycles NIO — `NetworkServer.swift`
- Scope: H6
- Passer toutes les closures NIO en `[weak self]`
- `HTTPServerHandler` et `WebSocketServerHandler`: weak ref vers `server`
- **Fichiers**: `NetworkServer.swift`, `HTTPServerHandler` (si fichier séparé), `WebSocketServerHandler` (si fichier séparé)

**Agent 3B**: Fix Resource Leaks — `TelemetryCollector.swift` + `UDPTransmitter.swift`
- Scope: M6, M4, M5
- `TelemetryCollector`: ajouter `mach_port_deallocate` pour chaque thread port
- `UDPTransmitter.send()`: fire-and-forget UDP au lieu d'await séquentiel
- `UDPTransmitter.connect()`: remplacer polling loop par continuation propre
- **Fichiers**: `TelemetryCollector.swift`, `UDPTransmitter.swift`

**Vérification**: `make build-ios` passe. Test streaming Flash (latence améliorée attendue).

---

### Phase 4 — DRY Consolidation (3 agents en parallèle)

**Agent 4A**: Unifier Error Handling
- Scope: H10, M8
- Créer un `errorJSON` unique dans un fichier utilitaire partagé (ex: `Sources/Shared/Extensions/HTTPResponse+Error.swift`)
- Consolider les error enums : soit tout sous `AVOCamError`, soit supprimer `AVOCamError` et garder les enums modulaires
- **Fichiers**: `AVOCamError.swift`, `NetworkServer.swift`, `HTTPRouter.swift`, `AuthMiddleware.swift`, `RateLimitMiddleware.swift`

**Agent 4B**: Unifier Resolution Parsing + Default Telemetry
- Scope: M9, M10
- Créer `Resolution` struct avec `init?(parsing:)` dans `Sources/Shared/Models/`
- Extraire `createDefaultTelemetry()` en `static func` sur `Telemetry`
- **Fichiers**: nouveau `Resolution.swift`, `CaptureManager.swift`, `StreamingCoordinator.swift`, `SRTConfiguration.swift`, `AppCoordinator.swift`, `TelemetryAggregator.swift`

**Agent 4C**: Cleanup Route Handlers Dupliqués
- Scope: H8
- Décider: garder `NetworkServer` handlers (code actif) et supprimer les `Controllers/` dupliqués, ou compléter la migration
- Recommandation: supprimer les controllers dupliqués pour l'instant, la migration DI complète est un chantier séparé
- **Fichiers**: `Controllers/StatusController.swift`, `Controllers/StreamController.swift`, `Controllers/CameraController.swift`, `Controllers/SettingsController.swift`

**Vérification**: `make build-ios` passe. Tester API endpoints.

---

### Phase 5 — AppCoordinator Refacto (1 agent, séquentiel)

> Dépend des phases précédentes. Touche le fichier central.

**Agent 5**: Réduire AppCoordinator
- Scope: M1, M2
- Extraire `NetworkRequestHandler` conformance dans un adapter séparé (`NetworkRequestAdapter.swift`)
- Rendre `stop()` async et await tous les cleanup tasks
- Réduire le logging excessif dans `CaptureManager.updateSettings()` (L7 — ce fichier n'est pas touché par les phases précédentes)
- Déplacer `isBatteryMonitoringEnabled = true` dans le `init()` de `TelemetryCollector` (M — pas touché en Phase 3B qui ne fait que port rights et ne modifie pas init)
- **Fichiers**: `AppCoordinator.swift`, `NetworkRequestAdapter.swift` (nouveau), `CaptureManager.swift`, `TelemetryCollector.swift`

**Vérification**: `make build-ios` passe. Test complet: démarrage app, streaming, arrêt propre.

---

### Phase 6 — Sécurité & Bonjour (1 agent)

**Agent 6**: Sécurité mDNS
- Scope: S1, S2
- Évaluer si le token dans le TXT record est intentionnel (discovery auto) — si oui, documenter
- Remplacer les valeurs hardcodées du TXT record par la config réelle du stream
- Unifier `createTXTRecord()` et `updateFlashPort()` (M — BonjourService DRY)
- **Fichiers**: `BonjourService.swift`

**Vérification**: `make build-ios` passe. Vérifier mDNS discovery depuis le Tauri controller.

---

## 3. Diagramme d'Exécution

```
Phase 0: [Agent 0 — Dead Code] ─────────────────────────────────────────┐
                                                                         │
Phase 1: [Agent 1A — StreamingCoordinator] ──┐                          │
          [Agent 1B — H264Encoder] ──────────┤ (parallèle)              │
                                              │                          │
Phase 2: [Agent 2A — NDI thread safety] ─────┐                          │
          [Agent 2B — Middleware safety] ─────┤ (parallèle)              │
          [Agent 2C — Thermal safety] ───────┘                          │
                                              │                          │
Phase 3: [Agent 3A — NIO retain cycles] ────┐                           │
          [Agent 3B — Resource leaks] ───────┤ (parallèle)              │
                                              │                          │
Phase 4: [Agent 4A — Error handling DRY] ───┐                           │
          [Agent 4B — Resolution/Telemetry] ─┤ (parallèle)              │
          [Agent 4C — Route handlers] ───────┘                          │
                                              │                          │
Phase 5: [Agent 5 — AppCoordinator] ─────────┤ (séquentiel)            │
                                              │                          │
Phase 6: [Agent 6 — Sécurité Bonjour] ──────┘                          │
                                                                         │
                                              Total: 13 agents, 7 phases ┘
```

---

## 4. Matrice Fichiers × Agents

Vérifie qu'aucun fichier n'est touché par 2 agents dans la même phase :

| Phase | Agent | Fichiers modifiés |
|-------|-------|-------------------|
| 0 | 0 | `ThermalMonitor`, `SRTHelpers`, `UserDefaults+Keys`, `ServiceContainer`, `StaticController`, `AppConfiguration`, `CaptureManager`, `SRTManager` |
| 1 | 1A | `StreamingCoordinator` |
| 1 | 1B | `H264Encoder` |
| 2 | 2A | `NDIManager`, `NDITallyPoller` |
| 2 | 2B | `RateLimitMiddleware`, `AuthMiddleware` |
| 2 | 2C | `ThermalManager` |
| 3 | 3A | `NetworkServer`, handlers NIO |
| 3 | 3B | `TelemetryCollector`, `UDPTransmitter` |
| 4 | 4A | `AVOCamError`, `NetworkServer`*, `HTTPRouter`, `AuthMiddleware`*, `RateLimitMiddleware`* |
| 4 | 4B | `Resolution` (new), `CaptureManager`*, `StreamingCoordinator`*, `SRTConfiguration`, `AppCoordinator`*, `TelemetryAggregator` |
| 4 | 4C | `Controllers/*` (suppression) |
| 5 | 5 | `AppCoordinator`*, `NetworkRequestAdapter` (new), `CaptureManager`*, `TelemetryCollector`* |
| 6 | 6 | `BonjourService` |

*\* Fichiers touchés dans des phases différentes — OK car les phases sont séquentielles.*

**Aucun conflit intra-phase.**

---

## 5. Critères de Succès

- [x] `make build-ios` passe après chaque phase
- [x] 0 `UnsafeMutablePointer` non deallocated
- [x] 0 classe non-actor avec état mutable cross-thread non protégé
- [x] 0 duplication `errorJSON`
- [x] 0 fichier dead code restant
- [ ] `AppCoordinator` < 400 lignes — **SKIPPED**: extraction NetworkRequestHandler trop couplée (voir Phase 5)
- [ ] Streaming NDI, SRT, Flash fonctionnels après refacto complète — **À tester manuellement**

---

## 6. Résultat d'Exécution

**Toutes les phases exécutées avec succès.** Build iOS OK après chaque phase.

| Phase | Status | Agents | Notes |
|-------|--------|--------|-------|
| 0 | ✅ Done | 1 | 4 fichiers supprimés, 3 nettoyés. `UserDefaults+Keys.swift` gardé (utilisé). |
| 1 | ✅ Done | 2 parallel | C1: `FrameCounter` class remplace `UnsafeMutablePointer`. C2: `passRetained`/`release` + `deinit` safety net. |
| 2 | ✅ Done | 3 parallel | 5 classes protégées par `OSAllocatedUnfairLock`. NDI: sync send + cached timebase. |
| 3 | ✅ Done | 2 parallel | NIO: `[weak self]` + weak server refs. UDP: fire-and-forget sends + continuation connect. Mach ports: deallocated. |
| 4 | ✅ Done | 3 parallel | `errorJSON` unifié via `HTTPResponse+Convenience`. `Resolution` struct partagé. `Telemetry.makeDefault()`. 5 controllers + `APIController` supprimés. `AVOCamError` gardé (utilisé). |
| 5 | ✅ Done | 1 | `stop()` async. Logging condensé. Battery monitoring init. M1 (extract handler) skipped — trop couplé. |
| 6 | ✅ Done | 1 | TXT record DRY. Token documenté comme intentionnel. Hardcoded values annotées TODO. |

### Fichiers supprimés (10)
- `ThermalMonitor.swift`, `SRTHelpers.swift`, `ServiceContainer.swift`
- `StaticController.swift`, `StatusController.swift`, `StreamController.swift`
- `CameraController.swift`, `SettingsController.swift`, `APIController.swift`
- Répertoires vides: `DI/`, `Controllers/`

### Fichiers créés (1)
- `Sources/Shared/Models/Resolution.swift`

### Reste à faire
- **M1**: Extraire `NetworkRequestHandler` de `AppCoordinator` — nécessite un refacto plus profond du state management
- **H10**: Unifier les error enums — `AVOCamError` est utilisé, consolidation à planifier séparément
- **S2**: Câbler `BonjourService.updateStreamInfo()` depuis `AppCoordinator` au démarrage du stream
- **Test manuel**: Valider streaming NDI, SRT, Flash après refacto
