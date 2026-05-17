import boto3
import json
import time

def monitor_queue():
    sqs = boto3.client('sqs', region_name='us-east-1')
    
    # Busca a URL da fila usando o nome
    queue_name = 'notificacoes-queue'
    try:
        response = sqs.get_queue_url(QueueName=queue_name)
        queue_url = response['QueueUrl']
        print(f"Monitorando a fila: {queue_name}")
        print(f"URL: {queue_url}\n")
    except Exception as e:
        print(f"Erro ao buscar a fila {queue_name}. Ela já foi criada com o terraform apply?\nDetalhes: {e}")
        return

    print("Aguardando mensagens... (Pressione Ctrl+C para sair)")
    
    try:
        while True:
            # Long polling de 20 segundos para aguardar mensagens
            response = sqs.receive_message(
                QueueUrl=queue_url,
                MaxNumberOfMessages=10,
                WaitTimeSeconds=20
            )

            messages = response.get('Messages', [])
            
            if not messages:
                print(".", end="", flush=True)
                continue
                
            print("\n")
            for msg in messages:
                receipt_handle = msg['ReceiptHandle']
                body = msg['Body']
                
                print("="*60)
                print("📨 NOVA MENSAGEM RECEBIDA!")
                print("="*60)
                
                try:
                    # O payload que chega deve ser um JSON limpo formatado pelo input_template do Pipes
                    parsed_body = json.loads(body)
                    print(json.dumps(parsed_body, indent=4, ensure_ascii=False))
                except json.JSONDecodeError:
                    # Fallback caso não seja um JSON válido
                    print(body)
                
                print("-" * 60)
                
                # Deleta a mensagem após "processar"
                sqs.delete_message(
                    QueueUrl=queue_url,
                    ReceiptHandle=receipt_handle
                )
                print("🗑️  Mensagem processada e removida da fila.\n")
                
    except KeyboardInterrupt:
        print("\n\nMonitoramento encerrado pelo usuário.")
    except Exception as e:
        print(f"\nOcorreu um erro durante o monitoramento: {e}")

if __name__ == "__main__":
    monitor_queue()
