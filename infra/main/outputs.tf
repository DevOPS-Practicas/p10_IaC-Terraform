output "aws_region" {
  value = var.aws_region
}

output "alb_dns_name" {
  description = "DNS público del ALB."
  value       = aws_lb.app.dns_name
}

output "alb_arn" {
  value = aws_lb.app.arn
}

output "alb_arn_suffix" {
  value = aws_lb.app.arn_suffix
}

output "blue_target_group_arn" {
  value = aws_lb_target_group.blue.arn
}

output "green_target_group_arn" {
  value = aws_lb_target_group.green.arn
}

output "blue_target_group_name" {
  value = aws_lb_target_group.blue.name
}

output "green_target_group_name" {
  value = aws_lb_target_group.green.name
}

output "blue_autoscaling_group_name" {
  value = aws_autoscaling_group.app["blue"].name
}

output "green_autoscaling_group_name" {
  value = aws_autoscaling_group.app["green"].name
}

output "autoscaling_group_name" {
  description = "Alias del ASG azul para compatibilidad con scripts."
  value       = aws_autoscaling_group.app["blue"].name
}

output "backend_ecr_repository_url" {
  value = aws_ecr_repository.backend.repository_url
}

output "frontend_ecr_repository_url" {
  value = aws_ecr_repository.frontend.repository_url
}

output "backend_ecr_repository_name" {
  value = aws_ecr_repository.backend.name
}

output "frontend_ecr_repository_name" {
  value = aws_ecr_repository.frontend.name
}

output "artifacts_bucket" {
  value = aws_s3_bucket.artifacts.bucket
}

output "codedeploy_app_name" {
  value = aws_codedeploy_app.app.name
}

output "codedeploy_deployment_group_name" {
  value = aws_codedeploy_deployment_group.app.deployment_group_name
}

output "cloudwatch_log_group_name" {
  value = aws_cloudwatch_log_group.app.name
}

output "dashboard_name" {
  value = aws_cloudwatch_dashboard.main.dashboard_name
}

output "ssm_parameter_name" {
  value = aws_ssm_parameter.cloudwatch_config.name
}

output "instance_profile_name" {
  value = aws_iam_instance_profile.ec2_app.name
}
