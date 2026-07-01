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

> [!WARNING]
> For Python applications, ensure you do not run the server using the `uvicorn` command-line utility in your container entrypoint, as Uvicorn's CLI will intercept `--show-spec` and fail with argument errors. Instead, launch Uvicorn programmatically in code (see Step 4) and run the script using `python`.

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
  try {
    if (fs.existsSync(secretPath) && fs.statSync(secretPath).isFile()) {
      return fs.readFileSync(secretPath, 'utf8').trim();
    }
  } catch (err) {
    // Ignore errors and fall back to environment variables
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
    try:
        if os.path.isfile(secret_path):
            with open(secret_path, 'r', encoding='utf-8') as f:
                return f.read().strip()
    except Exception:
        # Ignore errors and fall back to environment variables
        pass
    return os.getenv(env_fallback_name) or os.getenv(secret_name) or ''

# Example usage:
mongo_uri = get_secret_or_env('MONGO_URI', 'MONGO_URI')
# Note: ADMIN_PASSWORD is an example of an app-specific optional secret.
admin_password = get_secret_or_env('ADMIN_PASSWORD', 'ADMIN_PASSWORD')
```

---

### Step 3.5: Parse the Database Name from MONGO_URI Robustly
When connecting to MongoDB, the application must extract the database name from the connection string (with a fallback name like `my_app_db` if not found). To maintain environment parity and avoid issues with custom ports or replica sets, parse this path element robustly.

Avoid brittle regexes (like expecting a digit right before the slash) and use URL parsers or generic regex matches. Here is the proper implementation for common languages:

#### 1. JavaScript / TypeScript (Node.js)
```javascript
let dbName = 'my_app_db';
try {
  const parsed = new URL(mongoUri);
  const pathDb = parsed.pathname.replace(/^\//, '');
  if (pathDb) dbName = pathDb;
} catch (e) {
  const match = mongoUri.match(/\/([a-zA-Z0-9_-]+)(?:\?|$)/);
  if (match) dbName = match[1];
}
```

#### 2. Python
```python
import urllib.parse
import re

try:
    path_db = urllib.parse.urlparse(mongo_uri).path.lstrip('/')
    db_name = path_db if path_db else "my_app_db"
except Exception:
    match = re.search(r'/([a-zA-Z0-9_-]+)(?:\?|$)', mongo_uri)
    db_name = match.group(1) if match else "my_app_db"
```

#### 3. Rust
```rust
// Using the url crate
let db_name = match url::Url::parse(mongo_uri) {
    Ok(url) => url.path().trim_start_matches('/').to_string(),
    Err(_) => "my_app_db".to_string(),
};
```

#### 4. Go
```go
import (
    "net/url"
    "strings"
)

func getDBName(mongoURI string) string {
    u, err := url.Parse(mongoURI)
    if err == nil {
        path := strings.TrimPrefix(u.Path, "/")
        if path != "" {
            return path
        }
    }
    return "my_app_db"
}
```

#### 5. Java / Kotlin
```java
import com.mongodb.ConnectionString;

String dbName = "my_app_db";
try {
    ConnectionString conn = new ConnectionString(mongoUri);
    if (conn.getDatabase() != null) {
        dbName = conn.getDatabase();
    }
} catch (Exception e) {
    // URL parsing fallback
}
```

#### 6. C# / .NET
```csharp
using MongoDB.Driver;

var mongoUrl = new MongoUrl(mongoUri);
var dbName = mongoUrl.DatabaseName ?? "my_app_db";
```

#### 7. PHP
```php
$dbName = ltrim(parse_url($mongoUri, PHP_URL_PATH), '/') ?: 'my_app_db';
```

---

### Step 4: Bind Dynamically to `PORT`
The production edge router (Traefik) is hardcoded to route traffic to port `3000` inside your application container. Therefore, your application **must** bind dynamically to the port specified in the `PORT` environment variable (which the gateway automatically sets to `3000` in production) and default to `3000` during local development.

Update the bootstrap code:
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

### Step 5: Verify Path-Prefix Routing & Asset URLs
Since the reverse proxy hosts the application under a subpath matching the application name (e.g. `https://<domain>/<app-name>`) and strips this prefix before forwarding the request to the container, any absolute links to root assets (e.g., `<script src="/main.js">` or `<a href="/login">`) will fail.

Scan the application codebase and verify that all HTML links, asset references, and API redirects use either:
1. **Relative Paths**: e.g., `<script src="./main.js">` or `<a href="login">`.
2. **App-Prefixed Paths**: e.g., dynamically prefixing paths with the application name prefix (like `/<app-name>/main.js` or `/${APP_NAME}/main.js`).

---

### Step 6: Create docker-compose.dev.yml
Generate a local `docker-compose.dev.yml` file to test the application locally with database container services and local secrets mapped:
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
           target: MONGO_URI
         - source: dev_admin_password
           target: ADMIN_PASSWORD # Example of an app-specific optional secret

     mongo-db:
       image: mongo:7.0
       ports:
         - "27017:27017"

   secrets:
     dev_mongo_uri:
       file: ../dev_secrets/dev_mongo_uri.txt
     dev_admin_password:
       file: ../dev_secrets/dev_admin_password.txt
   ```

> [!IMPORTANT]
> The parameters and secrets shown above (`multiplication_factor`, `ADMIN_PASSWORD`, etc.) are **examples only**. Replace them with the actual parameters and secrets required by the target project, as declared in its `--show-spec` contract output.

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

---

### Step 7: Create the Dockerfile
Generate a standardized `Dockerfile` in the root of the project:
* Ensure it uses lightweight official base images (e.g. `node:20-alpine`, `python:3.11-slim`).
* Expose port `3000`.
* Exec-form `ENTRYPOINT` is preferred rather than `CMD` (so that `podman run --rm <image> --show-spec` appends CLI arguments correctly instead of overriding the startup command). Note that CMD-only configurations are still supported since the orchestrator can inspect and run CMD elements, but direct process execution via exec-form `ENTRYPOINT` provides cleaner signal handling and faster shutdowns.
  * **Correct Node**: `ENTRYPOINT ["node", "index.js"]`
  * **Correct Python**: `ENTRYPOINT ["python", "main.py"]`
  * **Note on Package Manager Wrappers**: If you use a package manager wrapper (like `ENTRYPOINT ["npm", "start"]` or `CMD ["npm", "start"]`), the orchestrator script is designed to automatically detect this and prepend `--` to forward the argument (e.g., `npm start -- --show-spec`).

---

### Step 8: Create GHCR Deployment Script
Generate a deployment script at `scripts/deploy-ghcr.sh` that automates image publishing:
```bash
#!/bin/bash
set -e

# Read package name from package.json or project config
APP_NAME="my-app"
GHCR_USER="your-github-username"

# Make sure you are authenticated to GHCR before running this script:
# echo $CR_PAT | docker login ghcr.io -u $GHCR_USER --password-stdin

# Note: You can replace 'docker' with 'podman' depending on your local machine configuration.
echo "Building production image..."
docker build -t ghcr.io/$GHCR_USER/$APP_NAME:latest .

echo "Pushing image to GitHub Container Registry..."
docker push ghcr.io/$GHCR_USER/$APP_NAME:latest

echo -e "\nDeployment setup ready!"
echo -e "Copy and run this command on your production VM:"
echo -e "  ./appRouter.sh create-app ghcr.io/$GHCR_USER/$APP_NAME:latest"
```
Make the script executable: `chmod +x scripts/deploy-ghcr.sh`.
