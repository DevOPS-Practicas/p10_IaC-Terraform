resource "aws_lb" "app" {
  name               = "${local.name_prefix}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id
  idle_timeout       = 60

  enable_deletion_protection = false

  tags = {
    Project   = var.project_name
    Practice  = "10"
    ManagedBy = "terraform"
  }
}

resource "aws_lb_target_group" "blue" {
  name                 = "${local.name_prefix}-tg-blue"
  port                 = 3000
  protocol             = "HTTP"
  vpc_id               = aws_vpc.main.id
  target_type          = "instance"
  deregistration_delay = 30

  health_check {
    enabled             = true
    path                = "/api/health"
    port                = "traffic-port"
    protocol            = "HTTP"
    healthy_threshold   = 2
    unhealthy_threshold = 2
    timeout             = 5
    interval            = 30
    matcher             = "200"
  }

  tags = {
    Project  = var.project_name
    Practice = "10"
    Color    = "blue"
  }
}

resource "aws_lb_target_group" "green" {
  name                 = "${local.name_prefix}-tg-green"
  port                 = 3000
  protocol             = "HTTP"
  vpc_id               = aws_vpc.main.id
  target_type          = "instance"
  deregistration_delay = 30

  health_check {
    enabled             = true
    path                = "/api/health"
    port                = "traffic-port"
    protocol            = "HTTP"
    healthy_threshold   = 2
    unhealthy_threshold = 2
    timeout             = 5
    interval            = 30
    matcher             = "200"
  }

  tags = {
    Project  = var.project_name
    Practice = "10"
    Color    = "green"
  }
}

resource "aws_lb_listener" "prod" {
  load_balancer_arn = aws_lb.app.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.blue.arn
  }

  # CodeDeploy cambia esta accion durante el Blue/Green.
  lifecycle {
    ignore_changes = [default_action]
  }

  tags = {
    Project  = var.project_name
    Practice = "10"
  }
}

resource "aws_lb_listener" "test" {
  load_balancer_arn = aws_lb.app.arn
  port              = 8080
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.green.arn
  }

  # CodeDeploy usa este listener como test_traffic_route.
  lifecycle {
    ignore_changes = [default_action]
  }

  tags = {
    Project  = var.project_name
    Practice = "10"
    Purpose  = "blue-green-test"
  }
}
