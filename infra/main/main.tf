terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

data "aws_caller_identity" "current" {}

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

locals {
  name_prefix               = var.project_name
  account_id                = data.aws_caller_identity.current.account_id
  azs                       = slice(data.aws_availability_zones.available.names, 0, 2)
  artifacts_bucket          = "${local.name_prefix}-artifacts-${local.account_id}-${var.aws_region}"
  cloudwatch_parameter_name = "/${local.name_prefix}/cloudwatch-agent/config"
  log_group_name            = "/${local.name_prefix}/calculadora"
  log_file_path             = "/var/log/calculadora/calculadora.log"
  ami_id                    = coalesce(var.ami_id, data.aws_ami.ubuntu.id)
}

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name      = "${local.name_prefix}-vpc"
    Project   = var.project_name
    Practice  = "10"
    ManagedBy = "terraform"
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name    = "${local.name_prefix}-igw"
    Project = var.project_name
  }
}

resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(aws_vpc.main.cidr_block, 8, count.index + 1)
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name    = "${local.name_prefix}-public-${count.index + 1}"
    Project = var.project_name
    Tier    = "public"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name    = "${local.name_prefix}-public-rt"
    Project = var.project_name
  }
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_security_group" "alb" {
  name        = "${local.name_prefix}-alb-sg"
  description = "ALB: HTTP 80 y listener de pruebas 8080"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTP produccion"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTP pruebas Blue/Green"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = [var.allowed_test_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "${local.name_prefix}-alb-sg"
    Project = var.project_name
  }
}

resource "aws_security_group" "instance" {
  name        = "${local.name_prefix}-instance-sg"
  description = "Instancias: solo trafico del ALB en 3000"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "Frontend desde el ALB"
    from_port       = 3000
    to_port         = 3000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "${local.name_prefix}-instance-sg"
    Project = var.project_name
  }
}

data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ec2_app_role" {
  name               = "${local.name_prefix}-ec2-app-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json

  tags = {
    Project  = var.project_name
    Practice = "10"
  }
}

resource "aws_iam_role_policy_attachment" "ec2_codedeploy" {
  role       = aws_iam_role.ec2_app_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2RoleforAWSCodeDeploy"
}

