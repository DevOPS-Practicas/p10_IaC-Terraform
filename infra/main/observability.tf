resource "aws_ssm_parameter" "cloudwatch_config" {
  name        = local.cloudwatch_parameter_name
  description = "Configuracion del CloudWatch Agent para la calculadora"
  type        = "String"

  value = jsonencode({
    agent = {
      metrics_collection_interval = 60
      run_as_user                 = "root"
    }
    metrics = {
      namespace = "CWAgent"
      append_dimensions = {
        AutoScalingGroupName = "$${aws:AutoScalingGroupName}"
        InstanceId           = "$${aws:InstanceId}"
      }
      aggregation_dimensions = [["AutoScalingGroupName"]]
      metrics_collected = {
        cpu = {
          measurement                 = ["cpu_usage_idle", "cpu_usage_user", "cpu_usage_system", "cpu_usage_iowait"]
          metrics_collection_interval = 60
          totalcpu                    = true
        }
        mem = {
          measurement                 = ["mem_used_percent"]
          metrics_collection_interval = 60
        }
        disk = {
          measurement                 = ["used_percent"]
          resources                   = ["/"]
          ignore_file_system_types    = ["sysfs", "devtmpfs", "tmpfs", "overlay"]
          metrics_collection_interval = 60
        }
        swap = {
          measurement                 = ["swap_used_percent"]
          metrics_collection_interval = 60
        }
      }
    }
    logs = {
      logs_collected = {
        files = {
          collect_list = [
            {
              file_path       = local.log_file_path
              log_group_name  = local.log_group_name
              log_stream_name = "{instance_id}"
              timezone        = "UTC"
            }
          ]
        }
      }
    }
  })

  tags = {
    Project  = var.project_name
    Practice = "10"
  }
}

resource "aws_cloudwatch_log_group" "app" {
  name              = local.log_group_name
  retention_in_days = 7

  tags = {
    Project  = var.project_name
    Practice = "10"
  }
}

resource "aws_cloudwatch_metric_alarm" "alb_5xx_blue" {
  alarm_name          = "gh-alb-5xx-blue"
  alarm_description   = "Errores 5xx del Target Group azul"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  datapoints_to_alarm = 1
  threshold           = 0
  treat_missing_data  = "notBreaching"

  metric_query {
    id          = "m1"
    return_data = false

    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "HTTPCode_Target_5XX_Count"
      period      = 60
      stat        = "Sum"

      dimensions = {
        LoadBalancer = aws_lb.app.arn_suffix
        TargetGroup  = aws_lb_target_group.blue.arn_suffix
      }
    }
  }

  metric_query {
    id          = "e1"
    expression  = "FILL(m1, 0)"
    label       = "5xx"
    return_data = true
  }

  tags = {
    Project  = var.project_name
    Practice = "10"
    Color    = "blue"
  }
}

resource "aws_cloudwatch_metric_alarm" "alb_5xx_green" {
  alarm_name          = "gh-alb-5xx-green"
  alarm_description   = "Errores 5xx del Target Group verde"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  datapoints_to_alarm = 1
  threshold           = 0
  treat_missing_data  = "notBreaching"

  metric_query {
    id          = "m1"
    return_data = false

    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "HTTPCode_Target_5XX_Count"
      period      = 60
      stat        = "Sum"

      dimensions = {
        LoadBalancer = aws_lb.app.arn_suffix
        TargetGroup  = aws_lb_target_group.green.arn_suffix
      }
    }
  }

  metric_query {
    id          = "e1"
    expression  = "FILL(m1, 0)"
    label       = "5xx"
    return_data = true
  }

  tags = {
    Project  = var.project_name
    Practice = "10"
    Color    = "green"
  }
}

resource "aws_cloudwatch_metric_alarm" "healthy_blue" {
  alarm_name          = "gh-tg-healthy-blue"
  alarm_description   = "Menos de 2 instancias sanas en el Target Group azul"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HealthyHostCount"
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  threshold           = 2
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = aws_lb.app.arn_suffix
    TargetGroup  = aws_lb_target_group.blue.arn_suffix
  }

  tags = {
    Project  = var.project_name
    Practice = "10"
    Color    = "blue"
  }
}

