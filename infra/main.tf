terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

# ============================================================
# DATA SOURCES
# Use the existing DEFAULT VPC
# ============================================================

data "aws_vpc" "default" {
  default = true
}

# Get available AZs
data "aws_availability_zones" "available" {
  state = "available"
}

# Get the existing default subnets
data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }

  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

# ============================================================
# LOCALS
# ============================================================

locals {
  name = "nginx-ecs"

  # Use the first two AZs
  availability_zones = slice(
    data.aws_availability_zones.available.names,
    0,
    2
  )

  # Select two default subnets
  subnets = slice(
    data.aws_subnets.default.ids,
    0,
    2
  )

  common_tags = {
    Project = "nginx-ecs"


  }
}

# ============================================================
# ALB SECURITY GROUP
# Internet -> ALB
# ============================================================

resource "aws_security_group" "alb" {
  name        = "${local.name}-alb-sg"
  description = "Security group for NGINX Application Load Balancer"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "HTTP from Internet"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS from Internet"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Allow outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(
    local.common_tags,
    {
      Name = "${local.name}-alb-sg"
    }
  )
}

# ============================================================
# ECS SECURITY GROUP
# ALB -> ECS
# ============================================================

resource "aws_security_group" "ecs" {
  name        = "${local.name}-ecs-sg"
  description = "Security group for ECS NGINX tasks"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description     = "HTTP from ALB"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    description = "Allow outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(
    local.common_tags,
    {
      Name = "${local.name}-ecs-sg"
    }
  )
}

# ============================================================
# IAM ROLE - ECS TASK EXECUTION ROLE
# ============================================================

resource "aws_iam_role" "ecs_task_execution" {
  name = "${local.name}-task-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"

    Statement = [
      {
        Effect = "Allow"

        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }

        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = local.common_tags
}

# Attach AWS managed ECS task execution policy
resource "aws_iam_role_policy_attachment" "ecs_task_execution" {
  role = aws_iam_role.ecs_task_execution.name

  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# ============================================================
# ECS CLUSTER
# ============================================================

resource "aws_ecs_cluster" "this" {
  name = local.name

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = local.common_tags
}

# ============================================================
# ECS TASK DEFINITION
# ============================================================

resource "aws_ecs_task_definition" "nginx" {
  family = "${local.name}-task"

  network_mode = "awsvpc"

  requires_compatibilities = [
    "FARGATE"
  ]

  cpu    = "256"
  memory = "512"

  execution_role_arn = aws_iam_role.ecs_task_execution.arn

  container_definitions = jsonencode([
    {
      name  = "nginx"
      image = "nginx:latest"

      essential = true

      portMappings = [
        {
          containerPort = 80
          hostPort      = 80
          protocol      = "tcp"
        }
      ]


      logConfiguration = {
        logDriver = "awslogs"

        options = {
          awslogs-group         = aws_cloudwatch_log_group.ecs.name
          awslogs-region        = "us-east-1"
          awslogs-stream-prefix = "nginx"
        }
      }
    }
  ])

  tags = local.common_tags
}

# ============================================================
# CLOUDWATCH LOG GROUP
# ============================================================

resource "aws_cloudwatch_log_group" "ecs" {
  name              = "/ecs/${local.name}"
  retention_in_days = 7

  tags = local.common_tags
}

# ============================================================
# APPLICATION LOAD BALANCER
# ============================================================

resource "aws_lb" "this" {
  name               = local.name
  load_balancer_type = "application"
  internal           = false

  security_groups = [
    aws_security_group.alb.id
  ]

  subnets = local.subnets

  tags = merge(
    local.common_tags,
    {
      Name = local.name
    }
  )
}

# ============================================================
# TARGET GROUP
# ============================================================

resource "aws_lb_target_group" "nginx" {
  name        = "${local.name}-tg"
  port        = 80
  protocol    = "HTTP"
  target_type = "ip"

  vpc_id = data.aws_vpc.default.id

  health_check {
    enabled             = true
    protocol            = "HTTP"
    path                = "/"
    port                = "traffic-port"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    matcher             = "200-399"
  }

  tags = local.common_tags
}

# ============================================================
# ALB LISTENER
# ============================================================

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn

  port     = 80
  protocol = "HTTP"

  default_action {
    type = "forward"

    target_group_arn = aws_lb_target_group.nginx.arn
  }
}

# ============================================================
# ECS SERVICE
# ============================================================

resource "aws_ecs_service" "nginx" {
  name = "${local.name}-service"

  cluster = aws_ecs_cluster.this.id

  task_definition = aws_ecs_task_definition.nginx.arn

  desired_count = 2

  launch_type = "FARGATE"

  platform_version = "LATEST"

  network_configuration {
    subnets = local.subnets

    security_groups = [
      aws_security_group.ecs.id
    ]

    # No NAT Gateway is being created.
    # Tasks are therefore placed in public default subnets.
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.nginx.arn
    container_name   = "nginx"
    container_port   = 80
  }

  deployment_minimum_healthy_percent = 50
  deployment_maximum_percent         = 200

  health_check_grace_period_seconds = 60

  depends_on = [
    aws_lb_listener.http,
    aws_iam_role_policy_attachment.ecs_task_execution
  ]

  tags = local.common_tags
}

# ============================================================
# ECS AUTO SCALING
# 2 TASKS MINIMUM
# 6 TASKS MAXIMUM
# ============================================================

resource "aws_appautoscaling_target" "ecs" {
  max_capacity       = 6
  min_capacity       = 2
  resource_id        = "service/${aws_ecs_cluster.this.name}/${aws_ecs_service.nginx.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"

  depends_on = [
    aws_ecs_service.nginx
  ]
}

# ============================================================
# CPU AUTO SCALING
# Target average CPU = 70%
# ============================================================

resource "aws_appautoscaling_policy" "ecs_cpu" {
  name               = "${local.name}-cpu-scaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ecs.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs.service_namespace

  target_tracking_scaling_policy_configuration {
    target_value = 70

    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }

    scale_in_cooldown  = 120
    scale_out_cooldown = 60
  }
}

# ============================================================
# OUTPUTS
# ============================================================

output "alb_dns_name" {
  description = "DNS name of the Application Load Balancer"
  value       = aws_lb.this.dns_name
}

output "alb_url" {
  description = "HTTP URL of the Application Load Balancer"
  value       = "http://${aws_lb.this.dns_name}"
}

output "ecs_cluster_name" {
  description = "ECS cluster name"
  value       = aws_ecs_cluster.this.name
}

output "ecs_service_name" {
  description = "ECS service name"
  value       = aws_ecs_service.nginx.name
}

output "ecs_task_definition" {
  description = "ECS task definition"
  value       = aws_ecs_task_definition.nginx.family
}

output "vpc_id" {
  description = "Default VPC ID"
  value       = data.aws_vpc.default.id
}

output "subnets" {
  description = "Default subnets used by the ALB and ECS"
  value       = local.subnets
}