terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    archive = {
      source  = "hashicorp/archive"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# ========================
# Variables
# ========================

variable "aws_region" {
  description = "AWS region for resources"
  type        = string
  default     = "ap-south-1"
}

variable "project_name" {
  description = "Project name"
  type        = string
  default     = "stock-etl"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "prod"
}

variable "container_port" {
  description = "Port exposed by the ECS container"
  type        = number
  default     = 8080
}

variable "ecs_task_cpu" {
  description = "ECS task CPU units"
  type        = string
  default     = "256"
}

variable "ecs_task_memory" {
  description = "ECS task memory in MB"
  type        = string
  default     = "512"
}

variable "ecs_desired_count" {
  description = "ECS desired task count"
  type        = number
  default     = 1
}

variable "sqs_visibility_timeout" {
  description = "SQS message visibility timeout in seconds"
  type        = number
  default     = 300
}

variable "autoscaling_target_value" {
  description = "Target value for autoscaling (messages per task)"
  type        = number
  default     = 100
}

# ========================
# S3 Bucket for Processed Data
# ========================

resource "aws_s3_bucket" "processed_data" {
  bucket        = "${var.project_name}-processed-data-${data.aws_caller_identity.current.account_id}"
  force_destroy = true

  tags = {
    Name        = "${var.project_name}-processed-data"
    Environment = var.environment
  }
}

resource "aws_s3_bucket_versioning" "processed_data" {
  bucket = aws_s3_bucket.processed_data.id

  versioning_configuration {
    status = "Enabled"
  }
}

# ========================
# ECR Repository for Worker Image
# ========================

resource "aws_ecr_repository" "worker" {
  name                 = "${var.project_name}-worker"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Name        = "${var.project_name}-worker"
    Environment = var.environment
  }
}

# ========================
# SQS Queue and DLQ
# ========================

resource "aws_sqs_queue" "dlq" {
  name                      = "${var.project_name}-dlq"
  message_retention_seconds = 1209600 # 14 days

  tags = {
    Name        = "${var.project_name}-dlq"
    Environment = var.environment
  }
}

resource "aws_sqs_queue" "job_queue" {
  name                       = "${var.project_name}-queue"
  visibility_timeout_seconds = var.sqs_visibility_timeout
  message_retention_seconds  = 86400 # 1 day

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = 3
  })

  tags = {
    Name        = "${var.project_name}-queue"
    Environment = var.environment
  }
}

# ========================
# ECS Cluster
# ========================

resource "aws_ecs_cluster" "main" {
  name = "${var.project_name}-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = {
    Name        = "${var.project_name}-cluster"
    Environment = var.environment
  }
}

# ========================
# IAM Roles for ECS
# ========================

# ECS Execution Role (for ECS/Fargate to pull images and logs)
resource "aws_iam_role" "ecs_task_execution_role" {
  name = "${var.project_name}-ecs-task-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ecs-tasks.amazonaws.com"
      }
    }]
  })

  tags = {
    Name        = "${var.project_name}-ecs-task-execution-role"
    Environment = var.environment
  }
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution_role_policy" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Allow ECS task execution role to pull from ECR
resource "aws_iam_role_policy" "ecs_task_execution_ecr_policy" {
  name = "${var.project_name}-ecs-task-execution-ecr-policy"
  role = aws_iam_role.ecs_task_execution_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ecr:GetAuthorizationToken",
        "ecr:BatchGetImage",
        "ecr:GetDownloadUrlForLayer"
      ]
      Resource = "*"
    }]
  })
}

# ECS Task Role (for the application running in the container)
resource "aws_iam_role" "ecs_task_role" {
  name = "${var.project_name}-ecs-task-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ecs-tasks.amazonaws.com"
      }
    }]
  })

  tags = {
    Name        = "${var.project_name}-ecs-task-role"
    Environment = var.environment
  }
}

