# GitHub Packages (GHCR) Container Deployment Guide

This guide details the complete developer lifecycle for developing an application locally on a workstation, packaging it into a container image, pushing it to the GitHub Container Registry (`ghcr.io`), and deploying it seamlessly to your production VM using the `instanceSqueeze.sh` tool.

---

## Step 1: Generate a GitHub Personal Access Token (PAT)

To read or write packages from terminal command lines, you must authenticate using a Personal Access Token instead of your standard GitHub password.

1. Go to your GitHub account settings: **Settings** -> **Developer settings** -> **Personal access tokens** -> **Tokens (classic)**.
2. Click **Generate new token** (choose **Generate new token (classic)**).
3. Provide a clear note (e.g. `vm-deployment-token`) and set an expiration duration.
4. Select the following scopes:
   * **`write:packages`**: Permits uploading container images from your local workstation.
   * **`read:packages`**: Permits downloading container images on your production VM.
5. Click **Generate token** and copy the resulting string immediately (you will not be able to view it again).

---

## Step 2: Authenticate Local Workstation (Docker/Podman)

On your local development machine, open a terminal window and log in to the GitHub Container Registry using the token generated in Step 1:

```bash
echo "YOUR_GITHUB_PAT" | docker login ghcr.io -u YOUR_GITHUB_USERNAME --password-stdin
```

*Note: Replace `YOUR_GITHUB_PAT` with your actual token value, and `YOUR_GITHUB_USERNAME` with your GitHub username.*

---

## Step 3: Build and Tag the Local Container Image

When packaging your application, tag the image using the `ghcr.io` registry namespace prefix so the engine knows where to publish it:

```bash
# Tag structure: ghcr.io/<owner>/<image-name>:<tag>
docker build -t ghcr.io/yourusername/my-service:latest .
```

---

## Step 4: Push the Image to GitHub Container Registry

Upload the built image to GitHub:

```bash
docker push ghcr.io/yourusername/my-service:latest
```

Once completed, the image is securely hosted under the **Packages** tab on your GitHub profile page.

---

## Step 5: Authenticate Production VM (Podman)

SSH into your remote VM and log in to `ghcr.io` under the non-root deployment user context. This enables Podman to pull down your private packages:

```bash
echo "YOUR_GITHUB_PAT" | podman login ghcr.io -u YOUR_GITHUB_USERNAME --password-stdin
```

*Note: This login is stored securely in the user's home configuration files, meaning you only need to run this command once on the VM.*

---

## Step 6: Deploy to Production VM

Now, deploy the application dynamically by passing the container image URL to the setup utility:

```bash
./instanceSqueeze.sh create-app ghcr.io/yourusername/my-service:latest
```

### Automatic Behind-the-Scenes Actions:
1. Podman pulls down the image `ghcr.io/yourusername/my-service:latest`.
2. The script parses the image and creates a persistent home directory at `/opt/my-service`.
3. The script extracts the central MongoDB root credentials, generates a unique application-specific database user, and uses `podman exec` to register them with restricted `readWrite` permissions on `my_service_db`.
4. The connection string is registered with Podman Secrets (`my-service_mongo_uri`) and the generated `/opt/my-service/docker-compose.prod.yml` mounts this secret dynamically at `/run/secrets/MONGO_URI` (along with configuring Traefik labels and `.env.production` metadata).
5. The container pulls the secret from memory and starts up.
