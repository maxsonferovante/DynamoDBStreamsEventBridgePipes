
---

### 1. O Fluxo Arquitetural Atualizado

* **Produtores (Sem alteração no código):**
  * **Lambda A:** `INSERT` na **Tabela A** (status: *aceito, recusado*).
  * **Lambda B:** `MODIFY` na **Tabela A** (status: *aceito* -> *recusado*).
  * **Lambda C:** `INSERT` na **Tabela B** (status: *criado, sucesso, erro*).
  * **Lambda D:** `MODIFY` na **Tabela B** (novo status: *agendado, deletado*).

* **Captura (Source):**
  * **DynamoDB Stream A:** Captura Tabela A.
  * **DynamoDB Stream B:** Captura Tabela B.

* **Filtragem e Roteamento (EventBridge Pipes):**
  * **Pipe A:** Lê Stream A, filtra usando Padrão A e envia ao SQS.
  * **Pipe B:** Lê Stream B, filtra usando Padrão B (atualizado) e envia ao SQS.

* **Buffer e Consumo (Target):**
  * **Fila SQS (NotificacoesQueue):** Centraliza os eventos de notificação.
  * **Lambda de Notificação:** Consome a fila SQS em lote e dispara o webhook (POST REST).

---

### 2. Os Filtros do EventBridge Pipes (Atualizados)

A grande sacada dos filtros do EventBridge é usar o operador lógico `$or` para combinar regras de `INSERT` e `MODIFY` dentro de um único Pipe, garantindo que eventos irrelevantes (como a atualização de um nome ou data que não muda o status) não gerem custo na sua fila SQS.

#### Pipe A (Monitorando a Tabela A)
Continua exatamente igual ao planejado: monitora inserções específicas e a mudança de "aceito" para "recusado".

```json
{
  "$or": [
    {
      "eventName": ["INSERT"],
      "dynamodb": {
        "NewImage": {
          "status": {
            "S": ["aceito", "recusado"]
          }
        }
      }
    },
    {
      "eventName": ["MODIFY"],
      "dynamodb": {
        "OldImage": {
          "status": {
            "S": ["aceito"]
          }
        },
        "NewImage": {
          "status": {
            "S": ["recusado"]
          }
        }
      }
    }
  ]
}
```

#### Pipe B (Monitorando a Tabela B) - [CORRIGIDO]
Agora, aplicamos a mesma lógica de `$or` para a Tabela B. 
A **Lambda C** gera eventos de `INSERT`. A **Lambda D** gera eventos de `MODIFY`.

```json
{
  "$or": [
    {
      "eventName": ["INSERT"],
      "dynamodb": {
        "NewImage": {
          "status": {
            "S": ["criado", "sucesso", "erro"]
          }
        }
      }
    },
    {
      "eventName": ["MODIFY"],
      "dynamodb": {
        "NewImage": {
          "status": {
            "S": ["agendado", "deletado"]
          }
        }
      }
    }
  ]
}
```

**💡 Dica de Ouro para o Pipe B (MODIFY):**
No filtro de `MODIFY` da Tabela B, estamos olhando apenas para a `NewImage` (o estado final). Isso significa: *"Se a tabela B foi atualizada e o status final é agendado ou deletado, dispare a notificação"*.

Se a sua Lambda D corre o risco de atualizar *outro campo* de um registro que *já estava* como "agendado" (gerando um novo evento MODIFY no DynamoDB onde o status continua sendo "agendado"), você acabará enviando uma notificação duplicada. 

Para evitar isso (garantindo que a notificação só saia quando o status **mudar para** agendado ou deletado), você pode usar o filtro `anything-but` na `OldImage`, assim:

```json
    {
      "eventName": ["MODIFY"],
      "dynamodb": {
        "OldImage": {
          "status": {
            "S": [{ "anything-but": ["agendado", "deletado"] }]
          }
        },
        "NewImage": {
          "status": {
            "S": ["agendado", "deletado"]
          }
        }
      }
    }
```
*Tradução da regra acima:* O status antigo não podia ser "agendado" nem "deletado", e o status novo agora é "agendado" ou "deletado". Isso garante **zero notificações duplicadas**, independente de quantas vezes a Lambda D atualize o registro!