# Allow ECS task role to access SQS
resource "aws_iam_role_policy" "ecs_task_sqs_policy" {
  name = "${var.project_name}-ecs-task-sqs-policy"
  role = aws_iam_role.ecs_task_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "sqs:ReceiveMessage",
        "sqs:DeleteMessage",
        "sqs:GetQueueAttributes",
        "sqs:ChangeMessageVisibility"
      ]
      Resource = aws_sqs_queue.job_queue.arn
    }]
  })
}

# Allow ECS task role to access S3
resource "aws_iam_role_policy" "ecs_task_s3_policy" {
  name = "${var.project_name}-ecs-task-s3-policy"
  role = aws_iam_role.ecs_task_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "s3:PutObject",
        "s3:GetObject"
      ]
      Resource = "${aws_s3_bucket.processed_data.arn}/*"
    }]
  })
}

# ========================
# ECS Task Definition
# ========================

resource "aws_ecs_task_definition" "worker" {
  family                   = "${var.project_name}-worker"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.ecs_task_cpu
  memory                   = var.ecs_task_memory
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn
  task_role_arn            = aws_iam_role.ecs_task_role.arn

  container_definitions = jsonencode([{
    name      = "${var.project_name}-worker"
    image     = "${aws_ecr_repository.worker.repository_url}:latest"
    essential = true

    portMappings = [{
      containerPort = var.container_port
      hostPort      = var.container_port
      protocol      = "tcp"
    }]

    environment = [
      {
        name  = "AWS_REGION"
        value = var.aws_region
      },
      {
        name  = "SQS_QUEUE_URL"
        value = aws_sqs_queue.job_queue.url
      },
      {
        name  = "S3_BUCKET"
        value = aws_s3_bucket.processed_data.id
      }
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.ecs_worker.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "ecs"
      }
    }
  }])

  tags = {
    Name        = "${var.project_name}-worker-task"
    Environment = var.environment
  }
}

# ========================
# CloudWatch Log Group for ECS
# ========================

resource "aws_cloudwatch_log_group" "ecs_worker" {
  name              = "/ecs/${var.project_name}-worker"
  retention_in_days = 7

  tags = {
    Name        = "${var.project_name}-ecs-logs"
    Environment = var.environment
  }
}

# ========================
# ECS Service
# ========================

resource "aws_ecs_service" "worker" {
  name            = "${var.project_name}-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.worker.arn
  desired_count   = var.ecs_desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = [aws_default_subnet.default.id]
    assign_public_ip = true
  }

  tags = {
    Name        = "${var.project_name}-service"
    Environment = var.environment
  }

  depends_on = [
    aws_ecs_task_definition.worker,
    aws_sqs_queue.job_queue
  ]
}

# ========================
# VPC (using default)
# ========================

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_default_subnet" "default" {
  availability_zone = data.aws_availability_zones.available.names[0]

  tags = {
    Name = "${var.project_name}-default-subnet"
  }
}

# ========================
# Application Auto Scaling
# ========================

resource "aws_appautoscaling_target" "ecs_target" {
  max_capacity       = 10
  min_capacity       = 1
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.worker.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "ecs_policy" {
  name               = "${var.project_name}-ecs-scaling-policy"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ecs_target.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs_target.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs_target.service_namespace

  target_tracking_scaling_policy_configuration {
    target_value = var.autoscaling_target_value

    customized_metric_specification {
      metrics = [
        {
          label      = "Get the queue size"
          id         = "m1"
          expression = null
          metric_stat = {
            metric = {
              namespace   = "AWS/SQS"
              name        = "ApproximateNumberOfMessagesVisible"
              dimensions  = {
                QueueName = aws_sqs_queue.job_queue.name
              }
            }
            stat   = "Sum"
            period = 60
          }
          return_data = false
        },
        {
          label      = "Get the running task count"
          id         = "m2"
          expression = null
          metric_stat = {
            metric = {
              namespace   = "ECS/ContainerInsights"
              name        = "RunningTaskCount"
              dimensions  = {
                ClusterName = aws_ecs_cluster.main.name
                ServiceName = aws_ecs_service.worker.name
              }
            }
            stat   = "Average"
            period = 60
          }
          return_data = false
        },
        {
          label      = "Calculate backlog per task"
          id         = "e1"
          expression = "m1 / m2"
          metric_stat = null
          return_data = true
        }
      ]
    }

    scale_in_cooldown  = 300
    scale_out_cooldown = 60
  }
}

# ========================
# Lambda IAM Role
# ========================

resource "aws_iam_role" "lambda_execution_role" {
  name = "${var.project_name}-lambda-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })

  tags = {
    Name        = "${var.project_name}-lambda-execution-role"
    Environment = var.environment
  }
}

# Allow Lambda to send messages to SQS
resource "aws_iam_role_policy" "lambda_sqs_policy" {
  name = "${var.project_name}-lambda-sqs-policy"
  role = aws_iam_role.lambda_execution_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "sqs:SendMessage",
        "sqs:GetQueueUrl"
      ]
      Resource = aws_sqs_queue.job_queue.arn
    }]
  })
}

