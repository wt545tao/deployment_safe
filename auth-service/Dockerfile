ARG PYTHON_IMAGE=python:3.11-slim
FROM ${PYTHON_IMAGE}

WORKDIR /srv

COPY app.py verify.py ./

EXPOSE 8000

CMD ["python", "app.py"]