resource "aws_cloudwatch_metric_alarm" "healthy_green" {
  alarm_name          = "gh-tg-healthy-green"
  alarm_description   = "Menos de 2 instancias sanas en el Target Group verde"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HealthyHostCount"
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  threshold           = 2
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = aws_lb.app.arn_suffix
    TargetGroup  = aws_lb_target_group.green.arn_suffix
  }

  tags = {
    Project  = var.project_name
    Practice = "10"
    Color    = "green"
  }
}

resource "aws_cloudwatch_metric_alarm" "latency_p99" {
  alarm_name          = "gh-alb-p99"
  alarm_description   = "Latencia p99 superior a 0.5 segundos"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "TargetResponseTime"
  extended_statistic  = "p99"
  period              = 60
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  threshold           = 0.5
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = aws_lb.app.arn_suffix
  }

  tags = {
    Project  = var.project_name
    Practice = "10"
  }
}

resource "aws_cloudwatch_metric_alarm" "cpu_high" {
  alarm_name          = "gh-asg-cpu-high"
  alarm_description   = "CPU promedio del ASG superior al 80 por ciento"
  namespace           = "AWS/EC2"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.app["blue"].name
  }

  tags = {
    Project  = var.project_name
    Practice = "10"
  }
}

resource "aws_cloudwatch_metric_alarm" "memory_high" {
  alarm_name          = "gh-asg-mem-high"
  alarm_description   = "Memoria usada del ASG superior al 80 por ciento"
  namespace           = "CWAgent"
  metric_name         = "mem_used_percent"
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.app["blue"].name
  }

  tags = {
    Project  = var.project_name
    Practice = "10"
  }
}

resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "gh-miAppEstado"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          view    = "timeSeries"
          stacked = false
          region  = var.aws_region
          stat    = "Average"
          period  = 60
          title   = "CPU del ASG (%)"
          metrics = [
            ["AWS/EC2", "CPUUtilization", "AutoScalingGroupName", aws_autoscaling_group.app["blue"].name, { label = "CPU %" }]
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          view    = "timeSeries"
          stacked = false
          region  = var.aws_region
          stat    = "Average"
          period  = 60
          title   = "Memoria usada (%)"
          metrics = [
            ["CWAgent", "mem_used_percent", "AutoScalingGroupName", aws_autoscaling_group.app["blue"].name, { label = "mem_used %" }]
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6
        properties = {
          view    = "timeSeries"
          stacked = false
          region  = var.aws_region
          stat    = "Sum"
          period  = 60
          title   = "Errores 5xx del ALB"
          metrics = [
            ["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", "LoadBalancer", aws_lb.app.arn_suffix, "TargetGroup", aws_lb_target_group.blue.arn_suffix, { label = "5xx blue" }],
            ["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", "LoadBalancer", aws_lb.app.arn_suffix, "TargetGroup", aws_lb_target_group.green.arn_suffix, { label = "5xx green" }]
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 6
        width  = 12
        height = 6
        properties = {
          view    = "timeSeries"
          stacked = false
          region  = var.aws_region
          stat    = "Minimum"
          period  = 60
          title   = "Instancias sanas por Target Group"
          metrics = [
            ["AWS/ApplicationELB", "HealthyHostCount", "LoadBalancer", aws_lb.app.arn_suffix, "TargetGroup", aws_lb_target_group.blue.arn_suffix, { label = "healthy blue" }],
            ["AWS/ApplicationELB", "HealthyHostCount", "LoadBalancer", aws_lb.app.arn_suffix, "TargetGroup", aws_lb_target_group.green.arn_suffix, { label = "healthy green" }]
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 12
        width  = 12
        height = 6
        properties = {
          view    = "timeSeries"
          stacked = false
          region  = var.aws_region
          stat    = "p99"
          period  = 60
          title   = "Latencia p99 del ALB (s)"
          metrics = [
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", aws_lb.app.arn_suffix, { label = "p99" }]
          ]
        }
      },
      {
        type   = "log"
        x      = 12
        y      = 12
        width  = 12
        height = 6
        properties = {
          view   = "table"
          region = var.aws_region
          title  = "Logs de la calculadora"
          query  = "SOURCE \"${local.log_group_name}\" | fields @timestamp, @message | sort @timestamp desc | limit 50"
        }
      }
    ]
  })
}
