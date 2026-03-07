● Bilan qualité / maintenabilité du plugin OBS                                                                                               
                                                                                                                                             
  Score global : 6.5/10 — Solide sur les fondamentaux, mais le fichier principal est un monolithe qui freine la maintenabilité.              
                                                                                                                                             
  Ce qui est bien fait                                                                                                                       
                                                                                                                                             
  ┌─────────────────┬───────┬─────────────────────────────────────────────────────────────────────────────────────┐                          
  │     Aspect      │ Score │                                       Détail                                        │                          
  ├─────────────────┼───────┼─────────────────────────────────────────────────────────────────────────────────────┤                          
  │ Gestion mémoire │ 10/10 │ Smart pointers partout, RAII exemplaire, ComPtr pour D3D11, zéro new/delete manuels │
  ├─────────────────┼───────┼─────────────────────────────────────────────────────────────────────────────────────┤
  │ Headers         │ 8/10  │ #pragma once partout, bonnes forward declarations                                   │
  ├─────────────────┼───────┼─────────────────────────────────────────────────────────────────────────────────────┤
  │ Documentation   │ 8/10  │ Bons commentaires dans les headers, classes bien documentées                        │
  ├─────────────────┼───────┼─────────────────────────────────────────────────────────────────────────────────────┤
  │ Nommage         │ 7/10  │ snake_case cohérent, namespace avolocam::, logging structuré (ALOG macros)          │
  ├─────────────────┼───────┼─────────────────────────────────────────────────────────────────────────────────────┤
  │ Tests           │ 6/10  │ 73 tests sur le core (RTP, jitter, assembler, sync) — bon pour le noyau réseau      │
  └─────────────────┴───────┴─────────────────────────────────────────────────────────────────────────────────────┘

  Les problèmes critiques

  1. avolocam-source.cpp = 1961 lignes monolithiques
  - Fait 10+ jobs : pipeline, receive loop, decode loop, tally, test patterns, GPU state, UI properties, callbacks OBS
  - C'est le gros point noir — tout changement dans ce fichier a un blast radius énorme

  2. Gestion d'erreurs incohérente
  - Mélange de bool, std::optional, atomics (bind_result_), et log silencieux
  - Pas de type Result<T, Error> ni d'enum d'erreurs unifié
  - Des erreurs async (thread decode) pas correctement remontées

  3. Duplication dans le traitement de paquets
  - process_packet_direct() (flash mode) et process_jitter_buffer() partagent ~70% de code
  - Un fix dans un path risque d'être oublié dans l'autre

  Problèmes secondaires

  - Magic numbers : timeouts (5ms, 100ms, 2000ms), tailles de queue (1, 4, 6) éparpillés dans le code au lieu de constantes nommées
  - Tally logic mélangée dans la receive loop (30 lignes de gestion tally dans une boucle réseau de 93 lignes)
  - Double buffering decode : sémantique d'ownership pas claire entre thread decode et thread render (atomic<Frame*> + atomic<int>)
  - Pas de tests pour : décodeurs, GPU converter, WebSocket, mDNS, coordination multi-thread
  - CMakeLists.txt : 411 lignes, chemins SDK hardcodés, détection FFmpeg dupliquée

  Recommandations prioritaires

  1. Éclater avolocam-source.cpp en 4-5 fichiers (PipelineManager, DecodeQueue, TallyManager, TestPatterns, SourceCallbacks)
  2. Unifier la gestion d'erreurs avec un enum class ErrorCode et un type Result
  3. Extraire un process_nal_units() commun aux deux modes (flash/stable)
  4. Nommer les magic numbers en constantes dans un header config
  5. Ajouter des tests d'intégration avec mocks pour le réseau et le GPU