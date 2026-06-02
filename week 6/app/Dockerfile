FROM python:3.12-slim

WORKDIR /app

# Install dependencies in a separate layer so rebuilds after code-only changes are fast.
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .

# Non-root user for container security.
RUN adduser --disabled-password --gecos "" --uid 1000 appuser
USER appuser

EXPOSE 80

CMD ["python", "app.py"]
