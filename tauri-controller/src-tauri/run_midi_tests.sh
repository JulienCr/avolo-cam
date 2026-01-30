#!/bin/bash
# Script pour exécuter les tests MIDI fonctionnels
# Usage: ./run_midi_tests.sh [test_name]

cd "$(dirname "$0")"

echo "🎹 MIDI Integration Tests"
echo "=========================="
echo ""

# Vérifier si le port MIDI existe
echo "1. Checking MIDI port availability..."
cargo test --test midi_integration_test test_midi_port_availability -- --nocapture
echo ""

# Si un nom de test spécifique est fourni
if [ ! -z "$1" ]; then
    echo "Running specific test: $1"
    cargo test --test midi_integration_test "$1" -- --ignored --nocapture
    exit $?
fi

# Sinon, proposer un menu
echo "Select a test to run:"
echo ""
echo "  1) All tests"
echo "  2) Note receiving test"
echo "  3) Learn mode simulation"
echo "  4) Learn mode with various notes"
echo "  5) Learn timeout behavior"
echo "  0) Exit"
echo ""
read -p "Enter your choice [1-5]: " choice

case $choice in
    1)
        echo ""
        echo "Running all MIDI tests..."
        cargo test --test midi_integration_test -- --ignored --nocapture
        ;;
    2)
        echo ""
        echo "Running note receiving test..."
        cargo test --test midi_integration_test test_midi_note_receiving -- --ignored --nocapture
        ;;
    3)
        echo ""
        echo "Running learn mode simulation..."
        cargo test --test midi_integration_test test_midi_learn_mode_simulation -- --ignored --nocapture
        ;;
    4)
        echo ""
        echo "Running learn mode with various notes..."
        cargo test --test midi_integration_test test_midi_learn_mode_with_various_notes -- --ignored --nocapture
        ;;
    5)
        echo ""
        echo "Running learn timeout test..."
        cargo test --test midi_integration_test test_midi_learn_timeout_behavior -- --ignored --nocapture
        ;;
    0)
        echo "Exiting..."
        exit 0
        ;;
    *)
        echo "Invalid choice!"
        exit 1
        ;;
esac

echo ""
echo "✅ Test completed!"

