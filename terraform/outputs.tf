output "url_app" {
  description = "URL pública de la prueba de concepto"
  value       = google_cloud_run_v2_service.app.uri
}

output "url_bandeja" {
  value = "${google_cloud_run_v2_service.app.uri}/bandeja"
}

output "bandeja_usuario" {
  value = "detective"
}

output "bandeja_clave" {
  description = "Ver con: terraform output -raw bandeja_clave"
  value       = random_password.bandeja.result
  sensitive   = true
}

output "bucket_adjuntos" {
  value = google_storage_bucket.adjuntos.name
}

output "cloud_sql" {
  value = google_sql_database_instance.db.connection_name
}

output "modo_ia" {
  value = local.usa_azure ? "Microsoft Foundry (${var.azure_openai_deployment})" : (var.vertex_model != "" ? "Gemini en Vertex AI (${var.vertex_model})" : "simulado")
}
