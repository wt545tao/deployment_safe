ARG PYTHON_IMAGE=python:3.11-slim
FROM ${PYTHON_IMAGE}

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PORT=8080

# musicdl installation source. Defaults to PyPI; override to install from a
# git/source archive, e.g. --build-arg MUSICDL_SPEC="git+https://github.com/wt545tao/musicdl.git"
ARG MUSICDL_SPEC="musicdl>=2.12"
ARG PIP_INDEX_URL="https://pypi.tuna.tsinghua.edu.cn/simple"
ARG PIP_TRUSTED_HOST="pypi.tuna.tsinghua.edu.cn"

RUN useradd --system --uid 10001 --create-home --home-dir /home/appuser appuser \
    && mkdir -p /home/appuser \
    && chown appuser:appuser /home/appuser

WORKDIR /srv

COPY requirements.txt .
RUN pip install --no-cache-dir \
        --index-url "$PIP_INDEX_URL" \
        --trusted-host "$PIP_TRUSTED_HOST" \
        -r requirements.txt "$MUSICDL_SPEC"

COPY app.py serve.py ./
COPY static ./static

RUN mkdir -p /srv/downloads && chown -R appuser:appuser /srv

ENV HOME=/home/appuser

USER appuser

EXPOSE 8080

CMD ["python", "serve.py"]
