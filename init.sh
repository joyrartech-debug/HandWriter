#!/bin/bash
set -e

echo "═══════════════════════════════════════"
echo "  HandWriter - Setup Iniziale"
echo "═══════════════════════════════════════"

# Verifica Flutter
if ! command -v flutter &> /dev/null; then
    echo "❌ Flutter non trovato. Installalo da https://flutter.dev"
    exit 1
fi

echo "✅ Flutter trovato: $(flutter --version | head -1)"

# Crea cartelle necessarie
echo ""
echo "📁 Creazione struttura cartelle..."
mkdir -p lib/config
mkdir -p lib/core/services
mkdir -p lib/features/canvas/data
mkdir -p lib/features/canvas/presentation
mkdir -p lib/features/library/data
mkdir -p lib/features/library/presentation
mkdir -p lib/shared/models
mkdir -p lib/shared/widgets
mkdir -p assets/backgrounds
mkdir -p test

echo "✅ Struttura cartelle creata"

# Installa dipendenze
echo ""
echo "📦 Installazione dipendenze..."
flutter pub get

# Genera codice (Freezed, json_serializable)
echo ""
echo "🔨 Generazione codice..."
dart run build_runner build --delete-conflicting-outputs

echo ""
echo "═══════════════════════════════════════"
echo "  ✅ Setup completato!"
echo ""
echo "  Prossimi passi:"
echo "  1. Configura il server Nextcloud nell'app"
echo "  2. flutter run"
echo "═══════════════════════════════════════"
