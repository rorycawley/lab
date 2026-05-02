FROM python:3.12-slim

WORKDIR /app

COPY main.py .

RUN useradd --system --uid 10001 --no-create-home app \
    && chown -R app:app /app
USER 10001

EXPOSE 8443

CMD ["python", "main.py"]
