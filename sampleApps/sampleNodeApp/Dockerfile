# Base image
FROM node:20-slim

# Set working directory
WORKDIR /app

# Copy dependency specifications
COPY package*.json ./

# Install production dependencies
RUN npm ci --omit=dev --verbose


# Copy application source code
COPY index.js ./

# Define environment variables with defaults
ENV PORT=3000
ENV APP_ENV=production

# Expose port dynamically (informational only)
EXPOSE 3000

# Start app
ENTRYPOINT ["node", "index.js"]
