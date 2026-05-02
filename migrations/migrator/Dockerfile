FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1

WORKDIR /migrator

RUN useradd --uid 10002 --create-home migrator

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY migrate.py .
COPY migrations ./migrations

USER 10002

CMD ["python", "migrate.py"]

