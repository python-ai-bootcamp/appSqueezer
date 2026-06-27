# Application Development & Environment Parity Guide

This guide details the standards for developing applications that are compatible with the rootless gateway (`appRouter`) deployment model. By following these patterns, you guarantee **100% environment parity**—your code will behave exactly the same way during local PC development (using Docker) as it does on the production VM (using Podman).

---

## 1. Core Principles

To ensure seamless production deployment:
1. **Dynamic Port Binding**: Applications must never bind to a hardcoded port (like `3000` or `8000`). Instead, they must bind dynamically to the port specified in the `PORT` environment variable.
2. **Secrets-Based Configuration**: Applications must load sensitive data (like database connection strings and custom passwords) from files inside the `/run/secrets/` directory instead of environment variables.
3. **The `--show-spec` Contract**: The container image must support a `--show-spec` flag that outputs its required environment parameters and secrets to stdout.
4. **Environment Parity Fallbacks**: During local development, the code should support fallback options (like checking standard env vars if secret files do not exist) so developers can run the app without manual mounts.

### 1.5 The `--show-spec` Implementation

When `appRouter.sh` deploys a container, it performs a pre-flight validation check by running:
```bash
podman run --rm <image> --show-spec
```
The application must intercept this flag at startup, print its configuration requirements to stdout, and exit immediately with code `0` in this format:
```text
REQUIRED_PARAMETERS=multiplication_factor,DEBUG
REQUIRED_SECRETS=ADMIN_PASSWORD,THIRD_PARTY_API_KEY
```

#### Node.js Implementation:
```javascript
if (process.argv.includes('--show-spec')) {
    console.log('REQUIRED_PARAMETERS=multiplication_factor');
    console.log('REQUIRED_SECRETS=ADMIN_PASSWORD');
    process.exit(0);
}
```

#### Python Implementation:
```python
import sys
if '--show-spec' in sys.argv:
    print('REQUIRED_PARAMETERS=multiplication_factor')
    print('REQUIRED_SECRETS=ADMIN_PASSWORD')
    sys.exit(0)
```

---

## 2. Reading Secrets (MONGO_URI)

In production, the database URI is injected into the container as a file-based secret at `/run/secrets/MONGO_URI`. 

Here is the standard implementation pattern to read this secret with a fallback for local development:

### 🟢 Node.js (JavaScript)
```javascript
const fs = require('fs');
const path = require('path');

let mongoUri;
const secretPath = '/run/secrets/MONGO_URI';

if (fs.existsSync(secretPath)) {
    // Read the secret from the container mount
    mongoUri = fs.readFileSync(secretPath, 'utf8').trim();
} else if (process.env.MONGO_URI) {
    // Fallback to local environment variable
    mongoUri = process.env.MONGO_URI;
} else {
    console.error('Error: MongoDB connection string not found.');
    process.exit(1);
}
```

### 🐍 Python (FastAPI / PyMongo)
```python
import os
import sys

secret_path = "/run/secrets/MONGO_URI"

if os.path.exists(secret_path):
    # Read the secret from the container mount
    with open(secret_path, "r", encoding="utf-8") as f:
        mongo_uri = f.read().strip()
elif os.getenv("MONGO_URI"):
    # Fallback to local environment variable
    mongo_uri = os.getenv("MONGO_URI")
else:
    print("Error: MongoDB connection string not found.", file=sys.stderr)
    sys.exit(1)
```

---

## 3. Dynamic Port & Domain Handling

The wrapper utility generates a `.env.production` file for each application, passing `PORT` and `APP_DOMAIN` automatically.

### Port Binding
* **Node.js Express**:
  ```javascript
  const port = process.env.PORT || 3000;
  app.listen(port, () => console.log(`Server running on port ${port}`));
  ```
* **Python Uvicorn (Dockerfile)**:
  Ensure your `Dockerfile` uses the exec-form `ENTRYPOINT` to allow arguments (like `--show-spec`) to be forwarded correctly:
  ```dockerfile
  ENTRYPOINT ["python", "main.py"]
  ```

### Domain Name Retrieval
The `APP_DOMAIN` variable is copied dynamically from the central router infrastructure config. Use it inside your code for absolute redirects, logging, CORS policies, or cookie session scopes:
```javascript
const domain = process.env.APP_DOMAIN || 'localhost';
```

---

## 4. Local Development Environment Setup (PC Parity)

To test your application locally using Docker while mimicking the production secrets behavior, use a local **Docker Compose override file** or define local secrets in your development `docker-compose.yml`.

### Example `docker-compose.dev.yml`
```yaml
version: "3.8"

services:
  web-app:
    build: .
    ports:
      - "3000:3000"
    environment:
      - PORT=3000
      - APP_DOMAIN=localhost
      - multiplication_factor=5
    secrets:
      - source: dev_mongo_uri
        target: MONGO_URI # Mounts as /run/secrets/MONGO_URI
      - source: dev_admin_password
        target: ADMIN_PASSWORD # Mounts as /run/secrets/ADMIN_PASSWORD

  mongo-db:
    image: mongo:7.0
    ports:
      - "27017:27017"

secrets:
  dev_mongo_uri:
    file: ./dev_mongo_uri.txt # Local connection string file
  dev_admin_password:
    file: ./dev_admin_password.txt # Local secret file containing your admin password
```

1. Create local credential text files in your project directory:
   * `dev_mongo_uri.txt`:
     ```text
     mongodb://mongo-db:27017/my_dev_database
     ```
   * `dev_admin_password.txt`:
     ```text
     my_secure_dev_password
     ```
2. Run your local dev server:
   ```bash
   docker compose -f docker-compose.dev.yml up --build
   ```

At startup, the local Docker engine will mount both secret files inside `/run/secrets/` in memory. This gives your application 100% environment parity with your production VM, where the VM operator deploys with:
```bash
./appRouter.sh create-app <image> --app-parameter "multiplication_factor=5" --app-secret "ADMIN_PASSWORD=my_secure_prod_password"
```
