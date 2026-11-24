variable "project_id" {
  description = "ID del proyecto de GCP (ej.: pdi-lab3-515621)"
  type        = string
}

variable "region" {
  description = "Región de GCP. Santiago, igual que en el Lab 2."
  type        = string
  default     = "southamerica-west1"
}

variable "azure_openai_endpoint" {
  description = "Endpoint del recurso de Microsoft Foundry / Azure OpenAI (ej.: https://mi-recurso.openai.azure.com/)"
  type        = string
  default     = ""
}

variable "azure_openai_deployment" {
  description = "Nombre del deployment del modelo en Foundry (ej.: gpt-4o-mini)"
  type        = string
  default     = ""
}

variable "azure_openai_api_version" {
  description = "Versión de la API de Azure OpenAI"
  type        = string
  default     = "2024-10-21"
}

variable "azure_openai_key" {
  description = "Clave del recurso de Foundry. Se guarda en Secret Manager. Vacía = clasificación simulada."
  type        = string
  default     = ""
  sensitive   = true
}

variable "vertex_model" {
  description = "Modelo Gemini en Vertex AI (se cobra a los créditos del proyecto). Vacío = no usar Vertex"
  type        = string
  default     = "gemini-3.8-flash"
}

variable "vertex_location" {
  description = "Ubicación del endpoint de Vertex AI"
  type        = string
  default     = "global"
}
