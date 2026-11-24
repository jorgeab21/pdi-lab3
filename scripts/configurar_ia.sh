#!/usr/bin/env bash
# Conecta la app a un modelo de Microsoft Foundry (Azure OpenAI) y redespliega.
# Pide endpoint, nombre de la implementación y clave (la clave no se muestra en pantalla),
# prueba que el modelo responda y recién entonces la guarda en terraform.tfvars (que no se sube a git).
set -euo pipefail
cd "$(dirname "$0")/.."
TFVARS=terraform/terraform.tfvars
[[ -f $TFVARS ]] || { echo "Falta $TFVARS (copia terraform.tfvars.example)"; exit 1; }

read -rp  "Endpoint de Azure OpenAI (ej. https://mi-recurso.openai.azure.com): " ENDPOINT
read -rp  "Nombre de la implementación (deployment): " DEPLOY
read -rsp "Clave de API (no se verá al pegar): " CLAVE; echo
ENDPOINT=$(echo "$ENDPOINT" | sed -E 's#(\.com)/.*#\1#; s#/+$##')   # deja solo https://xxx.openai.azure.com
API=2024-10-21

echo "Probando el modelo $DEPLOY en $ENDPOINT ..."
RESP=$(curl -s --max-time 90 -w '\n%{http_code}' "$ENDPOINT/openai/deployments/$DEPLOY/chat/completions?api-version=$API" \
  -H "api-key: $CLAVE" -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"Responde solo: OK"}]}') || RESP=$'sin conexión (¿el endpoint existe?)\n000'
CODIGO=$(tail -1 <<< "$RESP")
if [[ $CODIGO != 200 ]]; then
  echo "El modelo respondió HTTP $CODIGO:"; head -c 400 <<< "$RESP"; echo
  echo "No se guardó nada. Revisa el endpoint, la implementación o la clave."; exit 1
fi
echo "Respuesta del modelo: $(python3 -c 'import json,sys; print(json.loads(sys.stdin.read().rsplit("\n",1)[0])["choices"][0]["message"]["content"])' <<< "$RESP")"

# Reemplaza (o agrega) las variables de Azure en terraform.tfvars
grep -vE '^\s*azure_openai_(endpoint|deployment|key|api_version)\s*=' "$TFVARS" > "$TFVARS.tmp" || true
{ cat "$TFVARS.tmp"
  echo "azure_openai_endpoint    = \"$ENDPOINT\""
  echo "azure_openai_deployment  = \"$DEPLOY\""
  echo "azure_openai_api_version = \"$API\""
  echo "azure_openai_key         = \"$CLAVE\""; } > "$TFVARS"
rm -f "$TFVARS.tmp"; chmod 600 "$TFVARS"
unset CLAVE
echo "Guardado. Redesplegando con la IA de Foundry..."
./scripts/desplegar.sh
