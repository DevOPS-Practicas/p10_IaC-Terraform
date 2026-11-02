variable "aws_region" {
  description = "Región de AWS donde se crea el bucket de state."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Nombre del proyecto, usado en etiquetas."
  type        = string
  default     = "mi-app"
}
