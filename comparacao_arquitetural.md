# Comparativo Arquitetural: Notificações Baseadas em Eventos

Este documento analisa duas abordagens arquiteturais para a captura e envio de eventos de notificação em um sistema AWS Serverless: a abordagem utilizando **Change Data Capture (CDC)** via DynamoDB Streams e a abordagem de **Publicação Direta** pelas próprias Lambdas de negócio.

---

## Arquitetura 1: CDC com DynamoDB Streams + EventBridge Pipes (A Atual)

Nesta arquitetura, as Lambdas de negócio (A, B, C e D) apenas interagem com o DynamoDB. O **DynamoDB Streams** captura as alterações no banco (INSERTs e MODIFYs), o **EventBridge Pipes** filtra os eventos relevantes e os encaminha para uma Fila **SQS**, que finalmente aciona a **Lambda de Notificação**.

### Benefícios
*   **Garantia de Consistência (Sem *Dual-Write*):** Se o dado foi salvo no banco, o evento é gerado. Não há risco da transação no banco ter sucesso e a notificação falhar em ser enfileirada.
*   **Desacoplamento Total:** O código das Lambdas de negócio (A, B, C e D) não sabe que o serviço de notificação existe. Isso facilita a manutenção e os testes unitários.
*   **Responsabilidade Única (Clean Architecture):** As Lambdas de negócio focam apenas nas regras de negócio e persistência.
*   **Baixo Custo Computacional no Código:** Não é necessário adicionar SDKs de mensageria, *retries* ou lidar com *timeouts* da rede dentro do código da regra de negócio. O EventBridge Pipes resolve isso na camada de infraestrutura.
*   **Extensibilidade Segura:** Se um novo serviço precisar ouvir os mesmos eventos amanhã, basta adicionar um novo *Target* ao EventBridge Pipes, sem tocar em nenhuma linha de código legado.

### Riscos e Desvantagens
*   **Acoplamento ao Esquema do Banco:** O evento que trafega no sistema é literalmente a estrutura da tabela do banco de dados. Se o nome de uma coluna mudar no DynamoDB, o filtro do EventBridge Pipes e a Lambda de Notificação quebrarão.
*   **Restrição de Dados:** A notificação só pode ser montada com os dados que estão persistidos na Tabela. Se a notificação precisar de um dado efêmero (que a Lambda processou mas não salvou no banco), esta arquitetura não atende bem.
*   **Curva de Aprendizado e Operação:** Exige domínio sobre serviços como EventBridge Pipes, mapeamento de schemas (VTL/JSON Path no Target Input Transformer) e configuração do DynamoDB Streams.
*   **Maior Latência (*Hops*):** O evento precisa passar pelo DynamoDB -> Stream -> Pipes -> SQS -> Lambda, o que adiciona alguns milissegundos a mais na entrega em comparação ao envio direto.

---

## Arquitetura 2: Publicação Direta (Lambdas enviando direto para a Fila SQS)

Nesta alternativa, as Lambdas de negócio (A, B, C e D) são modificadas. Dentro do código delas, após (ou antes) salvar no DynamoDB, elas chamam ativamente a API do SQS para enfileirar a mensagem de notificação.

### Benefícios
*   **Flexibilidade do Payload (Eventos Ricos):** O evento enviado para a fila não precisa ser o espelho da tabela do banco. A Lambda pode compor um payload customizado com dados externos, variáveis de ambiente ou parâmetros efêmeros antes de enviar à fila.
*   **Desacoplamento do Esquema do Banco:** O banco de dados e os eventos do sistema podem evoluir de forma independente. Uma refatoração na estrutura da tabela do DynamoDB não quebra os consumidores da fila.
*   **Menos "Peças Móveis" de Infraestrutura:** Remove o DynamoDB Streams e o EventBridge Pipes do diagrama. O fluxo fica apenas: Lambda Negócio -> SQS -> Lambda Notificação. Isso pode simplificar o Terraform/CloudFormation.

### Riscos e Desvantagens
*   **O Problema do *Dual-Write* (Risco Crítico):** Se a Lambda salva no banco (Sucesso) e tenta enviar para o SQS, mas a rede oscila (Timeout/Erro), o banco fica com o status "recusado", mas o usuário nunca será notificado. Resolver o *Dual-Write* com consistência eventual (padrões como *Outbox Pattern*) adiciona enorme complexidade ao código.
*   **Poluição de Responsabilidades:** O código da Lambda A, B, C e D agora precisa gerenciar regras de negócio, persistência de dados, e também a lógica de mensageria (tratamento de erros de SQS, formatação de eventos, etc).
*   **Maior Tempo de Execução e Custo na Lambda:** Como a Lambda precisa fazer uma chamada de rede extra (para o SQS), o tempo de execução (que dita o custo da AWS Lambda) aumenta.
*   **Aumento na Superfície de Manutenção:** Se a formatação do evento base de notificação mudar, você precisará atualizar, testar e fazer o *deploy* das 4 Lambdas separadamente.

---

## Tabela Comparativa Resumo

| Característica | Arq 1: CDC (DynamoDB Streams) | Arq 2: Publicação Direta (SQS) |
| :--- | :--- | :--- |
| **Garantia de Entrega / Consistência** | Muito Alta (Fonte da verdade é o BD) | Baixa (Risco de inconsistência por Dual-Write) |
| **Complexidade no Código da Lambda** | Baixa (Não muda nada) | Alta (Adiciona lógica de infraestrutura e retries) |
| **Complexidade da Infraestrutura** | Média/Alta (Streams + Pipes) | Baixa (Apenas a Fila SQS) |
| **Flexibilidade do Payload** | Baixa (Preso ao esquema da tabela) | Alta (Total controle no código) |
| **Acoplamento entre Serviços** | Totalmente Desacoplado | Parcialmente Acoplado |

## Conclusão e Recomendação

A **Arquitetura 1 (CDC com DynamoDB Streams e EventBridge Pipes)** é a abordagem **recomendada** para o seu cenário. 

Como você já tem o DynamoDB Streams ativado e o gatilho da sua notificação é exatamente a mudança de estado na tabela (ex: aceito -> recusado), faz muito sentido usar a infraestrutura da AWS para garantir a entrega desse evento sem o risco do *Dual-Write*. A economia de código nas suas 4 Lambdas atuais justifica a adoção do EventBridge Pipes, transformando a AWS no responsável por garantir que, se o dado mudou, o evento chegará à fila.

A **Arquitetura 2** só seria indicada se você tivesse requisitos fortes de payloads de notificação com informações que **não** residem no DynamoDB, ou se você estivesse usando um banco de dados relacional sem um suporte amigável para CDC.
