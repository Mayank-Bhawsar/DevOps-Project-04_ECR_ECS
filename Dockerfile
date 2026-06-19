# =============================================================================
# Django Application Dockerfile
# =============================================================================
# This Dockerfile creates a production-ready container for Django applications
# optimized for AWS ECS deployment with security and performance best practices
# =============================================================================

# ------------------------------------------------------------------------------
# Multi-stage build for optimized production image
# ------------------------------------------------------------------------------

# Stage 1: Build stage with development dependencies
FROM python:3.9-slim as builder

# Set environment variables for build
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

# Install build dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    libpq-dev \
    && rm -rf /var/lib/apt/lists/*

# Create and activate virtual environment
RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

# Copy and install Python dependencies
COPY requirements.txt /tmp/
RUN pip install --no-cache-dir -r /tmp/requirements.txt

# ------------------------------------------------------------------------------
# Production stage
# ------------------------------------------------------------------------------

# Use minimal base image for production
FROM python:3.9-slim as production

# Set environment variables for production
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    DJANGO_SETTINGS_MODULE=myproject.settings.production \
    PATH="/opt/venv/bin:$PATH"

# Install runtime dependencies only
RUN apt-get update && apt-get install -y --no-install-recommends \
    libpq5 \
    curl \
    && rm -rf /var/lib/apt/lists/* \
    && apt-get clean

# Create non-root user for security
RUN groupadd -r django && useradd -r -g django django

# Copy virtual environment from builder stage
COPY --from=builder /opt/venv /opt/venv

# Set working directory
WORKDIR /usr/src/app

# Copy application code with proper ownership
COPY --chown=django:django . .

# Create necessary directories and set permissions
RUN mkdir -p /usr/src/app/static /usr/src/app/media /usr/src/app/logs \
    && chown -R django:django /usr/src/app

# Switch to non-root user
USER django

# Collect static files
RUN python manage.py collectstatic --noinput --clear

# Health check for container orchestration
HEALTHCHECK --interval=30s --timeout=10s --start-period=40s --retries=3 \
    CMD curl -f http://localhost:8000/health/ || exit 1

# Expose application port
EXPOSE 8000

# ------------------------------------------------------------------------------
# Application startup
# ------------------------------------------------------------------------------

# Use gunicorn for production WSGI server
CMD ["gunicorn", "--bind", "0.0.0.0:8000", "--workers", "3", "--timeout", "120", "--access-logfile", "-", "--error-logfile", "-", "myproject.wsgi:application"]
