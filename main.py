import threading

# pyrefly: ignore [missing-import]
from monitor_sqs import monitor_queue
from test_scenarios import test_scenarios


def main():
    monitor_sqs_thread = threading.Thread(target=monitor_queue, daemon=True)
    test_scenarios_thread = threading.Thread(target=test_scenarios, daemon=True)

    monitor_sqs_thread.start()
    test_scenarios_thread.start()

    monitor_sqs_thread.join()
    test_scenarios_thread.join()


if __name__ == "__main__":
    main()
