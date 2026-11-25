ARG PYTHON_IMAGE=python:3.11-slim
FROM ${PYTHON_IMAGE}

WORKDIR /srv

COPY app.py .

EXPOSE 8080

CMD ["python", "app.py"]
