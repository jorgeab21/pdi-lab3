#!/usr/bin/env bash
# Despliega toda la prueba de concepto con un solo comando (pensado para Cloud Shell).
set -euo pipefail
cd "$(dirname "$0")/../terraform"
if [ ! -f terraform.tfvars ]; then
  echo "Falta terraform/terraform.tfvars. Copia terraform.tfvars.example y complétalo." >&2
  exit 1
fi
# Cloud Shell ya no trae Terraform: si falta, se instala en ~/bin (una sola vez)
export PATH="$HOME/bin:$PATH"
if ! terraform version >/dev/null 2>&1; then
  echo "Instalando Terraform 1.9.8 en ~/bin ..."
  mkdir -p "$HOME/bin"
  curl -sSLo /tmp/tf.zip https://releases.hashicorp.com/terraform/1.9.8/terraform_1.9.8_linux_amd64.zip
  unzip -o -q /tmp/tf.zip -d "$HOME/bin" && rm /tmp/tf.zip
fi
PROYECTO=$(grep -E '^project_id' terraform.tfvars | cut -d'"' -f2)
gcloud config set project "$PROYECTO"
# APIs base que Terraform necesita para poder habilitar el resto
gcloud services enable cloudresourcemanager.googleapis.com serviceusage.googleapis.com iam.googleapis.com --project "$PROYECTO"
terraform init -upgrade
terraform apply -auto-approve
echo
echo "================ LISTO ================"
echo "App (ciudadano):  $(terraform output -raw url_app)"
echo "Bandeja:          $(terraform output -raw url_bandeja)"
echo "Usuario bandeja:  detective"
echo "Clave bandeja:    $(terraform output -raw bandeja_clave)"
echo "Modo IA:          $(terraform output -raw modo_ia)"
