ARG PYTHON_IMAGE=python:3.11-slim
FROM ${PYTHON_IMAGE}

RUN useradd --system --uid 10001 appuser

WORKDIR /srv

COPY app.py .

USER appuser

EXPOSE 8080

CMD ["python", "app.py"]
