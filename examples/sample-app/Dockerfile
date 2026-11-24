FROM python:3.11-slim

RUN useradd --system --uid 10001 appuser

WORKDIR /srv

COPY app.py .

USER appuser

EXPOSE 8080

CMD ["python", "app.py"]
