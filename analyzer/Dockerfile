FROM python:3.12-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends ffmpeg libchromaprint-tools tzdata \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements*.txt .
ARG ADVANCED_ANALYSIS=true
RUN if [ "$ADVANCED_ANALYSIS" = "true" ]; then \
      pip install --no-cache-dir --extra-index-url https://download.pytorch.org/whl/cpu -r requirements.txt; \
    else pip install --no-cache-dir -r requirements-loudness.txt; fi
ENV ADVANCED_ANALYSIS=$ADVANCED_ANALYSIS

COPY entrypoint.sh /entrypoint.sh
# Copied from Windows, the script can have CRLF line endings, which sh can't run.
RUN sed -i 's/\r$//' /entrypoint.sh && chmod 755 /entrypoint.sh
COPY app.py genre_fit.py landmarks.py loudness.py mashup.py structure.py karaoke.py karaoke_proxy.py hub*.py server_*.py ./
COPY hub_web ./hub_web

ENV DATA_DIR=/data HF_HOME=/data/huggingface
# Fewer malloc arenas, so memory freed by the many worker threads (the CLAP model's) can go back to the system.
ENV MALLOC_ARENA_MAX=2
VOLUME /data
EXPOSE 8787
HEALTHCHECK --interval=60s --timeout=10s --start-period=120s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8787/healthz', timeout=8)"
ENTRYPOINT ["/entrypoint.sh"]
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8787"]
