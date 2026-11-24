#!/usr/bin/env bash
# Envía un trámite de prueba a la URL desplegada y muestra el enlace de seguimiento.
set -euo pipefail
cd "$(dirname "$0")/../terraform"
URL=$(terraform output -raw url_app)
curl -s "$URL/salud"; echo
curl -s -X POST "$URL/tramites" \
  -F nombre="Ana Pérez" -F correo="ana@example.com" \
  -F asunto="Orden de expulsión con plazo que vence mañana" \
  -F mensaje="Recibí una orden de expulsión y el plazo vence mañana. Adjunto mi cédula." \
  | grep -oE 'PDI-[0-9]+-[0-9]+|https?://[^"<]*seguimiento\?codigo=[A-Za-z0-9_-]+' | sort -u
