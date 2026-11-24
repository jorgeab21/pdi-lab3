#!/usr/bin/env bash
# Pruebas de punta a punta y de errores contra la URL desplegada.
# Uso: ./scripts/pruebas_e2e.sh   (desde la carpeta del proyecto, después de desplegar.sh)
set -uo pipefail
RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
cd "$RAIZ/terraform"
URL=$(terraform output -raw url_app)
CLAVE=$(terraform output -raw bandeja_clave)
PROYECTO=$(terraform output -raw cloud_sql | cut -d: -f1)
TMP=$(mktemp -d)
OK=0; FALLA=0
check() { # check "descripción" valor_obtenido valor_esperado
  if [[ "$2" == "$3" ]]; then echo "  OK    $1"; OK=$((OK+1)); else echo "  FALLA $1 (obtuvo '$2', esperaba '$3')"; FALLA=$((FALLA+1)); fi
}
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }

echo "== 1. Salud"
curl -s "$URL/salud"; echo
check "GET /salud responde 200" "$(code "$URL/salud")" 200

echo "== 2. Ciudadano envía un trámite con documento adjunto"
DOC="$RAIZ/ejemplos/documento_ejemplo.png"   # documento ficticio para probar el OCR
if [[ -f $DOC ]]; then cp "$DOC" "$TMP/cedula.png"; else
python3 - "$TMP/cedula.png" <<'EOF'
import base64, sys
open(sys.argv[1], "wb").write(base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="))
EOF
fi
curl -s -X POST "$URL/tramites" \
  -F nombre="Ana Pérez" -F correo="ana@example.com" \
  -F asunto="Orden de expulsión con plazo que vence mañana" \
  -F mensaje="Recibí una orden de expulsión y el plazo para presentar descargos vence mañana. Adjunto mi cédula." \
  -F "documento=@$TMP/cedula.png;type=image/png" > "$TMP/recibido.html"
NUMERO=$(grep -oE 'PDI-[0-9]{4}-[0-9]+' "$TMP/recibido.html" | head -1)
CODIGO=$(grep -oE 'seguimiento\?codigo=[A-Za-z0-9_-]+' "$TMP/recibido.html" | head -1 | cut -d= -f2)
echo "  Número: $NUMERO   Código: $CODIGO"
check "se generó número de trámite" "$([[ -n $NUMERO ]] && echo si)" si

echo "== 3. Pub/Sub → clasificación (espera hasta 60 s)"
ESTADO=""
for i in $(seq 1 20); do
  sleep 3
  curl -s "$URL/seguimiento?codigo=$CODIGO" > "$TMP/seg.html"
  if grep -q "Clasificado" "$TMP/seg.html"; then ESTADO=Clasificado; break; fi
done
check "el trámite pasó a Clasificado vía Pub/Sub" "$ESTADO" Clasificado

echo "== 4. Bandeja del detective (autenticación)"
check "bandeja sin credenciales → 401" "$(code "$URL/bandeja")" 401
check "bandeja con clave errónea → 401" "$(code -u detective:malaclave "$URL/bandeja")" 401
check "bandeja con clave correcta → 200" "$(code -u "detective:$CLAVE" "$URL/bandeja")" 200
ID=$(curl -s -u "detective:$CLAVE" "$URL/bandeja" | grep -oE "/bandeja/[0-9]+\">$NUMERO" | grep -oE '[0-9]+' | head -1)
check "el trámite aparece en la bandeja" "$([[ -n $ID ]] && echo si)" si
check "detalle del trámite → 200" "$(code -u "detective:$CLAVE" "$URL/bandeja/$ID")" 200
echo "  --- Resultado de la IA ---"
curl -s -u "detective:$CLAVE" "$URL/bandeja/$ID" | python3 -c 'import sys,re,html; t=re.sub(r"<[^>]+>"," ",sys.stdin.read()); t=html.unescape(re.sub(r"\s+"," ",t)); i=max(t.find("Resumen IA"),0); print("  "+t[i:i+900])'

check "documento adjunto descargable → 200" "$(code -u "detective:$CLAVE" "$URL/bandeja/$ID/documento")" 200
check "cambiar estado a 'En revisión' → 303" "$(code -u "detective:$CLAVE" -X POST --data-urlencode "estado=En revisión" "$URL/bandeja/$ID/estado")" 303
check "seguimiento refleja 'En revisión'" "$(curl -s "$URL/seguimiento?codigo=$CODIGO" | grep -c 'En revisión' | sed 's/^[1-9][0-9]*$/si/')" si

echo "== 5. Casos de error"
check "estado inválido → 400" "$(code -u "detective:$CLAVE" -X POST -d "estado=Borrado" "$URL/bandeja/$ID/estado")" 400
check "trámite inexistente → 404" "$(code -u "detective:$CLAVE" "$URL/bandeja/999999")" 404
check "seguimiento con código falso → 404" "$(code "$URL/seguimiento?codigo=codigo-falso")" 404
check "formulario incompleto → 422" "$(code -X POST -F nombre=X "$URL/tramites")" 422
head -c 9000000 /dev/urandom > "$TMP/grande.pdf"
check "adjunto de 9 MB → 413" "$(code -X POST -F nombre=X -F correo=x@x.cl -F asunto=a -F mensaje=m -F "documento=@$TMP/grande.pdf;type=application/pdf" "$URL/tramites")" 413
check "push de Pub/Sub sin token → 403" "$(code -X POST -H 'Content-Type: application/json' -d '{}' "$URL/pubsub/procesar")" 403

echo "== 6. Mensaje en el tópico de prioridad (cola del detective)"
for p in alta media baja; do
  DATOS=$(gcloud pubsub subscriptions pull "tramites-prioridad-$p-bandeja" --project "$PROYECTO" --auto-ack --limit 10 \
    --format='value(message.data)' 2>/dev/null)
  DEC=$(echo "$DATOS" | while read -r l; do echo "$l" | base64 -d 2>/dev/null; echo; done)
  if grep -q "$NUMERO" <<< "$DATOS$DEC"; then echo "  mensaje encontrado en tramites-prioridad-$p"; PRIO=$p; fi
done
check "el clasificador publicó en un tópico de prioridad" "$([[ -n ${PRIO:-} ]] && echo si)" si

rm -rf "$TMP"
echo
echo "Resultado: $OK OK, $FALLA FALLA"
[[ $FALLA -eq 0 ]]
