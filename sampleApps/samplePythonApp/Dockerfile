# Base image
FROM python:3.11-slim

# Set working directory
WORKDIR /app

# Copy dependency specifications
COPY requirements.txt ./

# Install python dependencies
RUN pip install --no-cache-dir -r requirements.txt

# Copy application source code
COPY main.py ./

# Define environment variables with defaults
ENV PORT=3000
ENV NODE_ENV=production

# Expose port dynamically (informational only)
EXPOSE 3000

# Start app
ENTRYPOINT ["python", "main.py"]
