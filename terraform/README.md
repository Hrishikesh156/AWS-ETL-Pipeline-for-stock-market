# Terraform Configuration for AWS Stock Market ETL Pipeline

This directory contains the Terraform Infrastructure as Code (IaC) configuration for deploying the AWS Stock Market ETL pipeline.

## Architecture Overview

The Terraform configuration provisions the following AWS services:

- **S3**: Stores processed CSV stock data
- **SQS**: Job queue and Dead Letter Queue for asynchronous job processing
- **ECS/Fargate**: Containerized workers that process stock data
- **ECR**: Container image repository for the worker application
- **Lambda**: Producer function that creates stock processing jobs
- **EventBridge**: Scheduled trigger for daily pipeline execution
- **IAM**: Roles and policies for service permissions
- **CloudWatch**: Logs and metrics for monitoring
- **Application Auto Scaling**: Automatic ECS task scaling based on queue depth

## Prerequisites

1. **AWS Account**: Ensure you have appropriate AWS credentials configured
2. **Terraform**: Install [Terraform](https://www.terraform.io/downloads) (v1.0+)
3. **AWS CLI**: Install [AWS CLI](https://aws.amazon.com/cli/) for authentication
4. **Docker**: For building and pushing the worker container image to ECR

## Directory Structure

```
terraform/
├── main.tf                 # Main Terraform configuration (all resources)
├── terraform.tfvars        # Default variable values
└── README.md               # This file
```

## Files Configuration

### main.tf
Contains all resource definitions including:
- Variables with descriptions and defaults
- S3 bucket for processed data
- ECR repository for worker images
- SQS queue with Dead Letter Queue
- ECS cluster, service, and task definitions
- IAM roles and policies for ECS and Lambda
- Lambda producer function
- EventBridge daily scheduling rule
- Application Auto Scaling configuration
- CloudWatch log groups
- Outputs for easy reference to resource identifiers

### terraform.tfvars
Contains default values for variables. You can override these by:
1. Using `-var` flag: `terraform apply -var="ecs_desired_count=2"`
2. Creating a `terraform.auto.tfvars` file with custom values
3. Using environment variables: `export TF_VAR_aws_region=us-east-1`

## Deployment Steps

### 1. Initialize Terraform

```bash
cd terraform
terraform init
```

This downloads the required Terraform providers and prepares the working directory.

### 2. Plan the Deployment

```bash
terraform plan -out=tfplan
```

Review the planned changes before applying.

### 3. Apply the Configuration

```bash
terraform apply tfplan
```

This creates all AWS resources defined in the configuration.

### 4. Retrieve Output Values

After successful deployment, get the important resource identifiers:

```bash
terraform output
```

Key outputs include:
- `sqs_queue_url`: URL of the job queue
- `s3_bucket_name`: Name of the data bucket
- `ecr_repository_url`: ECR repository for container images
- `ecs_cluster_name`: ECS cluster name
- `lambda_function_name`: Lambda producer function name

### 5. Build and Push Worker Image

After the ECR repository is created:

```bash
# Get AWS account ID and authenticate with ECR
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export REGION=ap-south-1
export ECR_REPO=$(terraform output -raw ecr_repository_url)

# Authenticate Docker with ECR
aws ecr get-login-password --region $REGION | \
  docker login --username AWS --password-stdin \
  $AWS_ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com

# Build the worker image
cd .. # Go back to project root
docker build -t stock-etl-worker .

# Tag for ECR
docker tag stock-etl-worker:latest $ECR_REPO:latest

# Push to ECR
docker push $ECR_REPO:latest
```

## Configuration Variables

### Core Variables

- **aws_region**: AWS region for resource deployment (default: `ap-south-1`)
- **project_name**: Project name used for resource naming (default: `stock-etl`)
- **environment**: Environment identifier for tagging (default: `prod`)

### ECS Configuration

- **ecs_task_cpu**: CPU units for ECS tasks (default: `256`)
- **ecs_task_memory**: Memory in MB for ECS tasks (default: `512`)
- **ecs_desired_count**: Initial desired number of running tasks (default: `1`)
- **container_port**: Port exposed by the worker container (default: `8080`)

### SQS Configuration

- **sqs_visibility_timeout**: How long a message stays hidden after being received in seconds (default: `300` seconds / 5 minutes)
  - Should be longer than the expected worker processing time
  - If a worker doesn't delete the message within this time, it becomes visible again

### Autoscaling Configuration

- **autoscaling_target_value**: Target metric value for scaling (default: `100`)
  - Represents messages per running task
  - If set to 100: with 200 visible messages, ECS will scale to 2 tasks

## Autoscaling Behavior

The ECS service automatically scales based on the SQS queue depth using a custom metric:

```
Target Metric = ApproximateNumberOfMessagesVisible / RunningTaskCount
```

**Scaling Logic:**
- If metric > target_value: Scale up (add more tasks)
- If metric < target_value: Scale down (remove tasks)
- Minimum: 1 task (required for metric calculation)
- Maximum: 10 tasks

**Example:**
With `autoscaling_target_value = 100`:
- 100 messages, 1 task → 100/1 = 100 (no change)
- 250 messages, 1 task → 250/1 = 250 > 100 (scale up to 3 tasks)
- 300 messages, 3 tasks → 300/3 = 100 (balanced)

## EventBridge Scheduling

The Lambda producer is triggered by EventBridge using a cron expression:

```
cron(30 16 ? * MON-FRI *)
```

This translates to:
- **Time**: 4:30 PM UTC (16:30)
- **Days**: Monday through Friday only
- **Timezone**: UTC

**Adjust for your timezone:**
- IST (UTC+5:30): 9:00 PM = `cron(0 21 ? * MON-FRI *)`
- EST (UTC-5): 11:30 AM = `cron(30 11 ? * MON-FRI *)`

To modify, edit the `schedule_expression` in the `aws_cloudwatch_event_rule` resource.

## Destroying Resources

To remove all provisioned resources:

```bash
terraform destroy
```

Review the plan and confirm deletion. This will remove:
- All AWS resources created by Terraform
- ECR images must be manually deleted if the bucket has a deletion policy

## IAM Role Separation

### ECS Execution Role
Used by **ECS/Fargate itself**:
- Pull container images from ECR
- Push logs to CloudWatch

### ECS Task Role
Used by the **Python application inside the container**:
- Receive and delete messages from SQS
- Upload processed data to S3
- Get queue attributes and modify message visibility

### Lambda Execution Role
Used by the **Lambda producer function**:
- Send messages to SQS
- Write logs to CloudWatch

## Troubleshooting

### Lambda Function Not Triggering

1. Check EventBridge rule is enabled:
   ```bash
   aws events describe-rule --name stock-etl-daily-schedule
   ```

2. Verify Lambda has permission from EventBridge:
   ```bash
   aws lambda get-policy --function-name stock-etl-producer
   ```

3. Check CloudWatch Logs:
   ```bash
   aws logs tail /aws/lambda/stock-etl-producer --follow
   ```

### ECS Tasks Not Running

1. Check task definition:
   ```bash
   aws ecs describe-task-definition --task-definition stock-etl-worker
   ```

2. View recent tasks in the service:
   ```bash
   aws ecs list-tasks --cluster stock-etl-cluster --service-name stock-etl-service
   ```

3. Check task logs in CloudWatch:
   ```bash
   aws logs tail /ecs/stock-etl-worker --follow
   ```

### Autoscaling Not Working

1. Verify metrics are being published:
   ```bash
   aws cloudwatch get-metric-statistics \
     --namespace AWS/SQS \
     --metric-name ApproximateNumberOfMessagesVisible \
     --dimensions Name=QueueName,Value=stock-etl-queue \
     --start-time 2024-01-01T00:00:00Z \
     --end-time 2024-01-01T01:00:00Z \
     --period 60 \
     --statistics Sum
   ```

2. Check autoscaling policy:
   ```bash
   aws application-autoscaling describe-scaling-policies \
     --service-namespace ecs
   ```

## Cost Considerations

- **S3**: Storage costs for processed CSV files
- **SQS**: Per-request pricing (very low)
- **ECS/Fargate**: Per-task pricing based on CPU/memory allocated
- **Lambda**: Per-invocation and duration pricing
- **ECR**: Storage costs for container images
- **CloudWatch**: Logs and metrics pricing

For cost estimation, use the [AWS Pricing Calculator](https://calculator.aws/).

## Security Best Practices

1. **Secrets Management**: Use AWS Secrets Manager for sensitive data
   ```hcl
   # Update the task definition to reference secrets
   secrets = [{
     name      = "API_KEY"
     valueFrom = aws_secretsmanager_secret.api_key.arn
   }]
   ```

2. **Network Isolation**: Consider using a VPC instead of default subnet
   ```hcl
   subnets = [aws_subnet.private.id]
   assign_public_ip = false
   ```

3. **Image Scanning**: ECR automatically scans images for vulnerabilities

4. **IAM Least Privilege**: Roles have minimal required permissions

## Next Steps

1. Customize `terraform.tfvars` for your environment
2. Review and adjust the EventBridge cron schedule
3. Build and push the worker Docker image to ECR
4. Monitor CloudWatch Logs and metrics
5. Test the pipeline with sample data

## References

- [AWS Terraform Provider Documentation](https://registry.terraform.io/providers/hashicorp/aws/latest)
- [Terraform Configuration Language](https://www.terraform.io/language)
- [AWS Stock Market ETL Pipeline README](../readme.md)
