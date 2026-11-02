resource "aws_codedeploy_app" "app" {
  name             = "${local.name_prefix}-app"
  compute_platform = "Server"

  tags = {
    Project  = var.project_name
    Practice = "10"
  }
}

resource "aws_codedeploy_deployment_group" "app" {
  app_name               = aws_codedeploy_app.app.name
  deployment_group_name  = "produccion"
  service_role_arn       = aws_iam_role.codedeploy.arn
  deployment_config_name = "CodeDeployDefault.AllAtOnce"
  autoscaling_groups     = [aws_autoscaling_group.app["blue"].name]

  deployment_style {
    deployment_type   = "BLUE_GREEN"
    deployment_option = "WITH_TRAFFIC_CONTROL"
  }

  blue_green_deployment_config {
    # La instalacion termina y el despliegue queda en READY hasta que el
    # pipeline valide el entorno verde y ejecute continue-deployment.
    deployment_ready_option {
      action_on_timeout    = "STOP_DEPLOYMENT"
      wait_time_in_minutes = 5
    }

    # Terraform crea los dos ASG; CodeDeploy usa el ASG de reemplazo
    # que se indica en create-deployment con --target-instances.
    green_fleet_provisioning_option {
      action = "DISCOVER_EXISTING"
    }

    # KEEP_ALIVE conserva el ASG original para que Terraform no pierda su
    # state. El runbook incluye la limpieza de los ASG creados por CodeDeploy.
    terminate_blue_instances_on_deployment_success {
      action = "KEEP_ALIVE"
    }
  }

  # En EC2/On-Premises CodeDeploy usa target_group_info (un solo Target Group
  # de reemplazo), no target_group_pair_info. El pipeline alterna el Target
  # Group de reemplazo y actualiza el listener de pruebas antes de desplegar.
  load_balancer_info {
    target_group_info {
      name = aws_lb_target_group.green.name
    }
  }

  auto_rollback_configuration {
    enabled = true
    events  = ["DEPLOYMENT_FAILURE", "DEPLOYMENT_STOP_ON_ALARM"]
  }

  alarm_configuration {
    enabled = true
    alarms = [
      aws_cloudwatch_metric_alarm.alb_5xx_blue.alarm_name,
      aws_cloudwatch_metric_alarm.alb_5xx_green.alarm_name,
    ]
    ignore_poll_alarm_failure = false
  }

  outdated_instances_strategy = "UPDATE"

  tags = {
    Project  = var.project_name
    Practice = "10"
  }
}
