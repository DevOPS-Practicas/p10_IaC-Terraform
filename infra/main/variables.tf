# Valores por defecto pensados para seguir la practica sin archivo tfvars.
variable "aws_region" {
  description = "Región de AWS. Debe coincidir con AWS_REGION del repositorio."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Prefijo de nombres y etiquetas."
  type        = string
  default     = "mi-app"
}

variable "instance_type" {
  description = "Tipo de instancia para el ASG."
  type        = string
  default     = "t3.small"
}

variable "min_size" {
  description = "Tamaño mínimo del ASG."
  type        = number
  default     = 2
}

variable "max_size" {
  description = "Tamaño máximo del ASG."
  type        = number
  default     = 4
}

variable "desired_capacity" {
  description = "Capacidad deseada del ASG."
  type        = number
  default     = 2
}

variable "allowed_test_cidr" {
  description = "CIDR permitido para el listener de pruebas 8080. Cambiar a la IP del estudiante."
  type        = string
  default     = "0.0.0.0/0"
}

variable "key_name" {
  description = "Key pair opcional para SSH. Se recomienda dejar null y usar SSM Session Manager."
  type        = string
  default     = null
}

variable "ami_id" {
  description = "AMI opcional. Si es null se usa la última Ubuntu 24.04 LTS de Canonical."
  type        = string
  default     = null
}
