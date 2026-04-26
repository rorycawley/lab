FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY proxy.py .

RUN useradd --system --uid 10001 --no-create-home pgproxy \
    && chown -R pgproxy:pgproxy /app
USER 10001

EXPOSE 6432

CMD ["python", "-u", "proxy.py"]
