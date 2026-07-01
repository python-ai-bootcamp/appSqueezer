# Application Development & Environment Parity Guide

This guide details the standards for developing applications that are compatible with the rootless gateway (`appSqueezer`) deployment model. By following these patterns, you guarantee **100% environment parity**—your code will behave exactly the same way during local PC development (using Docker) as it does on the production VM (using Podman).

---

## 1. Core Principles

To ensure seamless production deployment:
1. **Dynamic Port Binding**: Applications must never bind to a hardcoded port. The production gateway is hardcoded to forward traffic to port `3000` inside your container, meaning your application **must** bind dynamically to the port specified in the `PORT` environment variable (which the gateway automatically sets to `3000` in production) and default to `3000` locally.
2. **Secrets-Based Configuration**: Applications must load sensitive data (like database connection strings and custom passwords) from files inside the `/run/secrets/` directory instead of environment variables.
3. **The `--show-spec` Contract**: The container image must support a `--show-spec` flag that outputs its required environment parameters and secrets to stdout.
4. **Environment Parity Fallbacks**: During local development, the code should support fallback options (like checking standard env vars if secret files do not exist) so developers can run the app without manual mounts.

### 1.5 The `--show-spec` Implementation

When `appSqueezer.sh` deploys a container, it performs a pre-flight validation check by running:
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
Because the edge router (Traefik) expects downstream container services to listen on port `3000`, the orchestrator automatically writes `PORT=3000` to `.env.production` for your application container. Your code must read this value and bind to it dynamically.

* **Node.js Express**:
  ```javascript
  const port = process.env.PORT || 3000;
  app.listen(port, () => console.log(`Server running on port ${port}`));
  ```
* **Python Uvicorn (Dockerfile)**:
  Ensure your application binds to the environment variable inside the code, and ensure your `Dockerfile` uses the exec-form `ENTRYPOINT` to allow arguments (like `--show-spec`) to be forwarded correctly:
  ```dockerfile
  ENTRYPOINT ["python", "main.py"]
  ```

### Domain Name Retrieval
The `APP_DOMAIN` variable is copied dynamically from the central router infrastructure config. Use it inside your code for absolute redirects, logging, CORS policies, or cookie session scopes:
```javascript
const domain = process.env.APP_DOMAIN || 'localhost';
```

### Path-Prefix Routing & Asset URLs

Because `appSqueezer` hosts applications under path prefixes (e.g., `https://<domain>/<app-name>`) and strips this prefix before forwarding the request to the container, absolute links to root assets (e.g., `<script src="/main.js">` or `<a href="/login">`) will fail. The client browser will request `https://<domain>/main.js` instead of the correct path, which bypasses the application and returns a 404 error.

To avoid this, ensure that all HTML links, asset references, and API redirects use either:
1. **Relative Paths**: e.g., `<script src="./main.js">` or `<a href="login">`.
2. **App-Prefixed Paths**: Prefix all routing paths with the application name (e.g., `/<app-name>/main.js`), matching the route prefix in production.

---

## 4. Local Development Environment Setup (PC Parity)

To test your application locally using Docker while mimicking the production secrets behavior, use a local **Docker Compose override file** or define local secrets in your development `docker-compose.yml`.

### Example `docker-compose.dev.yml`
```yaml
services:
  web-app:
    build: .
    ports:
      - "3000:3000"
    environment:
      - PORT=3000
      - APP_DOMAIN=localhost
      - multiplication_factor=5 # Example of an app-specific parameter
    secrets:
      - source: dev_mongo_uri
        target: MONGO_URI # Mounts as /run/secrets/MONGO_URI
      - source: dev_admin_password
        target: ADMIN_PASSWORD # Example of an app-specific optional secret

  mongo-db:
    image: mongo:7.0
    ports:
      - "27017:27017"

secrets:
  dev_mongo_uri:
    file: ../dev_secrets/dev_mongo_uri.txt # Local connection string file (kept outside the Git repo)
  dev_admin_password:
    file: ../dev_secrets/dev_admin_password.txt # Local secret file containing your admin password (kept outside the Git repo)
```

> [!IMPORTANT]
> **Keep local secrets safe**: Do not store plain text password files inside your Git repository. It is a best practice to place them in a dedicated directory outside the repository root (e.g. `../dev_secrets/`). If you must place them inside the repository during testing, ensure they are explicitly added to your `.gitignore` file.

> [!NOTE]
> **Initialize Local Secret Files**: Write the default contents for the dev secret files in a folder outside the project directory to allow immediate local execution via `docker compose -f docker-compose.dev.yml up`:
> 1. `../dev_secrets/dev_mongo_uri.txt`:
>    ```text
>    mongodb://mongo-db:27017/my_dev_db
>    ```
> 2. `../dev_secrets/dev_admin_password.txt`:
>    ```text
>    my_secure_dev_password
>    ```

1. Create a directory named `dev_secrets` outside the project root and add the text files:
   * `../dev_secrets/dev_mongo_uri.txt`:
     ```text
     mongodb://mongo-db:27017/my_dev_database
     ```
   * `../dev_secrets/dev_admin_password.txt`:
     ```text
     my_secure_dev_password
     ```
2. Run your local dev server:
   ```bash
   docker compose -f docker-compose.dev.yml up --build
   ```

At startup, the local Docker engine will mount both secret files inside `/run/secrets/` in memory. This gives your application 100% environment parity with your production VM, where the VM operator deploys with:
```bash
./appSqueezer.sh create-app <image> --app-parameter "multiplication_factor=5" --app-secret "ADMIN_PASSWORD=my_secure_prod_password"
```
