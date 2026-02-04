FROM python:3.11-slim

WORKDIR /app

# Dependances systeme
# hadolint ignore=DL3008
RUN apt-get update && apt-get install -y --no-install-recommends \
    libpq-dev \
    && rm -rf /var/lib/apt/lists/*

# Dependances Python
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Application
COPY app.py .

# User non-root
RUN useradd -m appuser && chown -R appuser:appuser /app
USER appuser

EXPOSE 5000

CMD ["gunicorn", "--bind", "0.0.0.0:5000", "--workers", "2", "app:app"]
