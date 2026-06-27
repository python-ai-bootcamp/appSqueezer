# Agentic Skill - Make Project Support appRouter Deployment

This skill teaches you how to automatically refactor and prepare any web application repository to support dynamic deployment on a production VM using the rootless `appRouter.sh` orchestrator.

---

## Refactoring Steps

Follow these sequential steps to adapt the target project:

### Step 1: Detect Language & Main Entrypoint
1. Scan the repository to determine the primary language and framework:
   * **Node.js**: Presence of `package.json`. Look for the `"main"` entrypoint file (usually `index.js`, `server.js`, or `app.js`).
   * **Python**: Presence of `requirements.txt`, `pyproject.toml`, or `setup.py`. Locate the main script or API routing entrypoint (usually `main.py` or `app.py`).
2. Identify all required environment parameters and sensitive keys (e.g. database connections, API tokens) used throughout the code.

---

### Step 2: Implement the `--show-spec` Contract
At the absolute beginning of the application's startup file (before database or server initialization), intercept the CLI argument `--show-spec`. If present, print the list of required parameters and secrets, and exit immediately with code `0`.

#### Node.js Template:
```javascript
if (process.argv.includes('--show-spec')) {
  console.log('REQUIRED_PARAMETERS=multiplication_factor,OTHER_ENV_VAR');
  console.log('REQUIRED_SECRETS=ADMIN_PASSWORD,CUSTOM_API_KEY');
  process.exit(0);
}
```

#### Python Template:
```python
import sys
if '--show-spec' in sys.argv:
    print('REQUIRED_PARAMETERS=multiplication_factor,OTHER_ENV_VAR')
    print('REQUIRED_SECRETS=ADMIN_PASSWORD,CUSTOM_API_KEY')
    sys.exit(0)
```

---

### Step 3: Implement the Secrets Loader Helper
To maintain environment parity, the application must read credentials from volatile mounted files in production (`/run/secrets/`), but fall back to environment variables locally.

Inject the following helper function into the database configuration or system utility file:

#### Node.js:
```javascript
const fs = require('fs');
const path = require('path');

function getSecretOrEnv(secretName, envFallbackName) {
  const secretPath = path.join('/run/secrets', secretName);
  if (fs.existsSync(secretPath)) {
    return fs.readFileSync(secretPath, 'utf8').trim();
  }
  return process.env[envFallbackName] || process.env[secretName] || '';
}

// Example usage:
const mongoUri = getSecretOrEnv('MONGO_URI', 'MONGO_URI');
const adminPassword = getSecretOrEnv('ADMIN_PASSWORD', 'ADMIN_PASSWORD');
```

#### Python:
```python
import os

def get_secret_or_env(secret_name: str, env_fallback_name: str) -> str:
    secret_path = os.path.join('/run/secrets', secret_name)
    if os.path.exists(secret_path):
        with open(secret_path, 'r', encoding='utf-8') as f:
            return f.read().strip()
    return os.getenv(env_fallback_name) or os.getenv(secret_name) or ''

# Example usage:
mongo_uri = get_secret_or_env('MONGO_URI', 'MONGO_URI')
admin_password = get_secret_or_env('ADMIN_PASSWORD', 'ADMIN_PASSWORD')
```

---

### Step 4: Bind Dynamically to `PORT`
Ensure the server is not listening on a hardcoded port. Update the bootstrap code:
* **Node.js**:
  ```javascript
  const port = process.env.PORT || 3000;
  app.listen(port, () => console.log(`Server listening on port ${port}`));
  ```
* **Python (Uvicorn)**:
  Ensure the launch script binds to the port variable:
  ```python
  import uvicorn
  port = int(os.getenv("PORT", "3000"))
  uvicorn.run("main:app", host="0.0.0.0", port=port)
  ```

---

### Step 5: Configure Local Workstation Parity (`.env` & compose)
1. Generate an `.env` file containing dev environment variables (like mock API keys and database strings).
2. Append `.env` to the project's `.gitignore` to prevent committing secrets to source control.
3. Generate a local `docker-compose.dev.yml` file to test the application locally with database container services and the local `.env` variables mapped:
   ```yaml
   version: "3.8"
   services:
     web-app:
       build: .
       ports:
         - "3000:3000"
       env_file:
         - .env
     # local helper database if needed
   ```

---

### Step 6: Create the Dockerfile
Generate a standardized `Dockerfile` in the root of the project:
* Ensure it uses lightweight official base images (e.g. `node:20-alpine`, `python:3.11-slim`).
* Expose port `3000`.
* Ensure that the execution command (`CMD` or `ENTRYPOINT`) uses shell form or permits passing CLI arguments (so that `podman run --rm <image> --show-spec` behaves correctly).
  * **Correct Node**: `CMD ["node", "index.js"]`
  * **Correct Python**: `CMD ["python", "main.py"]`

---

### Step 7: Create GHCR Deployment Script
Generate a deployment script at `scripts/deploy-ghcr.sh` that automates image publishing:
```bash
#!/bin/bash
set -e

# Read package name from package.json or project config
APP_NAME="my-app"
GHCR_USER="your-github-username"

echo "Building production image..."
docker build -t ghcr.io/$GHCR_USER/$APP_NAME:latest .

echo "Pushing image to GitHub Container Registry..."
docker push ghcr.io/$GHCR_USER/$APP_NAME:latest

echo -e "\nDeployment setup ready!"
echo -e "Copy and run this command on your production VM:"
echo -e "  ./appRouter.sh create-app ghcr.io/$GHCR_USER/$APP_NAME:latest"
```
Make the script executable: `chmod +x scripts/deploy-ghcr.sh`.
