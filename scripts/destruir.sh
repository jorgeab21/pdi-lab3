#!/usr/bin/env bash
# Borra TODA la infraestructura creada (para no gastar créditos después de presentar).
set -euo pipefail
cd "$(dirname "$0")/../terraform"
terraform destroy -auto-approve
