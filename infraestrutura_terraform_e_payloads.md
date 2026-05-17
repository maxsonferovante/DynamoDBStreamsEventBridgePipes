# Implementação: Terraform e Fluxo de Dados

Este documento detalha a implementação em Terraform para a arquitetura baseada em EventBridge Pipes e SQS (Arquitetura 1), bem como o formato do payload de dados que trafegará no sistema em cada um dos 4 cenários das Lambdas.

---

## 1. Código Terraform (Trechos Principais)

Abaixo estão as configurações do recurso `aws_pipes_pipe` que farão a mágica de ler o DynamoDB, aplicar o filtro e formatar os dados antes de entregar à fila SQS.

### A. Fila SQS (Destino)
```hcl
resource "aws_sqs_queue" "notificacoes_queue" {
  name                       = "notificacoes-queue"
  visibility_timeout_seconds = 30
  message_retention_seconds  = 86400
}
```

### B. EventBridge Pipe A (Monitorando Tabela A)
Este Pipe captura as ações da **Lambda A** (INSERT) e da **Lambda B** (MODIFY).

```hcl
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
    
    # Filtro de Eventos
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
    # Transforma o payload bruto do DynamoDB em um JSON limpo para o SQS
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
```

### C. EventBridge Pipe B (Monitorando Tabela B)
Este Pipe captura as ações da **Lambda C** (INSERT) e da **Lambda D** (MODIFY).

```hcl
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
    
    # Filtro de Eventos
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
    # Transforma o payload bruto do DynamoDB em um JSON limpo para o SQS
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
```

---

## 2. Fluxo de Dados: Os 5 Cenários

Graças ao `input_template` configurado no Terraform acima, a fila SQS **não** receberá o JSON complexo padrão do DynamoDB Streams. A fila receberá um JSON mapeado, limpo e enxuto. 

Veja como os dados se comportam em cada cenário de Lambda:

### Cenário 1: Lambda A (Tabela A - INSERT)
A Lambda A insere um novo registro com status `aceito`.

**O que o Stream gera (Evento Bruto capturado pelo Pipe):**
```json
{
  "eventName": "INSERT",
  "dynamodb": {
    "NewImage": {
      "usuarioId": {"S": "usr_123"},
      "status": {"S": "aceito"},
      "outrosDados": {"S": "..."}
    }
  }
}
```

**O que chega no SQS (Após ser filtrado e formatado pelo Pipe):**
```json
{
  "usuarioId": "usr_123",
  "statusAtual": "aceito",
  "tabelaOrigem": "TabelaA",
  "tipoEvento": "INSERT"
}
```

### Cenário 2: Lambda B (Tabela A - MODIFY)
A Lambda B altera o status de um registro existente de `aceito` para `recusado`.

**O que o Stream gera:**
```json
{
  "eventName": "MODIFY",
  "dynamodb": {
    "OldImage": {
      "usuarioId": {"S": "usr_123"},
      "status": {"S": "aceito"}
    },
    "NewImage": {
      "usuarioId": {"S": "usr_123"},
      "status": {"S": "recusado"}
    }
  }
}
```

**O que chega no SQS:**
```json
{
  "usuarioId": "usr_123",
  "statusAtual": "recusado",
  "tabelaOrigem": "TabelaA",
  "tipoEvento": "MODIFY"
}
```

### Cenário 3: Lambda D (Tabela B - MODIFY)
A Lambda D altera o status de um registro na Tabela B para `agendado`.

**O que o Stream gera:**
```json
{
  "eventName": "MODIFY",
  "dynamodb": {
    "OldImage": {
      "usuarioId": {"S": "usr_789"},
      "status": {"S": "criado"}
    },
    "NewImage": {
      "usuarioId": {"S": "usr_789"},
      "status": {"S": "agendado"}
    }
  }
}
```

**O que chega no SQS:**
```json
{
  "usuarioId": "usr_789",
  "statusAtual": "agendado",
  "tabelaOrigem": "TabelaB",
  "tipoEvento": "MODIFY"
}
```

### Cenário 4: Lambda C (Tabela B - INSERT SUCESSO)
A Lambda C cria um registro na Tabela B com status `sucesso`.

**O que o Stream gera:**
```json
{
  "eventName": "INSERT",
  "dynamodb": {
    "NewImage": {
      "usuarioId": {"S": "usr_456"},
      "status": {"S": "sucesso"}
    }
  }
}
```

**O que chega no SQS:**
```json
{
  "usuarioId": "usr_456",
  "statusAtual": "sucesso",
  "tabelaOrigem": "TabelaB",
  "tipoEvento": "INSERT"
}
```

### Cenário 5: Lambda C (Tabela B - INSERT ERRO)
A Lambda C cria um registro na Tabela B com status `erro`.

**O que o Stream gera:**
```json
{
  "eventName": "INSERT",
  "dynamodb": {
    "NewImage": {
      "usuarioId": {"S": "usr_999"},
      "status": {"S": "erro"}
    }
  }
}
```

**O que chega no SQS:**
```json
{
  "usuarioId": "usr_999",
  "statusAtual": "erro",
  "tabelaOrigem": "TabelaB",
  "tipoEvento": "INSERT"
}
```

---
**Conclusão do Fluxo:**
A sua Lambda de Notificação consumirá mensagens extremamente previsíveis do SQS. Independentemente da origem (Tabela A ou Tabela B, INSERT ou MODIFY), o JSON que o código precisará ler será sempre focado na regra de notificação, graças ao mapeamento que ocorreu nativamente no EventBridge Pipes.
