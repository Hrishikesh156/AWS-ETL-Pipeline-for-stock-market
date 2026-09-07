import boto3
import json
import os
import time
from download_data import download_and_upload_stock_data
sqs = boto3.client("sqs")

#QUEUE_URL = os.environ["QUEUE_URL"]
QUEUE_URL = "https://sqs.ap-south-1.amazonaws.com/504827858021/download-stock-data-queue"


while True:

    response = sqs.receive_message(
        QueueUrl=QUEUE_URL,
        MaxNumberOfMessages=1,
        WaitTimeSeconds=20
    )

    messages = response.get("Messages", [])

    for message in messages:

        receipt_handle = message["ReceiptHandle"]

        try:

            job = json.loads(message["Body"])

            symbol = job["symbol"]
            date = job["date"]

            print(f"Processing {symbol}")

            download_and_upload_stock_data(symbol, date)

            # Delete ONLY after successful processing
            sqs.delete_message(
                QueueUrl=QUEUE_URL,
                ReceiptHandle=receipt_handle
            )

            print(f"Completed {symbol}")

        except Exception as e:

            print(f"Failed: {e}")

            # Don't delete the message.
            # SQS will make it visible again after
            # the visibility timeout.