FROM python:3.12-slim

RUN groupadd --system --gid 1000 app \
 && useradd  --system --uid 1000 --gid app --no-create-home --home-dir /app app

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY main.py .

RUN chown -R app:app /app

USER 1000:1000

EXPOSE 8080

CMD ["python", "main.py"]
