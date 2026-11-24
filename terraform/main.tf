# =============================================================================
# PDI · Trámites migratorios — Infraestructura como código (Lab 3, TICS413)
# Crea en GCP (región Santiago) todo lo que necesita la prueba de concepto:
# APIs, Artifact Registry, imagen del contenedor, Cloud Storage, Pub/Sub,
# Cloud SQL PostgreSQL, Secret Manager, cuenta de servicio y Cloud Run.
# La IA se consume desde Microsoft Foundry (Azure OpenAI) con la clave guardada en Secret Manager.
# =============================================================================

terraform {
  required_version = ">= 1.5"
  required_providers {
    google = { source = "hashicorp/google", version = "~> 6.0" }
    random = { source = "hashicorp/random", version = "~> 3.6" }
    null   = { source = "hashicorp/null", version = "~> 3.2" }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

locals {
  nombre    = "pdi-tramites"
  imagen    = "${var.region}-docker.pkg.dev/${var.project_id}/${local.nombre}/app:${substr(local.hash_app, 0, 12)}"
  hash_app  = sha1(join("", [for f in sort(fileset("${path.module}/../app", "**")) : filesha1("${path.module}/../app/${f}") if !startswith(f, "__pycache__") && f != "local.db"]))
  usa_azure = nonsensitive(var.azure_openai_key != "")
  prioridades = ["alta", "media", "baja"]
}

# ----------------------------------------------------------------- APIs
resource "google_project_service" "apis" {
  for_each = toset([
    "run.googleapis.com", "artifactregistry.googleapis.com", "sqladmin.googleapis.com",
    "pubsub.googleapis.com", "secretmanager.googleapis.com", "storage.googleapis.com", "iam.googleapis.com",
    "cloudbuild.googleapis.com", "aiplatform.googleapis.com",
  ])
  service            = each.value
  disable_on_destroy = false
}

# ----------------------------------------------------------------- contenedor
resource "google_artifact_registry_repository" "repo" {
  repository_id = local.nombre
  location      = var.region
  format        = "DOCKER"
  depends_on    = [google_project_service.apis]
}

# Construye y sube la imagen de la app con Cloud Build cada vez que cambia el código.
resource "null_resource" "imagen" {
  triggers = { imagen = local.imagen }
  provisioner "local-exec" {
    command = <<-EOT
      set -e
      gcloud builds submit ${path.module}/../app --tag ${local.imagen} --project ${var.project_id} --quiet
    EOT
  }
  depends_on = [google_artifact_registry_repository.repo, google_project_iam_member.build]
}

# Cloud Build corre con la cuenta de servicio de Compute por defecto: necesita subir la imagen y leer el código.
data "google_project" "this" {}

resource "google_project_iam_member" "build" {
  for_each   = toset(["roles/cloudbuild.builds.builder", "roles/artifactregistry.writer", "roles/storage.objectAdmin", "roles/logging.logWriter"])
  project    = var.project_id
  role       = each.value
  member     = "serviceAccount:${data.google_project.this.number}-compute@developer.gserviceaccount.com"
  depends_on = [google_project_service.apis]
}

# ----------------------------------------------------------------- Cloud Storage (adjuntos)
resource "google_storage_bucket" "adjuntos" {
  name                        = "${var.project_id}-adjuntos"
  location                    = var.region
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = true
  lifecycle_rule {
    condition { age = 90 }
    action {
      type          = "SetStorageClass"
      storage_class = "NEARLINE"
    }
  }
  depends_on = [google_project_service.apis]
}

# ----------------------------------------------------------------- Pub/Sub
resource "google_pubsub_topic" "ingesta" {
  name       = "tramites-ingesta"
  depends_on = [google_project_service.apis]
}

resource "google_pubsub_topic" "prioridad" {
  for_each   = toset(local.prioridades)
  name       = "tramites-prioridad-${each.value}"
  depends_on = [google_project_service.apis]
}

# Suscripción de ejemplo por prioridad (para mostrar los mensajes en la consola / demo).
resource "google_pubsub_subscription" "prioridad" {
  for_each                   = google_pubsub_topic.prioridad
  name                       = "${each.value.name}-bandeja"
  topic                      = each.value.id
  message_retention_duration = "86400s"
}

resource "random_password" "pubsub_token" {
  length  = 32
  special = false
}

# Pub/Sub empuja cada trámite nuevo a Cloud Run para procesarlo (asíncrono, con reintentos).
resource "google_pubsub_subscription" "ingesta_push" {
  name                 = "tramites-ingesta-push"
  topic                = google_pubsub_topic.ingesta.id
  ack_deadline_seconds = 120
  push_config {
    push_endpoint = "${google_cloud_run_v2_service.app.uri}/pubsub/procesar?token=${random_password.pubsub_token.result}"
  }
  retry_policy {
    minimum_backoff = "10s"
    maximum_backoff = "300s"
  }
}

# ----------------------------------------------------------------- Cloud SQL (PostgreSQL)
resource "random_password" "db" {
  length  = 24
  special = false
}

resource "google_sql_database_instance" "db" {
  name                = "${local.nombre}-db"
  database_version    = "POSTGRES_15"
  region              = var.region
  deletion_protection = false
  settings {
    edition           = "ENTERPRISE"
    tier              = "db-f1-micro"
    availability_type = "ZONAL" # PoC: zonal. En PROD real sería REGIONAL (alta disponibilidad).
    disk_size         = 10
    disk_type         = "PD_SSD"
    ip_configuration {
      ipv4_enabled = true # sin redes autorizadas: solo se entra con el conector de Cloud SQL (IAM)
      ssl_mode     = "ENCRYPTED_ONLY"
    }
    backup_configuration { enabled = false }
  }
  depends_on = [google_project_service.apis]
}

resource "google_sql_database" "tramites" {
  name     = "tramites"
  instance = google_sql_database_instance.db.name
}

resource "google_sql_user" "app" {
  name     = "pdi"
  instance = google_sql_database_instance.db.name
  password = random_password.db.result
}

# ----------------------------------------------------------------- Secret Manager
resource "random_password" "bandeja" {
  length  = 12
  special = false
}

resource "google_secret_manager_secret" "s" {
  for_each  = toset(concat(["db-password", "bandeja-clave"], local.usa_azure ? ["azure-openai-key"] : []))
  secret_id = each.value
  replication {
    auto {}
  }
  depends_on = [google_project_service.apis]
}

resource "google_secret_manager_secret_version" "v" {
  for_each = google_secret_manager_secret.s
  secret   = each.value.id
  secret_data = {
    "db-password"      = random_password.db.result
    "bandeja-clave"    = random_password.bandeja.result
    "azure-openai-key" = var.azure_openai_key
  }[each.key]
}

# ----------------------------------------------------------------- identidad de la app
resource "google_service_account" "app" {
  account_id   = "pdi-tramites-app"
  display_name = "Cloud Run · PDI trámites"
}

resource "google_project_iam_member" "app" {
  for_each = toset(["roles/cloudsql.client", "roles/pubsub.publisher", "roles/secretmanager.secretAccessor", "roles/logging.logWriter", "roles/aiplatform.user"])
  project  = var.project_id
  role     = each.value
  member   = "serviceAccount:${google_service_account.app.email}"
}

resource "google_storage_bucket_iam_member" "app" {
  bucket = google_storage_bucket.adjuntos.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.app.email}"
}

# ----------------------------------------------------------------- Cloud Run
resource "google_cloud_run_v2_service" "app" {
  name                = local.nombre
  location            = var.region
  ingress             = "INGRESS_TRAFFIC_ALL"
  deletion_protection = false

  template {
    service_account = google_service_account.app.email
    scaling {
      min_instance_count = 0
      max_instance_count = 10
    }
    volumes {
      name = "cloudsql"
      cloud_sql_instance { instances = [google_sql_database_instance.db.connection_name] }
    }
    containers {
      image = local.imagen
      resources {
        limits   = { cpu = "1", memory = "512Mi" }
        cpu_idle = true # facturación por petición
      }
      volume_mounts {
        name       = "cloudsql"
        mount_path = "/cloudsql"
      }
      env {
        name  = "GOOGLE_CLOUD_PROJECT"
        value = var.project_id
      }
      env {
        name  = "BUCKET"
        value = google_storage_bucket.adjuntos.name
      }
      env {
        name  = "TOPIC_INGESTA"
        value = google_pubsub_topic.ingesta.name
      }
      env {
        name  = "PUBSUB_TOKEN"
        value = random_password.pubsub_token.result
      }
      env {
        name  = "DB_PASSWORD"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.s["db-password"].secret_id
            version = "latest"
          }
        }
      }
      env {
        name  = "DB_SOCKET"
        value = "/cloudsql/${google_sql_database_instance.db.connection_name}/.s.PGSQL.5432"
      }
      env {
        name = "BANDEJA_CLAVE"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.s["bandeja-clave"].secret_id
            version = "latest"
          }
        }
      }
      env {
        name  = "VERTEX_MODEL"
        value = var.vertex_model
      }
      env {
        name  = "VERTEX_LOCATION"
        value = var.vertex_location
      }
      env {
        name  = "AZURE_OPENAI_ENDPOINT"
        value = var.azure_openai_endpoint
      }
      env {
        name  = "AZURE_OPENAI_DEPLOYMENT"
        value = var.azure_openai_deployment
      }
      env {
        name  = "AZURE_OPENAI_API_VERSION"
        value = var.azure_openai_api_version
      }
      dynamic "env" {
        for_each = local.usa_azure ? [1] : []
        content {
          name = "AZURE_OPENAI_KEY"
          value_source {
            secret_key_ref {
              secret  = google_secret_manager_secret.s["azure-openai-key"].secret_id
              version = "latest"
            }
          }
        }
      }
    }
  }
  depends_on = [null_resource.imagen, google_project_iam_member.app, google_secret_manager_secret_version.v, google_sql_user.app, google_sql_database.tramites, google_storage_bucket_iam_member.app]
}

# Acceso público a la URL (el portal del ciudadano es público; la bandeja pide usuario y clave).
resource "google_cloud_run_v2_service_iam_member" "publico" {
  name     = google_cloud_run_v2_service.app.name
  location = var.region
  role     = "roles/run.invoker"
  member   = "allUsers"
}
