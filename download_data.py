import yfinance as yf
import pandas as pd
import boto3
from io import StringIO

s3 = boto3.client("s3")

BUCKET_NAME = "stock-data-bucket-504827858021-ap-south-1-an"  # Replace with your S3 bucket name


def download_and_upload_stock_data(symbol: str, date: str):

    ticker = f"{symbol}"

    start = pd.Timestamp(date)
    end = start + pd.Timedelta(days=1)

    df = yf.download(
        ticker,
        start=start.strftime("%Y-%m-%d"),
        end=end.strftime("%Y-%m-%d"),
        interval="1m",
        auto_adjust=False,
        progress=False
    )

    if df.empty:
        raise ValueError(
            f"No data available for {symbol} on {date}"
        )

    # Flatten MultiIndex
    if isinstance(df.columns, pd.MultiIndex):
        df.columns = df.columns.get_level_values(0)

    df = df.reset_index()

    df.columns = [
        str(col).lower().replace(" ", "_")
        for col in df.columns
    ]

    df["symbol"] = symbol

    # Convert DataFrame → CSV in memory
    csv_buffer = StringIO()
    df.to_csv(csv_buffer, index=False)

    # S3 path
    s3_key = (
        f"market-data/"
        f"year={start.year}/"
        f"month={start.month:02d}/"
        f"day={start.day:02d}/"
        f"symbol={symbol}/"
        f"{symbol}_{date}.csv"
    )

    # Upload to S3
    s3.put_object(
        Bucket=BUCKET_NAME,
        Key=s3_key,
        Body=csv_buffer.getvalue(),
        ContentType="text/csv"
    )

    print(
        f"Uploaded {symbol} data to "
        f"s3://{BUCKET_NAME}/{s3_key}"
    )

    return df

res  = download_and_upload_stock_data("RELIANCE", "2026-09-01")
