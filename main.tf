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

# --- SQS QUEUE ---

resource "aws_sqs_queue" "notificacoes_queue" {
  name                       = "notificacoes-queue"
  visibility_timeout_seconds = 30
  message_retention_seconds  = 86400
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
      aws_sqs_queue.notificacoes_queue.arn
    ]
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
    input_template = <<EOF
{
  "usuarioId": <$.dynamodb.NewImage.usuarioId.S>,
  "statusAtual": <$.dynamodb.NewImage.status.S>,
  "tabelaOrigem": "TabelaA",
  "tipoEvento": <$.eventName>
}
EOF
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
    input_template = <<EOF
{
  "usuarioId": <$.dynamodb.NewImage.usuarioId.S>,
  "statusAtual": <$.dynamodb.NewImage.status.S>,
  "tabelaOrigem": "TabelaB",
  "tipoEvento": <$.eventName>
}
EOF
  }
}