# Allow Lambda basic execution and CloudWatch logs
resource "aws_iam_role_policy_attachment" "lambda_basic_execution" {
  role       = aws_iam_role.lambda_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# ========================
# Lambda Function (Producer)
# ========================

data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/../lambda_assign_download_worker.py"
  output_path = "${path.module}/lambda_function.zip"
}

resource "aws_lambda_function" "producer" {
  filename         = data.archive_file.lambda_zip.output_path
  function_name    = "${var.project_name}-producer"
  role             = aws_iam_role.lambda_execution_role.arn
  handler          = "lambda_assign_download_worker.lambda_handler"
  runtime          = "python3.12"
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256

  environment {
    variables = {
      SQS_QUEUE_URL = aws_sqs_queue.job_queue.url
    }
  }

  tags = {
    Name        = "${var.project_name}-producer"
    Environment = var.environment
  }
}

# ========================
# EventBridge Rule for Daily Trigger
# ========================

resource "aws_cloudwatch_event_rule" "daily_trigger" {
  name                = "${var.project_name}-daily-schedule"
  description         = "Trigger stock ETL pipeline daily after market close"
  schedule_expression = "cron(30 16 ? * MON-FRI *)" # 4:30 PM UTC (after market close - 3:30 PM EST)

  tags = {
    Name        = "${var.project_name}-daily-schedule"
    Environment = var.environment
  }
}

resource "aws_cloudwatch_event_target" "lambda_target" {
  rule      = aws_cloudwatch_event_rule.daily_trigger.name
  target_id = "LambdaProducer"
  arn       = aws_lambda_function.producer.arn
}

# Allow EventBridge to invoke Lambda
resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.producer.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.daily_trigger.arn
}

# ========================
# Data Sources
# ========================

data "aws_caller_identity" "current" {}

# ========================
# Outputs
# ========================

output "sqs_queue_url" {
  description = "URL of the SQS queue"
  value       = aws_sqs_queue.job_queue.url
}

output "sqs_queue_arn" {
  description = "ARN of the SQS queue"
  value       = aws_sqs_queue.job_queue.arn
}

output "s3_bucket_name" {
  description = "Name of the S3 bucket for processed data"
  value       = aws_s3_bucket.processed_data.id
}

output "ecr_repository_url" {
  description = "URL of the ECR repository"
  value       = aws_ecr_repository.worker.repository_url
}

output "ecs_cluster_name" {
  description = "Name of the ECS cluster"
  value       = aws_ecs_cluster.main.name
}

output "ecs_service_name" {
  description = "Name of the ECS service"
  value       = aws_ecs_service.worker.name
}

output "lambda_function_name" {
  description = "Name of the Lambda producer function"
  value       = aws_lambda_function.producer.function_name
}

output "eventbridge_rule_name" {
  description = "Name of the EventBridge daily trigger rule"
  value       = aws_cloudwatch_event_rule.daily_trigger.name
}