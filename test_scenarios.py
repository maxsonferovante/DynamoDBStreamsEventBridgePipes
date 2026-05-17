import boto3
import time

def test_scenarios():
    dynamodb = boto3.resource('dynamodb', region_name='us-east-1')
    
    tabela_a = dynamodb.Table('tabela-a')
    tabela_b = dynamodb.Table('tabela-b')
    
    print("Iniciando testes dos cenários de DynamoDB Streams -> EventBridge Pipes -> SQS...\n")

    # =========================================================================
    # Cenário 1: Lambda A (Tabela A - INSERT)
    # A Lambda A insere um novo registro com status `aceito`.
    # =========================================================================
    print("--- Cenário 1: Tabela A (INSERT) ---")
    print("Inserindo registro em 'tabela-a' com status 'aceito'")
    tabela_a.put_item(
        Item={
            'usuarioId': 'usr_123',
            'status': 'aceito',
            'outrosDados': 'Este é um teste do cenário 1'
        }
    )
    print("Cenário 1 executado com sucesso!\n")
    
    # Aguardar um pouco entre os eventos
    time.sleep(2)

    # =========================================================================
    # Cenário 2: Lambda B (Tabela A - MODIFY)
    # A Lambda B altera o status de um registro existente de `aceito` para `recusado`.
    # =========================================================================
    print("--- Cenário 2: Tabela A (MODIFY) ---")
    print("Atualizando registro 'usr_123' em 'tabela-a' para status 'recusado'")
    tabela_a.update_item(
        Key={'usuarioId': 'usr_123'},
        UpdateExpression="set #st = :s",
        ExpressionAttributeNames={'#st': 'status'},
        ExpressionAttributeValues={':s': 'recusado'}
    )
    print("Cenário 2 executado com sucesso!\n")
    
    time.sleep(2)

    # =========================================================================
    # Cenário 3: Lambda D (Tabela B - MODIFY)
    # A Lambda D altera o status de um registro na Tabela B para `agendado`.
    # =========================================================================
    print("--- Cenário 3: Tabela B (MODIFY) ---")
    # Para atualizar a partir de "criado", primeiro precisamos inserir o registro como "criado"
    print("Preparando cenário 3: Inserindo registro em 'tabela-b' com status 'criado'")
    tabela_b.put_item(
        Item={
            'usuarioId': 'usr_789',
            'status': 'criado'
        }
    )
    
    time.sleep(2)
    
    print("Executando cenário 3: Atualizando registro 'usr_789' em 'tabela-b' para status 'agendado'")
    tabela_b.update_item(
        Key={'usuarioId': 'usr_789'},
        UpdateExpression="set #st = :s",
        ExpressionAttributeNames={'#st': 'status'},
        ExpressionAttributeValues={':s': 'agendado'}
    )
    print("Cenário 3 executado com sucesso!\n")
    
    time.sleep(2)

    # =========================================================================
    # Cenário 4: Lambda C (Tabela B - INSERT SUCESSO)
    # A Lambda C cria um registro na Tabela B com status `sucesso`.
    # =========================================================================
    print("--- Cenário 4: Tabela B (INSERT SUCESSO) ---")
    print("Inserindo registro em 'tabela-b' com status 'sucesso'")
    tabela_b.put_item(
        Item={
            'usuarioId': 'usr_456',
            'status': 'sucesso',
            'detalhes': 'Teste do cenário 4 (sucesso)'
        }
    )
    print("Cenário 4 executado com sucesso!\n")
    
    time.sleep(2)

    # =========================================================================
    # Cenário 5: Lambda C (Tabela B - INSERT ERRO)
    # A Lambda C cria um registro na Tabela B com status `erro`.
    # =========================================================================
    print("--- Cenário 5: Tabela B (INSERT ERRO) ---")
    print("Inserindo registro em 'tabela-b' com status 'erro'")
    tabela_b.put_item(
        Item={
            'usuarioId': 'usr_999',
            'status': 'erro',
            'detalhes': 'Teste do cenário 5 (erro)'
        }
    )
    print("Cenário 5 executado com sucesso!\n")

    print("Todos os dados de teste foram inseridos com sucesso!")
    print("Os eventos devem aparecer na fila SQS 'notificacoes-queue' em instantes.")

if __name__ == "__main__":
    try:
        test_scenarios()
    except Exception as e:
        print(f"Ocorreu um erro ao executar o teste: {e}")
        print("Verifique se as tabelas existem (rodou terraform apply?) e se as credenciais da AWS estão configuradas (aws sso login ou variáves de ambiente).")
