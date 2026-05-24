terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

# --- DYNAMODB TABLES ---

resource "aws_dynamodb_table" "tabela_a" {
  name             = "tabela-a"
  billing_mode     = "PAY_PER_REQUEST"
  hash_key         = "usuarioId"
  stream_enabled   = true
  stream_view_type = "NEW_AND_OLD_IMAGES"

  attribute {
    name = "usuarioId"
    type = "S"
  }
}

resource "aws_dynamodb_table" "tabela_b" {
  name             = "tabela-b"
  billing_mode     = "PAY_PER_REQUEST"
  hash_key         = "usuarioId"
  stream_enabled   = true
  stream_view_type = "NEW_AND_OLD_IMAGES"

  attribute {
    name = "usuarioId"
    type = "S"
  }
}

# --- SQS QUEUES (Main & DLQs) ---

resource "aws_sqs_queue" "notificacoes_dlq" {
  name = "notificacoes-dlq"
}

resource "aws_sqs_queue" "notificacoes_queue" {
  name                       = "notificacoes-queue"
  visibility_timeout_seconds = 60 # Ajustado para evitar duplicidade (recomendado: 6x o timeout da Lambda)
  message_retention_seconds  = 86400

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.notificacoes_dlq.arn
    maxReceiveCount     = 3
  })
}

resource "aws_sqs_queue" "pipes_dlq" {
  name = "pipes-dlq"
}

# --- CLOUDWATCH LOGS ---

resource "aws_cloudwatch_log_group" "pipe_logs" {
  name              = "/aws/vendedlogs/pipes/notificacoes"
  retention_in_days = 7
}

# --- IAM ROLE FOR EVENTBRIDGE PIPES ---

data "aws_iam_policy_document" "pipe_assume_role" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["pipes.amazonaws.com"]
    }
    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "pipe_role" {
  name               = "eventbridge-pipe-role"
  assume_role_policy = data.aws_iam_policy_document.pipe_assume_role.json
}

data "aws_iam_policy_document" "pipe_policy" {
  statement {
    effect = "Allow"
    actions = [
      "dynamodb:DescribeStream",
      "dynamodb:GetRecords",
      "dynamodb:GetShardIterator",
      "dynamodb:ListStreams"
    ]
    resources = [
      aws_dynamodb_table.tabela_a.stream_arn,
      aws_dynamodb_table.tabela_b.stream_arn
    ]
  }

  statement {
    effect = "Allow"
    actions = [
      "sqs:SendMessage"
    ]
    resources = [
      aws_sqs_queue.notificacoes_queue.arn,
      aws_sqs_queue.pipes_dlq.arn
    ]
  }

  statement {
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]
    resources = ["${aws_cloudwatch_log_group.pipe_logs.arn}:*"]
  }
}

resource "aws_iam_role_policy" "pipe_role_policy" {
  name   = "pipe-policy"
  role   = aws_iam_role.pipe_role.id
  policy = data.aws_iam_policy_document.pipe_policy.json
}

# --- EVENTBRIDGE PIPES ---

resource "aws_pipes_pipe" "pipe_tabela_a" {
  name     = "pipe-tabela-a"
  role_arn = aws_iam_role.pipe_role.arn
  source   = aws_dynamodb_table.tabela_a.stream_arn
  target   = aws_sqs_queue.notificacoes_queue.arn

  source_parameters {
    dynamodb_stream_parameters {
      starting_position = "LATEST"
      batch_size        = 10
    }
    
    filter_criteria {
      filter {
        pattern = jsonencode({
          "$or" : [
            {
              "eventName" : ["INSERT"],
              "dynamodb" : {
                "NewImage" : {
                  "status" : {
                    "S" : ["aceito", "recusado"]
                  }
                }
              }
            },
            {
              "eventName" : ["MODIFY"],
              "dynamodb" : {
                "OldImage" : {
                  "status" : {
                    "S" : ["aceito"]
                  }
                },
                "NewImage" : {
                  "status" : {
                    "S" : ["recusado"]
                  }
                }
              }
            }
          ]
        })
      }
    }
  }

  target_parameters {
    sqs_queue_parameters {
      dead_letter_config {
        arn = aws_sqs_queue.pipes_dlq.arn
      }
    }

    input_template = <<EOF
{
  "usuarioId": <$.dynamodb.NewImage.usuarioId.S>,
  "statusAtual": <$.dynamodb.NewImage.status.S>,
  "tabelaOrigem": "TabelaA",
  "tipoEvento": <$.eventName>
}
EOF
  }

  log_configuration {
    level = "ERROR"
    cloudwatch_logs_log_destination {
      log_group_arn = aws_cloudwatch_log_group.pipe_logs.arn
    }
  }
}

resource "aws_pipes_pipe" "pipe_tabela_b" {
  name     = "pipe-tabela-b"
  role_arn = aws_iam_role.pipe_role.arn
  source   = aws_dynamodb_table.tabela_b.stream_arn
  target   = aws_sqs_queue.notificacoes_queue.arn

  source_parameters {
    dynamodb_stream_parameters {
      starting_position = "LATEST"
      batch_size        = 10
    }
    
    filter_criteria {
      filter {
        pattern = jsonencode({
          "$or" : [
            {
              "eventName" : ["INSERT"],
              "dynamodb" : {
                "NewImage" : {
                  "status" : {
                    "S" : ["criado", "sucesso", "erro"]
                  }
                }
              }
            },
            {
              "eventName" : ["MODIFY"],
              "dynamodb" : {
                "OldImage" : {
                  "status" : {
                    "S" : [{ "anything-but" : ["agendado", "deletado"] }]
                  }
                },
                "NewImage" : {
                  "status" : {
                    "S" : ["agendado", "deletado"]
                  }
                }
              }
            }
          ]
        })
      }
    }
  }

  target_parameters {
    sqs_queue_parameters {
      dead_letter_config {
        arn = aws_sqs_queue.pipes_dlq.arn
      }
    }

    input_template = <<EOF
{
  "usuarioId": <$.dynamodb.NewImage.usuarioId.S>,
  "statusAtual": <$.dynamodb.NewImage.status.S>,
  "tabelaOrigem": "TabelaB",
  "tipoEvento": <$.eventName>
}
EOF
  }

  log_configuration {
    level = "ERROR"
    cloudwatch_logs_log_destination {
      log_group_arn = aws_cloudwatch_log_group.pipe_logs.arn
    }
  }
}

# --- CLOUDWATCH ALARMS ---

resource "aws_cloudwatch_metric_alarm" "pipe_errors" {
  alarm_name          = "eventbridge-pipes-errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "1"
  metric_name         = "ExecutionError"
  namespace           = "AWS/Pipes"
  period              = "60"
  statistic           = "Sum"
  threshold           = "0"
  alarm_description   = "Alarme se houver falhas na execução dos EventBridge Pipes."
  treat_missing_data  = "notBreaching"
}

resource "aws_cloudwatch_metric_alarm" "dlq_messages" {
  alarm_name          = "sqs-dlq-messages-detected"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "1"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = "60"
  statistic           = "Sum"
  threshold           = "0"
  alarm_description   = "Alarme se houver mensagens paradas em qualquer DLQ."
  dimensions = {
    QueueName = aws_sqs_queue.notificacoes_dlq.name
  }
}
