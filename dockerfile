FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .

RUN pip install --no-cache-dir -r requirements.txt

COPY ecs_download_worker.py download_data.py ./

CMD ["python", "ecs_download_worker.py"]