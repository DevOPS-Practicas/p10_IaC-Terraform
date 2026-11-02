output "state_bucket" {
  description = "Bucket S3 que guarda el state de Terraform."
  value       = aws_s3_bucket.state.bucket
}

output "state_bucket_arn" {
  description = "ARN del bucket de state."
  value       = aws_s3_bucket.state.arn
}
