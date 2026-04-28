# Multi-stage build for security and size optimization
# Stage 1: Builder - install dependencies
FROM python:3.11-slim AS builder

WORKDIR /build

# Copy requirements first (leverage Docker layer caching)
COPY requirements.txt .

# Install dependencies with no cache to minimize layer size
RUN pip install --no-cache-dir --user -r requirements.txt


# Stage 2: Runtime - minimal image with only necessary components
FROM python:3.11-slim

# Metadata labels for tracking and security scanning
LABEL maintainer="Xgrid Internship"
LABEL description="Secure Python Health API - Production Ready"
LABEL version="1.0.0"

# Set working directory
WORKDIR /app

# Create non-root user for security (principle of least privilege)
RUN useradd -m -u 1000 appuser

# Copy only dependencies from builder stage (not entire /build directory)
COPY --from=builder --chown=appuser:appuser /root/.local /home/appuser/.local

# Copy application code with correct ownership
COPY --chown=appuser:appuser main.py .

# Set environment variables
ENV PATH=/home/appuser/.local/bin:$PATH \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

# Switch to non-root user BEFORE CMD (security best practice)
USER appuser

# Health check (Docker native health monitoring)
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD python -c "import requests; requests.get('http://localhost:8000/health')" || exit 1

# Expose port 8000
EXPOSE 8000

# Run the application
CMD ["python", "-m", "uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
