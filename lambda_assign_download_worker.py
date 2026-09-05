import json
import os
import boto3
import uuid
from datetime import datetime

sqs = boto3.client("sqs")

# QUEUE_URL = os.environ["QUEUE_URL"]
QUEUE_URL = "https://sqs.us-east-1.amazonaws.com/504827858021/download_data_queue"

NIFTY_50 = [
    "ADANIENT",
    "ADANIPORTS",
    "APOLLOHOSP",
    "ASIANPAINT",
    "AXISBANK",
    "BAJAJ-AUTO",
    "BAJFINANCE",
    "BAJAJFINSV",
    "BEL",
    "BHARTIARTL",
    "CIPLA",
    "COALINDIA",
    "DRREDDY",
    "EICHERMOT",
    "ETERNAL",
    "GRASIM",
    "HCLTECH",
    "HDFCBANK",
    "HDFCLIFE",
    "HEROMOTOCO",
    "HINDALCO",
    "HINDUNILVR",
    "ICICIBANK",
    "INDUSINDBK",
    "INFY",
    "ITC",
    "JIOFIN",
    "JSWSTEEL",
    "KOTAKBANK",
    "LT",
    "M&M",
    "MARUTI",
    "MAXHEALTH",
    "NESTLEIND",
    "NTPC",
    "ONGC",
    "POWERGRID",
    "RELIANCE",
    "SBILIFE",
    "SHRIRAMFIN",
    "SBIN",
    "SUNPHARMA",
    "TATACONSUM",
    "TATAMOTORS",
    "TATASTEEL",
    "TCS",
    "TECHM",
    "TITAN",
    "TRENT",
    "ULTRACEMCO",
    "WIPRO"
]


def lambda_handler(event, context):

    job_id = str(uuid.uuid4())

    today = datetime.utcnow().strftime("%Y-%m-%d")
    NIFTY_5  = NIFTY_50[:5]  # For testing, limit to first 5 symbols

    for symbol in NIFTY_5:

        message = {
            "job_id": job_id,
            "symbol": symbol,
            "exchange": "NSE",
            "date": today,
            "task": "download_daily_data"
        }

        print("Queuing message:", message)
        response = sqs.send_message(
            QueueUrl=QUEUE_URL,
            MessageBody=json.dumps(message)
        )

        print(
            f"Queued {symbol}, "
            f"message_id={response['MessageId']}"
        )


    return {
        "statusCode": 200,
        "body": json.dumps({
            "job_id": job_id,
            "stocks_queued": len(NIFTY_5)
        })
    }

resp = lambda_handler({}, {})
print(resp)