resource "aws_iam_role_policy_attachment" "ec2_ecr_read" {
  role       = aws_iam_role.ec2_app_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy_attachment" "ec2_cloudwatch" {
  role       = aws_iam_role.ec2_app_role.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_role_policy_attachment" "ec2_ssm_core" {
  role       = aws_iam_role.ec2_app_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "ec2_artifacts" {
  statement {
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:GetObjectVersion"]
    resources = ["${aws_s3_bucket.artifacts.arn}/*"]
  }

  statement {
    effect    = "Allow"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [aws_s3_bucket.artifacts.arn]
  }
}

resource "aws_iam_role_policy" "ec2_artifacts" {
  name   = "artifacts-read"
  role   = aws_iam_role.ec2_app_role.id
  policy = data.aws_iam_policy_document.ec2_artifacts.json
}

data "aws_iam_policy_document" "ec2_ssm_parameter" {
  statement {
    effect    = "Allow"
    actions   = ["ssm:GetParameter"]
    resources = ["arn:aws:ssm:${var.aws_region}:${local.account_id}:parameter${local.cloudwatch_parameter_name}"]
  }
}

resource "aws_iam_role_policy" "ec2_ssm_parameter" {
  name   = "cloudwatch-parameter-read"
  role   = aws_iam_role.ec2_app_role.id
  policy = data.aws_iam_policy_document.ec2_ssm_parameter.json
}

resource "aws_iam_instance_profile" "ec2_app" {
  name = "${local.name_prefix}-ec2-app-profile"
  role = aws_iam_role.ec2_app_role.name
}

data "aws_iam_policy_document" "codedeploy_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["codedeploy.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "codedeploy" {
  name               = "${local.name_prefix}-codedeploy-role"
  assume_role_policy = data.aws_iam_policy_document.codedeploy_assume_role.json

  tags = {
    Project  = var.project_name
    Practice = "10"
  }
}

resource "aws_iam_role_policy_attachment" "codedeploy_managed" {
  role       = aws_iam_role.codedeploy.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSCodeDeployRole"
}

data "aws_iam_policy_document" "codedeploy_extra" {
  statement {
    effect    = "Allow"
    actions   = ["ec2:RunInstances", "ec2:CreateTags", "ec2:TerminateInstances"]
    resources = ["*"]
  }

  statement {
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = [aws_iam_role.ec2_app_role.arn]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ec2.amazonaws.com"]
    }
  }

  statement {
    effect = "Allow"
    actions = [
      "autoscaling:CreateAutoScalingGroup",
      "autoscaling:UpdateAutoScalingGroup",
      "autoscaling:DeleteAutoScalingGroup",
      "autoscaling:DescribeAutoScalingGroups",
      "autoscaling:DescribeAutoScalingInstances",
      "autoscaling:DescribeScalingActivities",
      "autoscaling:SetDesiredCapacity",
      "autoscaling:TerminateInstanceInAutoScalingGroup"
    ]
    resources = ["*"]
  }

  statement {
    effect = "Allow"
    actions = [
      "elasticloadbalancing:Describe*",
      "elasticloadbalancing:CreateTargetGroup",
      "elasticloadbalancing:DeleteTargetGroup",
      "elasticloadbalancing:RegisterTargets",
      "elasticloadbalancing:DeregisterTargets",
      "elasticloadbalancing:ModifyListener"
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "codedeploy_extra" {
  name   = "codedeploy-bluegreen-extra"
  role   = aws_iam_role.codedeploy.id
  policy = data.aws_iam_policy_document.codedeploy_extra.json
}

resource "aws_ecr_repository" "backend" {
  name                 = "${local.name_prefix}/backend"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = {
    Project  = var.project_name
    Practice = "10"
  }
}

resource "aws_ecr_repository" "frontend" {
  name                 = "${local.name_prefix}/frontend"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = {
    Project  = var.project_name
    Practice = "10"
  }
}

resource "aws_s3_bucket" "artifacts" {
  bucket        = local.artifacts_bucket
  force_destroy = true

  tags = {
    Project   = var.project_name
    Practice  = "10"
    ManagedBy = "terraform"
  }
}

resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket                  = aws_s3_bucket.artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  rule {
    id     = "expire-old-releases"
    status = "Enabled"

    filter {
      prefix = "releases/"
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

resource "aws_launch_template" "app" {
  name_prefix   = "${local.name_prefix}-lt-"
  image_id      = local.ami_id
  instance_type = var.instance_type
  key_name      = var.key_name

  iam_instance_profile {
    name = aws_iam_instance_profile.ec2_app.name
  }

  vpc_security_group_ids = [aws_security_group.instance.id]

  user_data = base64encode(templatefile("${path.module}/user_data.sh", {
    aws_region                = var.aws_region
    cloudwatch_parameter_name = local.cloudwatch_parameter_name
  }))

  tag_specifications {
    resource_type = "instance"

    tags = {
      Name      = "${local.name_prefix}-app"
      Project   = var.project_name
      Practice  = "10"
      ManagedBy = "terraform"
    }
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  monitoring {
    enabled = true
  }

  tags = {
    Project  = var.project_name
    Practice = "10"
  }
}

resource "aws_autoscaling_group" "app" {
  for_each = {
    blue  = aws_lb_target_group.blue.arn
    green = aws_lb_target_group.green.arn
  }

  name                      = "${local.name_prefix}-asg-${each.key}"
  vpc_zone_identifier       = aws_subnet.public[*].id
  min_size                  = var.min_size
  max_size                  = var.max_size
  desired_capacity          = var.desired_capacity
  health_check_type         = "EC2"
  health_check_grace_period = 300
  target_group_arns         = [each.value]
  wait_for_capacity_timeout = "10m"

  launch_template {
    id      = aws_launch_template.app.id
    version = aws_launch_template.app.latest_version
  }

  instance_refresh {
    strategy = "Rolling"

    preferences {
      min_healthy_percentage = 100
      instance_warmup        = 300
    }
  }

  dynamic "tag" {
    for_each = {
      Name      = "${local.name_prefix}-asg-${each.key}"
      Project   = var.project_name
      Practice  = "10"
      ManagedBy = "terraform"
      Color     = each.key
    }

    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }

  depends_on = [aws_ssm_parameter.cloudwatch_config]
}
