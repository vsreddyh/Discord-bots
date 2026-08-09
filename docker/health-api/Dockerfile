FROM python:3.11-alpine

RUN apk add --no-cache curl sqlite

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY main.py .

ENV HEALTH_DB_PATH=/data/health.db

EXPOSE 8000

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
