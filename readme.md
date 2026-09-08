# AWS Stock Market ETL Pipeline

An event-driven, serverless/containerized ETL pipeline for downloading and processing stock-market data after the daily market session.

The project demonstrates AWS architecture, asynchronous processing, container orchestration, autoscaling, IAM, infrastructure as code, and object storage.

## Architecture

```text
                         Daily Schedule
                              |
                              v
                    +-------------------+
                    |    EventBridge    |
                    |  Scheduled Rule   |
                    +---------+---------+
                              |
                              | Invoke
                              v
                    +-------------------+
                    |      Lambda       |
                    | Producer Function |
                    +---------+---------+
                              |
                              | Send one job per stock
                              v
                    +-------------------+
                    |       SQS         |
                    |   Stock Job Queue |
                    |       + DLQ       |
                    +---------+---------+
                              |
                              | Consume
                              v
                 +-------------------------+
                 |      ECS Service        |
                 |                         |
                 | +--------+ +--------+   |
                 | |Worker 1| |Worker 2|...|
                 | +--------+ +--------+   |
                 +------------+------------+
                              |
                              | Process / Upload
                              v
                    +-------------------+
                    |        S3         |
                    | Processed CSV Data|
                    +-------------------+

ECS Autoscaling:

SQS Queue Depth
      |
      v
Messages / Running ECS Tasks
      |
      v
Application Auto Scaling
      |
      v
ECS Desired Task Count
```

## Workflow

1. **EventBridge** triggers the pipeline once per day after the market session.
2. **Lambda Producer** determines the stocks that need to be processed.
3. Lambda publishes one job/message per stock to **Amazon SQS**.
4. **ECS/Fargate workers** continuously poll SQS.
5. Each worker downloads/processes stock data.
6. Processed data is written to **Amazon S3** as CSV files.
7. After successful processing, the worker deletes the SQS message.
8. Failed messages are retried by SQS.
9. Messages that repeatedly fail are moved to the **Dead Letter Queue (DLQ)**.
10. ECS scales based on the SQS backlog so more workers can be started when the queue grows.

## AWS Services

| Service | Purpose |
|---|---|
| EventBridge | Daily scheduled trigger |
| Lambda | Producer that creates stock-processing jobs |
| SQS | Asynchronous job queue |
| SQS DLQ | Stores repeatedly failed jobs |
| ECS/Fargate | Runs containerized ETL workers |
| ECR | Stores the Docker worker image |
| S3 | Stores processed stock data |
| IAM | Controls service/application permissions |
| CloudWatch | Logs, metrics, and monitoring |
| Application Auto Scaling | Scales ECS workers based on queue backlog |
| Terraform | Provisions AWS infrastructure |

## IAM Design

The project separates ECS infrastructure permissions from application permissions.

### ECS Execution Role

Used by ECS/Fargate itself.

Typical permissions:

- Pull images from ECR
- Send container logs to CloudWatch

```text
ECS Execution Role
        |
        +--> ECR
        |
        +--> CloudWatch Logs
```

### ECS Task Role

Used by the Python application running inside the container.

Typical permissions:

```text
ECS Task Role
      |
      +--> SQS
      |     +--> ReceiveMessage
      |     +--> DeleteMessage
      |     +--> GetQueueAttributes
      |     +--> ChangeMessageVisibility
      |
      +--> S3
            +--> PutObject
            +--> GetObject
```

The container does **not** contain personal AWS credentials. Boto3 obtains temporary credentials from the ECS Task Role.

## SQS Processing

The worker follows an at-least-once processing model.

```text
SQS
 |
 | ReceiveMessage
 v
Worker
 |
 +--> Success --> DeleteMessage --> Message removed
 |
 +--> Failure --> Message remains
                    |
                    v
              Visibility Timeout
                    |
                    v
              Message visible again
```

### In-flight messages

A message becomes **in flight** after a worker receives it but before it is deleted.

For example:

```text
10 messages in queue

7 visible
3 in flight
```

The three in-flight messages are currently being processed or temporarily hidden because of the visibility timeout.

The visibility timeout should be longer than the expected processing time of a worker.

## ECS Autoscaling

The ECS service uses SQS backlog to determine the required number of workers.

The target metric can be represented as:

```text
SQS visible messages
--------------------
ECS running tasks
```

For example, with a target of `100`:

```text
100 messages / 1 task = 100
200 messages / 2 tasks = 100
300 messages / 3 tasks = 100
```

This allows ECS to increase or decrease the number of workers according to workload.

For initial testing, a minimum capacity of `1` is recommended because the metric:

```text
messages / running_tasks
```

cannot be calculated when there are zero running tasks.

## Docker

The ETL worker is packaged as a Docker image.

Example structure:

```text
worker/
├── worker.py
├── download_data.py
├── requirements.txt
└── Dockerfile
```

Example Dockerfile:

```dockerfile
FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

CMD ["python", "worker.py"]
```

Build the image:

```bash
docker build -t stock-etl-worker .
```

Tag it for ECR:

```bash
docker tag stock-etl-worker:latest \
<ACCOUNT_ID>.dkr.ecr.ap-south-1.amazonaws.com/stock-etl-worker:latest
```

Authenticate Docker with ECR:

```bash
aws ecr get-login-password --region ap-south-1 | \
docker login --username AWS --password-stdin \
<ACCOUNT_ID>.dkr.ecr.ap-south-1.amazonaws.com
```

Push the image:

```bash
docker push \
<ACCOUNT_ID>.dkr.ecr.ap-south-1.amazonaws.com/stock-etl-worker:latest
```

> If Docker was installed for a normal user, avoid mixing `sudo docker` with normal-user Docker authentication. Otherwise Docker may look for ECR credentials under a different user's Docker configuration.
