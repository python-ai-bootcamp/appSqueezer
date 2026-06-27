#!/usr/bin/env bash

# Exit immediately if a command exits with a non-zero status
set -e

# Configuration / Output paths
INFRA_DIR="/opt/web-infrastructure"
TEMPLATE_FILE="$(dirname "$0")/templates/docker-compose_infra.yaml.template"

# Text Styling
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Ensure script is NOT run directly as root to preserve user-level Podman environment
if [ "$EUID" -eq 0 ]; then
    log_error "Please do not run this script as root/sudo directly."
    log_error "Run it as a standard user with sudo privileges: ./appRouter.sh install ..."
    exit 1
fi

show_usage() {
    echo "Usage:"
    echo "  $0 install -d <domain> [-e <email>] [-u <mongo-user>] [-p <mongo-password>]"
    echo "  $0 uninstall [-y|--non-interactive]"
    echo "  $0 create-app <image> [--app-parameter \"KEY=VALUE\"]... [--app-secret \"KEY=VALUE\"]... [--cpu <limit>] [--memory <limit>]"
    echo "  $0 list"
    echo "  $0 start <app-name>"
    echo "  $0 stop <app-name>"
    echo "  $0 restart <app-name>"
    echo "  $0 logs <app-name> [compose-options...]"
    echo "  $0 configure <app-name> [--app-parameter \"KEY=VALUE\"]... [--app-secret \"KEY=VALUE\"]... [--cpu <limit>] [--memory <limit>] [--clear-app-parameters] [--clear-app-secrets] [--clear-app-limits]"
    echo "  $0 update <app-name> [--image <new-image-url>]"
    echo "  $0 destroy-app <app-name> [--keep-secrets | --delete-secrets] [--keep-parameters | --delete-parameters] [--keep-data | --delete-data] [--keep-backups | --delete-backups]"
    echo "  $0 backup [--app-name=<name> | --all] [--description=<suffix>]"
    echo "  $0 restore [--app-name=<name> --backup-name=<file> | --all]"
    echo ""
    echo "Options:"
    echo "  -d, --domain              Domain name for routing (Mandatory for install)"
    echo "  -e, --email               Let's Encrypt admin email (Default: admin@example.com)"
    echo "  -u, --mongo-user          MongoDB admin username (Default: admin_user)"
    echo "  -p, --mongo-password      MongoDB admin password (Default: auto-generated)"
    echo "  -y, --non-interactive     Force uninstall without prompting (Automatic cleanup of files)"
    echo "  --app-parameter           Pass environment variables to app (e.g. --app-parameter \"K=V\")"
    echo "  --app-secret              Pass sensitive secrets to app via Podman Secrets (e.g. --app-secret \"K=V\")"
    echo "  --cpu                     CPU limit constraints (e.g. --cpu \"0.5\")"
    echo "  --memory                  Memory limit constraints (e.g. --memory \"512M\")"
    echo "  --clear-app-parameters    For configure: discard existing app parameters"
    echo "  --clear-app-secrets       For configure: discard existing app secrets"
    echo "  --clear-app-limits        For configure: discard existing CPU and memory limits"
    echo "  --image                   For update: change the container image URL"
    echo "  --app-name                Select single application context"
    echo "  --backup-name             Name of database backup file"
    echo "  --description             Optional description suffix for backup file"
    echo "  --all                     Target all deployed applications"
    exit 1
}

# Ensure action is provided
if [ $# -lt 1 ]; then
    show_usage
fi

ACTION=$1
shift

# Defaults
APP_DOMAIN=""
LETSENCRYPT_EMAIL="admin@example.com"
MONGO_ROOT_USER="admin_user"
MONGO_ROOT_PASSWORD=""
NON_INTERACTIVE=false
APP_IMAGE=""
APP_NAME=""
declare -a APP_PARAMS=()
declare -a APP_SECRETS=()
declare -a LOG_ARGS=()
CLEAR_PARAMS=false
CLEAR_SECRETS=false
CLEAR_LIMITS=false
UPDATE_IMAGE=""
APP_CPU=""
APP_MEM=""
DESTROY_SECRETS=""
DESTROY_PARAMS=""
DESTROY_DATA=""
DESTROY_BACKUPS=""
ALL_APPS=false
BACKUP_DESC=""
BACKUP_NAME=""

if [ "$ACTION" = "create-app" ]; then
    if [ $# -lt 1 ]; then
        log_error "Missing image name for create-app."
        show_usage
    fi
    APP_IMAGE="$1"
    shift
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --app-parameter)
                if [ -z "$2" ]; then
                    log_error "Missing value for --app-parameter"
                    show_usage
                fi
                PARAM_KEY="${2%%=*}"
                if [[ "$PARAM_KEY" =~ ^(PORT|NODE_ENV|APP_DOMAIN)$ ]]; then
                    log_error "Parameter '$PARAM_KEY' is a reserved gateway configuration and cannot be overridden."
                    exit 1
                fi
                APP_PARAMS+=("$2")
                shift 2
                ;;
            --app-secret)
                if [ -z "$2" ]; then
                    log_error "Missing value for --app-secret"
                    show_usage
                fi
                APP_SECRETS+=("$2")
                shift 2
                ;;
            --cpu)
                if [ -z "$2" ]; then
                    log_error "Missing value for --cpu"
                    show_usage
                fi
                APP_CPU="$2"
                shift 2
                ;;
            --memory)
                if [ -z "$2" ]; then
                    log_error "Missing value for --memory"
                    show_usage
                fi
                APP_MEM="$2"
                shift 2
                ;;
            *)
                log_error "Unknown argument for create-app: $1"
                show_usage
                ;;
        esac
    done
elif [ "$ACTION" = "configure" ]; then
    if [ $# -lt 1 ]; then
        log_error "Missing app-name for configure."
        show_usage
    fi
    APP_NAME="$1"
    shift
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --app-parameter)
                if [ -z "$2" ]; then
                    log_error "Missing value for --app-parameter"
                    show_usage
                fi
                PARAM_KEY="${2%%=*}"
                if [[ "$PARAM_KEY" =~ ^(PORT|NODE_ENV|APP_DOMAIN)$ ]]; then
                    log_error "Parameter '$PARAM_KEY' is a reserved gateway configuration and cannot be overridden."
                    exit 1
                fi
                APP_PARAMS+=("$2")
                shift 2
                ;;
            --app-secret)
                if [ -z "$2" ]; then
                    log_error "Missing value for --app-secret"
                    show_usage
                fi
                APP_SECRETS+=("$2")
                shift 2
                ;;
            --cpu)
                if [ -z "$2" ]; then
                    log_error "Missing value for --cpu"
                    show_usage
                fi
                APP_CPU="$2"
                shift 2
                ;;
            --memory)
                if [ -z "$2" ]; then
                    log_error "Missing value for --memory"
                    show_usage
                fi
                APP_MEM="$2"
                shift 2
                ;;
            --clear-app-parameters)
                CLEAR_PARAMS=true
                shift
                ;;
            --clear-app-secrets)
                CLEAR_SECRETS=true
                shift
                ;;
            --clear-app-limits)
                CLEAR_LIMITS=true
                shift
                ;;
            *)
                log_error "Unknown argument for configure: $1"
                show_usage
                ;;
        esac
    done
elif [ "$ACTION" = "update" ]; then
    if [ $# -lt 1 ]; then
        log_error "Missing app-name for update."
        show_usage
    fi
    APP_NAME="$1"
    shift
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --image)
                if [ -z "$2" ]; then
                    log_error "Missing value for --image"
                    show_usage
                fi
                UPDATE_IMAGE="$2"
                shift 2
                ;;
            *)
                log_error "Unknown argument for update: $1"
                show_usage
                ;;
        esac
    done
elif [ "$ACTION" = "destroy-app" ]; then
    if [ $# -lt 1 ]; then
        log_error "Missing app-name for destroy-app."
        show_usage
    fi
    APP_NAME="$1"
    shift
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --keep-secrets)
                DESTROY_SECRETS="keep"
                shift
                ;;
            --delete-secrets)
                DESTROY_SECRETS="delete"
                shift
                ;;
            --keep-parameters)
                DESTROY_PARAMS="keep"
                shift
                ;;
            --delete-parameters)
                DESTROY_PARAMS="delete"
                shift
                ;;
            --keep-data)
                DESTROY_DATA="keep"
                shift
                ;;
            --delete-data)
                DESTROY_DATA="delete"
                shift
                ;;
            --keep-backups)
                DESTROY_BACKUPS="keep"
                shift
                ;;
            --delete-backups)
                DESTROY_BACKUPS="delete"
                shift
                ;;
            *)
                log_error "Unknown argument for destroy-app: $1"
                show_usage
                ;;
        esac
    done
    
    # Enforce mandatory choices
    if [ -z "$DESTROY_SECRETS" ] || [ -z "$DESTROY_PARAMS" ] || [ -z "$DESTROY_DATA" ] || [ -z "$DESTROY_BACKUPS" ]; then
        log_error "Missing mandatory choices for destroy-app."
        log_error "You must specify cleanup decisions for all groups:"
        log_error "  - Secrets: --keep-secrets or --delete-secrets"
        log_error "  - Parameters: --keep-parameters or --delete-parameters"
        log_error "  - Data: --keep-data or --delete-data"
        log_error "  - Backups: --keep-backups or --delete-backups"
        exit 1
    fi
elif [ "$ACTION" = "backup" ] || [ "$ACTION" = "restore" ]; then
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --app-name=*)
                APP_NAME="${1#*=}"
                shift
                ;;
            --app-name)
                if [ -z "$2" ]; then
                    log_error "Missing value for --app-name"
                    show_usage
                fi
                APP_NAME="$2"
                shift 2
                ;;
            --description=*)
                BACKUP_DESC="${1#*=}"
                shift
                ;;
            --description)
                if [ -z "$2" ]; then
                    log_error "Missing value for --description"
                    show_usage
                fi
                BACKUP_DESC="$2"
                shift 2
                ;;
            --backup-name=*)
                BACKUP_NAME="${1#*=}"
                shift
                ;;
            --backup-name)
                if [ -z "$2" ]; then
                    log_error "Missing value for --backup-name"
                    show_usage
                fi
                BACKUP_NAME="$2"
                shift 2
                ;;
            --all)
                ALL_APPS=true
                shift
                ;;
            *)
                log_error "Unknown argument for $ACTION: $1"
                show_usage
                ;;
        esac
    done

    # Validation
    if [ "$ALL_APPS" = true ] && [ -n "$APP_NAME" ]; then
        log_error "Cannot specify both --all and --app-name."
        exit 1
    fi
    if [ "$ALL_APPS" = false ] && [ -z "$APP_NAME" ]; then
        log_error "Must specify either --all or --app-name=<name>."
        exit 1
    fi
    if [ "$ACTION" = "restore" ] && [ "$ALL_APPS" = false ] && [ -z "$BACKUP_NAME" ]; then
        log_error "Must specify --backup-name=<file> when restoring a single application."
        exit 1
    fi
elif [ "$ACTION" = "start" ] || [ "$ACTION" = "stop" ] || [ "$ACTION" = "restart" ]; then
    if [ $# -lt 1 ]; then
        log_error "Missing app-name for $ACTION."
        show_usage
    fi
    APP_NAME="$1"
    shift
    if [ $# -gt 0 ]; then
        log_error "Too many arguments for $ACTION: $@"
        show_usage
    fi
elif [ "$ACTION" = "logs" ]; then
    if [ $# -lt 1 ]; then
        log_error "Missing app-name for logs."
        show_usage
    fi
    APP_NAME="$1"
    shift
    LOG_ARGS=("$@")
elif [ "$ACTION" = "list" ]; then
    if [ $# -gt 0 ]; then
        log_error "Too many arguments for list: $@"
        show_usage
    fi
else
    # Parse named parameters for install/uninstall
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -d|--domain)
                APP_DOMAIN="$2"
                shift 2
                ;;
            -e|--email)
                LETSENCRYPT_EMAIL="$2"
                shift 2
                ;;
            -u|--mongo-user)
                MONGO_ROOT_USER="$2"
                shift 2
                ;;
            -p|--mongo-password)
                MONGO_ROOT_PASSWORD="$2"
                shift 2
                ;;
            -y|--non-interactive)
                NON_INTERACTIVE=true
                shift
                ;;
            *)
                log_error "Unknown argument: $1"
                show_usage
                ;;
        esac
    done
fi

do_install() {
    # Check mandatory parameter
    if [ -z "$APP_DOMAIN" ]; then
        log_error "Missing required parameter: -d/--domain is mandatory for install."
        show_usage
    fi

    # Handle auto-password generation if not provided
    if [ -z "$MONGO_ROOT_PASSWORD" ]; then
        MONGO_ROOT_PASSWORD=$(openssl rand -hex 16 2>/dev/null || gpg --gen-random --armor 1 16 2>/dev/null || dd if=/dev/urandom bs=1 count=16 2>/dev/null | od -An -vtx1 | tr -d ' \n' || echo "SecurePass$(date +%s%N)")
        log_info "Auto-generated secure MongoDB root password."
    fi

    log_info "Configuration parameters to be applied:"
    echo -e "  Domain:         ${YELLOW}${APP_DOMAIN}${NC}"
    echo -e "  Let's Encrypt:  ${YELLOW}${LETSENCRYPT_EMAIL}${NC}"
    echo -e "  Mongo User:     ${YELLOW}${MONGO_ROOT_USER}${NC}"
    echo -e "  Mongo Password: ${YELLOW}[hidden]${NC}"
    echo ""

    log_info "1. Installing OS dependencies..."
    sudo apt update
    sudo apt install -y git podman podman-compose gnupg pass jq

    log_info "2. Enabling and starting Podman user socket and restart service..."
    # Enable lingering to allow user services to run when not logged in
    sudo loginctl enable-linger "$(whoami)"
    systemctl --user daemon-reload
    systemctl --user enable --now podman.socket
    systemctl --user enable --now podman-restart.service

    # Verify socket status
    SOCKET_PATH="/run/user/$(id -u)/podman/podman.sock"
    if [ ! -S "$SOCKET_PATH" ]; then
        log_warn "Podman socket not found at expected path: $SOCKET_PATH"
        log_warn "Traefik might fail to dynamically discover containers until the socket is active."
    else
        log_success "Podman user socket is running at $SOCKET_PATH"
    fi

    log_info "3. Creating directory structure at $INFRA_DIR..."
    sudo mkdir -p "$INFRA_DIR/letsencrypt"
    # Change ownership to current user so compose/podman runs rootless
    sudo chown -R "$(id -u):$(id -g)" "$INFRA_DIR"

    # Create acme.json with strict permissions
    touch "$INFRA_DIR/letsencrypt/acme.json"
    chmod 600 "$INFRA_DIR/letsencrypt/acme.json"

    log_info "4. Configuring docker-compose and environment..."
    if [ ! -f "$TEMPLATE_FILE" ]; then
        log_error "Template file not found at $TEMPLATE_FILE. Cannot proceed."
        exit 1
    fi
    cp "$TEMPLATE_FILE" "$INFRA_DIR/docker-compose.yml"

    # Write .env file
    ENV_FILE="$INFRA_DIR/.env"
    cat <<EOF > "$ENV_FILE"
APP_DOMAIN=${APP_DOMAIN}
LETSENCRYPT_EMAIL=${LETSENCRYPT_EMAIL}
USER_UID=$(id -u)
MONGO_ROOT_USER=${MONGO_ROOT_USER}
MONGO_ROOT_PASSWORD=${MONGO_ROOT_PASSWORD}
EOF
    chmod 600 "$ENV_FILE"

    log_info "5. Ensuring shared network 'web_gateway' exists..."
    if ! podman network inspect web_gateway >/dev/null 2>&1; then
        podman network create web_gateway
        log_success "Created network: web_gateway"
    else
        log_info "Network 'web_gateway' already exists."
    fi

    log_info "6. Starting Infrastructure Services via podman-compose..."
    cd "$INFRA_DIR"
    podman-compose up -d

    log_success "Installation completed successfully!"
    log_success "Traefik and MongoDB are running rootless."
    echo -e "${YELLOW}MongoDB Root Credentials saved in $ENV_FILE${NC}"
}

do_uninstall() {
    if [ "$NON_INTERACTIVE" = false ]; then
        log_warn "This will stop services and delete configurations."
        read -r -p "Are you sure you want to uninstall? [y/N]: " CONFIRM
        if [[ ! "$CONFIRM" =~ ^[yY](es)?$ ]]; then
            log_info "Uninstall aborted."
            exit 0
        fi
    fi

    log_info "1. Stopping services..."
    if [ -f "$INFRA_DIR/docker-compose.yml" ]; then
        cd "$INFRA_DIR"
        podman-compose down || true
    else
        log_warn "docker-compose.yml not found at $INFRA_DIR, skipping service teardown."
    fi

    log_info "2. Removing network 'web_gateway'..."
    if podman network inspect web_gateway >/dev/null 2>&1; then
        podman network rm web_gateway || true
    fi

    log_info "3. Disabling Podman user socket and restart services..."
    systemctl --user disable --now podman.socket || true
    systemctl --user disable --now podman-restart.service || true

    log_info "4. Cleaning up files..."
    CLEAN_ALL=true
    if [ "$NON_INTERACTIVE" = false ]; then
        read -r -p "Do you want to delete all configuration, SSL certs, and MongoDB databases at $INFRA_DIR? [y/N]: " CLEAN_PROMPT
        if [[ ! "$CLEAN_PROMPT" =~ ^[yY](es)?$ ]]; then
            CLEAN_ALL=false
        fi
    fi

    if [ "$CLEAN_ALL" = true ]; then
        sudo rm -rf "$INFRA_DIR"
        log_success "Successfully removed all files at $INFRA_DIR"
    else
        log_info "Preserved configuration files at $INFRA_DIR"
    fi

    log_success "Uninstall process completed."
}

do_create_app() {
    IMAGE="$1"
    if [ -z "$IMAGE" ]; then
        log_error "Image name is required for create-app."
        exit 1
    fi

    # Extract base image name
    IMAGE_BASE="${IMAGE##*/}"
    APP_NAME="${IMAGE_BASE%%:*}"
    APP_NAME=$(echo "$APP_NAME" | tr '.' '-')
    # Ensure database name uses underscores instead of hyphens/periods
    DB_NAME=$(echo "$APP_NAME" | tr '-' '_' | tr '.' '_')_db
    
    APP_DIR="/opt/$APP_NAME"
    ENV_FILE="$INFRA_DIR/.env"
    
    # Read database credentials from central .env
    if [ ! -f "$ENV_FILE" ]; then
        log_error "Central infrastructure is not installed or .env is missing. Run install first."
        exit 1
    fi
    
    # Extract root mongo credentials and APP_DOMAIN
    set +e
    MONGO_ROOT_USER=$(grep "^MONGO_ROOT_USER=" "$ENV_FILE" | cut -d= -f2 | tr -d '\r')
    MONGO_ROOT_PASSWORD=$(grep "^MONGO_ROOT_PASSWORD=" "$ENV_FILE" | cut -d= -f2 | tr -d '\r')
    APP_DOMAIN=$(grep "^APP_DOMAIN=" "$ENV_FILE" | cut -d= -f2 | tr -d '\r')
    set -e
    
    if [ -z "$MONGO_ROOT_USER" ] || [ -z "$MONGO_ROOT_PASSWORD" ]; then
        log_error "Failed to retrieve MongoDB root credentials from $ENV_FILE."
        exit 1
    fi
    if [ -z "$APP_DOMAIN" ]; then
        log_error "Failed to retrieve APP_DOMAIN from $ENV_FILE."
        exit 1
    fi

    # --- Pre-Flight Contract Verification ---
    log_info "1. Pulling container image to inspect contract: ${IMAGE}..."
    podman pull "$IMAGE" >/dev/null

    log_info "2. Inspecting application contract via --show-spec..."
    ENTRYPOINT_JSON=$(podman image inspect "$IMAGE" --format '{{json .Config.Entrypoint}}' 2>/dev/null || echo "null")
    IS_WRAPPER=$(echo "$ENTRYPOINT_JSON" | jq -e 'type == "array" and (.[0] | sub(".*/"; "") | in({"npm":1, "yarn":1, "pnpm":1, "bun":1}))' >/dev/null 2>&1 && echo "true" || echo "false")
    SPEC_ERR_FILE=$(mktemp)
    if [ "$IS_WRAPPER" = "true" ]; then
        log_info "Package manager entrypoint wrapper detected. Injecting '--' before contract flags."
        SPEC_OUTPUT=$(podman run --rm "$IMAGE" -- --show-spec 2>"$SPEC_ERR_FILE" || true)
    else
        SPEC_OUTPUT=$(podman run --rm "$IMAGE" --show-spec 2>"$SPEC_ERR_FILE" || true)
    fi
    
    if ! echo "$SPEC_OUTPUT" | grep -q "^REQUIRED_PARAMETERS="; then
        log_error "Application contract validation failed: Image does not support --show-spec or is invalid."
        if [ -s "$SPEC_ERR_FILE" ]; then
            log_error "Container error output:"
            cat "$SPEC_ERR_FILE" >&2
        fi
        rm -f "$SPEC_ERR_FILE"
        exit 1
    fi
    rm -f "$SPEC_ERR_FILE"

    REQ_PARAMS_STR=$(echo "$SPEC_OUTPUT" | grep "^REQUIRED_PARAMETERS=" | cut -d= -f2 | tr -d '\r' | tr -d '[:space:]')
    REQ_SECRETS_STR=$(echo "$SPEC_OUTPUT" | grep "^REQUIRED_SECRETS=" | cut -d= -f2 | tr -d '\r' | tr -d '[:space:]')

    # Validate required parameters
    IFS=',' read -ra REQ_PARAMS <<< "$REQ_PARAMS_STR"
    MISSING_PARAMS=()
    for req in "${REQ_PARAMS[@]}"; do
        [ -z "$req" ] && continue
        FOUND=false
        for param in "${APP_PARAMS[@]}"; do
            KEY="${param%%=*}"
            if [ "$KEY" = "$req" ]; then
                FOUND=true
                break
            fi
        done
        if [ "$FOUND" = false ]; then
            MISSING_PARAMS+=("$req")
        fi
    done

    # Validate required secrets
    IFS=',' read -ra REQ_SECRETS <<< "$REQ_SECRETS_STR"
    MISSING_SECRETS=()
    for req in "${REQ_SECRETS[@]}"; do
        [ -z "$req" ] && continue
        FOUND=false
        for secret in "${APP_SECRETS[@]}"; do
            KEY="${secret%%=*}"
            if [ "$KEY" = "$req" ]; then
                FOUND=true
                break
            fi
        done
        if [ "$FOUND" = false ]; then
            MISSING_SECRETS+=("$req")
        fi
    done

    # Fail fast if requirements are missing
    if [ ${#MISSING_PARAMS[@]} -gt 0 ] || [ ${#MISSING_SECRETS[@]} -gt 0 ]; then
        log_error "Pre-flight contract verification failed! Missing mandatory configurations."
        if [ ${#MISSING_PARAMS[@]} -gt 0 ]; then
            echo -e "${RED}Missing required parameters (pass via --app-parameter):${NC}"
            for m in "${MISSING_PARAMS[@]}"; do
                echo -e "  - $m"
            done
        fi
        if [ ${#MISSING_SECRETS[@]} -gt 0 ]; then
            echo -e "${RED}Missing required secrets (pass via --app-secret):${NC}"
            for s in "${MISSING_SECRETS[@]}"; do
                echo -e "  - $s"
            done
        fi
        exit 1
    fi
    log_success "Pre-flight contract verification passed."

    log_info "Creating application workspace..."
    echo -e "  App Name:   ${YELLOW}${APP_NAME}${NC}"
    echo -e "  Image:      ${YELLOW}${IMAGE}${NC}"
    echo -e "  Prefix:     ${YELLOW}/${APP_NAME}${NC}"
    echo -e "  DB Name:    ${YELLOW}${DB_NAME}${NC}"
    echo -e "  Directory:  ${YELLOW}${APP_DIR}${NC}"
    echo -e "  Domain:     ${YELLOW}${APP_DOMAIN}${NC}"
    echo ""

    # Generate unique scoped DB credentials
    APP_DB_USER="user_$(echo "$APP_NAME" | tr '-' '_' | tr '.' '_')"
    APP_DB_PASSWORD=$(openssl rand -hex 16 2>/dev/null || gpg --gen-random --armor 1 16 2>/dev/null || dd if=/dev/urandom bs=1 count=16 2>/dev/null | od -An -vtx1 | tr -d ' \n' || echo "AppPass$(date +%s%N)")
    SCOPED_MONGO_URI="mongodb://${APP_DB_USER}:${APP_DB_PASSWORD}@shared_production_mongodb:27017/${DB_NAME}?authSource=admin"

    # Create user in MongoDB
    if ! podman ps --format "{{.Names}}" | grep -q "^shared_production_mongodb$"; then
        log_error "MongoDB container 'shared_production_mongodb' is not running. Start infrastructure first."
        exit 1
    fi

    log_info "Provisioning isolated database user '${APP_DB_USER}'..."
    podman exec -i shared_production_mongodb mongosh \
        -u "$MONGO_ROOT_USER" \
        -p "$MONGO_ROOT_PASSWORD" \
        --authenticationDatabase admin \
        --eval "
            db = db.getSiblingDB('${DB_NAME}');
            if (!db.getUser('${APP_DB_USER}')) {
                db.createUser({
                    user: '${APP_DB_USER}',
                    pwd: '${APP_DB_PASSWORD}',
                    roles: [{ role: 'readWrite', db: '${DB_NAME}' }]
                });
            } else {
                db.changeUserPassword('${APP_DB_USER}', '${APP_DB_PASSWORD}');
            }
        " >/dev/null

    log_info "Storing database connection string as a Podman Secret..."
    podman secret rm "${APP_NAME}_mongo_uri" >/dev/null 2>&1 || true
    echo -n "$SCOPED_MONGO_URI" | podman secret create "${APP_NAME}_mongo_uri" -

    # Register application secrets
    if [ ${#APP_SECRETS[@]} -gt 0 ]; then
        log_info "Registering application secrets with Podman..."
        for secret in "${APP_SECRETS[@]}"; do
            KEY="${secret%%=*}"
            VAL="${secret#*=}"
            SECRET_NAME="${APP_NAME}_secret_${KEY}"
            
            podman secret rm "$SECRET_NAME" >/dev/null 2>&1 || true
            echo -n "$VAL" | podman secret create "$SECRET_NAME" -
        done
    fi

    # Create directory and assign permissions to current user
    sudo mkdir -p "$APP_DIR"
    sudo chown -R "$(id -u):$(id -g)" "$APP_DIR"

    # Write .env.production
    cat <<EOF > "$APP_DIR/.env.production"
PORT=3000
NODE_ENV=production
APP_DOMAIN=${APP_DOMAIN}
EOF

    if [ -n "$APP_CPU" ]; then
        echo "APP_CPUS=${APP_CPU}" >> "$APP_DIR/.env.production"
    fi
    if [ -n "$APP_MEM" ]; then
        echo "APP_MEM_LIMIT=${APP_MEM}" >> "$APP_DIR/.env.production"
    fi

    # Write any app-specific parameters
    if [ ${#APP_PARAMS[@]} -gt 0 ]; then
        echo "" >> "$APP_DIR/.env.production"
        echo "# App-specific parameters" >> "$APP_DIR/.env.production"
        for param in "${APP_PARAMS[@]}"; do
            echo "$param" >> "$APP_DIR/.env.production"
        done
    fi
    chmod 600 "$APP_DIR/.env.production"

    # Generate docker-compose secrets sections dynamically
    SERVICES_SECRETS_SECTION="    secrets:\n      - source: ${APP_NAME}_mongo_uri\n        target: MONGO_URI"
    GLOBAL_SECRETS_SECTION="secrets:\n  ${APP_NAME}_mongo_uri:\n    external: true"

    if [ ${#APP_SECRETS[@]} -gt 0 ]; then
        for secret in "${APP_SECRETS[@]}"; do
            KEY="${secret%%=*}"
            SERVICES_SECRETS_SECTION="${SERVICES_SECRETS_SECTION}\n      - source: ${APP_NAME}_secret_${KEY}\n        target: ${KEY}"
            GLOBAL_SECRETS_SECTION="${GLOBAL_SECRETS_SECTION}\n  ${APP_NAME}_secret_${KEY}:\n    external: true"
        done
    fi

    # Write docker-compose.prod.yml
    COMPOSE_FILE="$APP_DIR/docker-compose.prod.yml"
    cat <<EOF > "$COMPOSE_FILE"
version: "3.8"

services:
  backend-${APP_NAME}:
    image: ${IMAGE}
    container_name: app_${APP_NAME}_backend
    restart: unless-stopped
    env_file:
      - .env.production
    networks:
      - web_gateway
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
EOF

    if [ -n "$APP_CPU" ]; then
        echo "    cpus: \"${APP_CPU}\"" >> "$COMPOSE_FILE"
    fi
    if [ -n "$APP_MEM" ]; then
        echo "    mem_limit: \"${APP_MEM}\"" >> "$COMPOSE_FILE"
    fi

    # Append mounted secrets
    echo -e "$SERVICES_SECRETS_SECTION" >> "$COMPOSE_FILE"

    # Append Traefik routing labels
    cat <<EOF >> "$COMPOSE_FILE"
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.${APP_NAME}.rule=PathPrefix(\`/${APP_NAME}\`)"
      - "traefik.http.routers.${APP_NAME}.entrypoints=websecure"
      - "traefik.http.routers.${APP_NAME}.tls=true"
      - "traefik.http.middlewares.${APP_NAME}-strip.stripprefix.prefixes=/${APP_NAME}"
      - "traefik.http.routers.${APP_NAME}.middlewares=${APP_NAME}-strip"
      - "traefik.http.services.${APP_NAME}.loadbalancer.server.port=3000"

EOF

    # Append global secrets definition
    echo -e "$GLOBAL_SECRETS_SECTION" >> "$COMPOSE_FILE"

    # Append networks
    cat <<EOF >> "$COMPOSE_FILE"

networks:
  web_gateway:
    external: true
EOF

    log_info "Starting application container..."
    cd "$APP_DIR"
    podman-compose -f docker-compose.prod.yml up -d

    log_success "Application deployed successfully!"
    log_success "Reachable at: https://${APP_DOMAIN}/${APP_NAME}"
}

do_list() {
    log_info "Scanning for deployed applications under /opt/..."
    
    printf "\n%-20s %-50s %-20s\n" "Application" "Route URL" "Container Status"
    printf "%-20s %-50s %-20s\n" "-----------" "---------" "----------------"

    for dir in /opt/*; do
        [ -d "$dir" ] || continue
        APP_DIR_NAME=$(basename "$dir")
        [ "$APP_DIR_NAME" = "web-infrastructure" ] && continue
        
        COMPOSE_PATH="$dir/docker-compose.prod.yml"
        if [ -f "$COMPOSE_PATH" ]; then
            ENV_PATH="$dir/.env.production"
            DOMAIN="unknown-domain"
            if [ -f "$ENV_PATH" ]; then
                DOMAIN=$(grep "^APP_DOMAIN=" "$ENV_PATH" | cut -d= -f2 | tr -d '\r')
            fi
            
            ROUTE_URL="https://${DOMAIN}/${APP_DIR_NAME}"
            CONTAINER_NAME="app_${APP_DIR_NAME}_backend"
            STATUS=$(podman ps -a --filter "name=${CONTAINER_NAME}" --format "{{.Status}}" 2>/dev/null)
            
            if [ -z "$STATUS" ]; then
                STATUS="Not Found / Stopped"
            fi
            
            printf "%-20s %-50s %-20s\n" "$APP_DIR_NAME" "$ROUTE_URL" "$STATUS"
        fi
    done
    echo ""
}

do_start() {
    APP_NAME=$(echo "$1" | tr '.' '-')
    APP_DIR="/opt/$APP_NAME"
    if [ ! -d "$APP_DIR" ] || [ ! -f "$APP_DIR/docker-compose.prod.yml" ]; then
        log_error "Application '$APP_NAME' is not deployed or missing docker-compose.prod.yml."
        exit 1
    fi
    log_info "Starting application '$APP_NAME'..."
    cd "$APP_DIR"
    podman-compose -f docker-compose.prod.yml up -d
    log_success "Application '$APP_NAME' started."
}

do_stop() {
    APP_NAME=$(echo "$1" | tr '.' '-')
    APP_DIR="/opt/$APP_NAME"
    if [ ! -d "$APP_DIR" ] || [ ! -f "$APP_DIR/docker-compose.prod.yml" ]; then
        log_error "Application '$APP_NAME' is not deployed or missing docker-compose.prod.yml."
        exit 1
    fi
    log_info "Stopping application '$APP_NAME'..."
    cd "$APP_DIR"
    podman-compose -f docker-compose.prod.yml down
    log_success "Application '$APP_NAME' stopped."
}

do_restart() {
    APP_NAME=$(echo "$1" | tr '.' '-')
    APP_DIR="/opt/$APP_NAME"
    if [ ! -d "$APP_DIR" ] || [ ! -f "$APP_DIR/docker-compose.prod.yml" ]; then
        log_error "Application '$APP_NAME' is not deployed or missing docker-compose.prod.yml."
        exit 1
    fi
    log_info "Restarting application '$APP_NAME'..."
    cd "$APP_DIR"
    podman-compose -f docker-compose.prod.yml restart
    log_success "Application '$APP_NAME' restarted."
}

do_logs() {
    APP_NAME=$(echo "$1" | tr '.' '-')
    shift
    APP_DIR="/opt/$APP_NAME"
    if [ ! -d "$APP_DIR" ] || [ ! -f "$APP_DIR/docker-compose.prod.yml" ]; then
        log_error "Application '$APP_NAME' is not deployed or missing docker-compose.prod.yml."
        exit 1
    fi
    cd "$APP_DIR"
    podman-compose -f docker-compose.prod.yml logs "$@"
}

do_configure() {
    APP_NAME=$(echo "$1" | tr '.' '-')
    APP_DIR="/opt/$APP_NAME"
    ENV_FILE="$INFRA_DIR/.env"
    
    if [ ! -d "$APP_DIR" ] || [ ! -f "$APP_DIR/docker-compose.prod.yml" ]; then
        log_error "Application '$APP_NAME' is not deployed or missing docker-compose.prod.yml."
        exit 1
    fi

    # Read database credentials and domain from central .env
    if [ ! -f "$ENV_FILE" ]; then
        log_error "Central infrastructure is not installed or .env is missing. Run install first."
        exit 1
    fi
    set +e
    APP_DOMAIN=$(grep "^APP_DOMAIN=" "$ENV_FILE" | cut -d= -f2 | tr -d '\r')
    set -e
    if [ -z "$APP_DOMAIN" ]; then
        log_error "Failed to retrieve APP_DOMAIN from $ENV_FILE."
        exit 1
    fi

    IMAGE=$(grep "image:" "$APP_DIR/docker-compose.prod.yml" | head -n 1 | awk '{print $2}')
    if [ -z "$IMAGE" ]; then
        log_error "Could not resolve image for application '$APP_NAME' from existing compose file."
        exit 1
    fi

    # Merge/Clear Parameters & Limits
    declare -A MERGED_PARAMS
    ACTIVE_CPUS=""
    ACTIVE_MEM=""

    if [ "$CLEAR_PARAMS" = false ] && [ -f "$APP_DIR/.env.production" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            line=$(echo "$line" | tr -d '\r')
            [[ "$line" =~ ^[[:space:]]*# ]] && continue
            [[ "$line" =~ ^[[:space:]]*$ ]] && continue
            if [[ "$line" != *=* ]]; then continue; fi
            
            KEY="${line%%=*}"
            VAL="${line#*=}"
            if [ "$KEY" != "PORT" ] && [ "$KEY" != "NODE_ENV" ] && [ "$KEY" != "APP_DOMAIN" ] && [ "$KEY" != "APP_CPUS" ] && [ "$KEY" != "APP_MEM_LIMIT" ]; then
                MERGED_PARAMS["$KEY"]="$VAL"
            fi
        done < "$APP_DIR/.env.production"
    fi

    if [ "$CLEAR_LIMITS" = false ] && [ -f "$APP_DIR/.env.production" ]; then
        set +e
        ENV_CPUS=$(grep "^APP_CPUS=" "$APP_DIR/.env.production" | cut -d= -f2)
        ENV_MEM=$(grep "^APP_MEM_LIMIT=" "$APP_DIR/.env.production" | cut -d= -f2)
        set -e
        if [ -n "$ENV_CPUS" ]; then ACTIVE_CPUS="$ENV_CPUS"; fi
        if [ -n "$ENV_MEM" ]; then ACTIVE_MEM="$ENV_MEM"; fi
    fi

    for param in "${APP_PARAMS[@]}"; do
        KEY="${param%%=*}"
        VAL="${param#*=}"
        MERGED_PARAMS["$KEY"]="$VAL"
    done

    if [ -n "$APP_CPU" ]; then
        ACTIVE_CPUS="$APP_CPU"
    fi
    if [ -n "$APP_MEM" ]; then
        ACTIVE_MEM="$APP_MEM"
    fi

    # Merge/Clear Secrets
    declare -A MAPPED_SECRETS
    if [ "$CLEAR_SECRETS" = false ] && [ -f "$APP_DIR/docker-compose.prod.yml" ]; then
        for s_source in $(grep -o "${APP_NAME}_secret_[A-Za-z0-9_]*" "$APP_DIR/docker-compose.prod.yml" 2>/dev/null | sort -u || true); do
            KEY="${s_source#${APP_NAME}_secret_}"
            MAPPED_SECRETS["$KEY"]="$s_source"
        done
    fi

    if [ "$CLEAR_SECRETS" = true ]; then
        log_info "Clearing existing registered secrets for application '$APP_NAME' from Podman..."
        for s in $(podman secret ls --format "{{.Name}}" 2>/dev/null | grep "^${APP_NAME}_secret_"); do
            podman secret rm "$s" >/dev/null 2>&1 || true
        done
    fi

    for secret in "${APP_SECRETS[@]}"; do
        KEY="${secret%%=*}"
        VAL="${secret#*=}"
        SECRET_NAME="${APP_NAME}_secret_${KEY}"
        
        log_info "Registering secret '$KEY' in Podman..."
        podman secret rm "$SECRET_NAME" >/dev/null 2>&1 || true
        echo -n "$VAL" | podman secret create "$SECRET_NAME" -
        MAPPED_SECRETS["$KEY"]="$SECRET_NAME"
    done

    # Pre-Flight Contract Verification
    log_info "Inspecting application contract via --show-spec..."
    ENTRYPOINT_JSON=$(podman image inspect "$IMAGE" --format '{{json .Config.Entrypoint}}' 2>/dev/null || echo "null")
    IS_WRAPPER=$(echo "$ENTRYPOINT_JSON" | jq -e 'type == "array" and (.[0] | sub(".*/"; "") | in({"npm":1, "yarn":1, "pnpm":1, "bun":1}))' >/dev/null 2>&1 && echo "true" || echo "false")
    SPEC_ERR_FILE=$(mktemp)
    if [ "$IS_WRAPPER" = "true" ]; then
        log_info "Package manager entrypoint wrapper detected. Injecting '--' before contract flags."
        SPEC_OUTPUT=$(podman run --rm "$IMAGE" -- --show-spec 2>"$SPEC_ERR_FILE" || true)
    else
        SPEC_OUTPUT=$(podman run --rm "$IMAGE" --show-spec 2>"$SPEC_ERR_FILE" || true)
    fi
    
    if ! echo "$SPEC_OUTPUT" | grep -q "^REQUIRED_PARAMETERS="; then
        log_error "Application contract validation failed: Image does not support --show-spec or is invalid."
        if [ -s "$SPEC_ERR_FILE" ]; then
            log_error "Container error output:"
            cat "$SPEC_ERR_FILE" >&2
        fi
        rm -f "$SPEC_ERR_FILE"
        exit 1
    fi
    rm -f "$SPEC_ERR_FILE"

    REQ_PARAMS_STR=$(echo "$SPEC_OUTPUT" | grep "^REQUIRED_PARAMETERS=" | cut -d= -f2 | tr -d '\r' | tr -d '[:space:]')
    REQ_SECRETS_STR=$(echo "$SPEC_OUTPUT" | grep "^REQUIRED_SECRETS=" | cut -d= -f2 | tr -d '\r' | tr -d '[:space:]')

    # Validate parameters
    IFS=',' read -ra REQ_PARAMS <<< "$REQ_PARAMS_STR"
    MISSING_PARAMS=()
    for req in "${REQ_PARAMS[@]}"; do
        [ -z "$req" ] && continue
        if [ -z "${MERGED_PARAMS[$req]}" ]; then
            MISSING_PARAMS+=("$req")
        fi
    done

    # Validate secrets
    IFS=',' read -ra REQ_SECRETS <<< "$REQ_SECRETS_STR"
    MISSING_SECRETS=()
    for req in "${REQ_SECRETS[@]}"; do
        [ -z "$req" ] && continue
        if [ -z "${MAPPED_SECRETS[$req]}" ]; then
            MISSING_SECRETS+=("$req")
        fi
    done

    # Fail fast if requirements are missing
    if [ ${#MISSING_PARAMS[@]} -gt 0 ] || [ ${#MISSING_SECRETS[@]} -gt 0 ]; then
        log_error "Pre-flight contract verification failed! Missing mandatory configurations."
        if [ ${#MISSING_PARAMS[@]} -gt 0 ]; then
            echo -e "${RED}Missing required parameters (pass via --app-parameter):${NC}"
            for m in "${MISSING_PARAMS[@]}"; do
                echo -e "  - $m"
            done
        fi
        if [ ${#MISSING_SECRETS[@]} -gt 0 ]; then
            echo -e "${RED}Missing required secrets (pass via --app-secret):${NC}"
            for s in "${MISSING_SECRETS[@]}"; do
                echo -e "  - $s"
            done
        fi
        exit 1
    fi
    log_success "Pre-flight contract verification passed."

    # Write .env.production
    cat <<EOF > "$APP_DIR/.env.production"
PORT=3000
NODE_ENV=production
APP_DOMAIN=${APP_DOMAIN}
EOF

    if [ -n "$ACTIVE_CPUS" ]; then
        echo "APP_CPUS=${ACTIVE_CPUS}" >> "$APP_DIR/.env.production"
    fi
    if [ -n "$ACTIVE_MEM" ]; then
        echo "APP_MEM_LIMIT=${ACTIVE_MEM}" >> "$APP_DIR/.env.production"
    fi

    if [ ${#MERGED_PARAMS[@]} -gt 0 ]; then
        echo "" >> "$APP_DIR/.env.production"
        echo "# App-specific parameters" >> "$APP_DIR/.env.production"
        for key in "${!MERGED_PARAMS[@]}"; do
            echo "$key=${MERGED_PARAMS[$key]}" >> "$APP_DIR/.env.production"
        done
    fi
    chmod 600 "$APP_DIR/.env.production"

    # Generate docker-compose secrets sections dynamically
    SERVICES_SECRETS_SECTION="    secrets:\n      - source: ${APP_NAME}_mongo_uri\n        target: MONGO_URI"
    GLOBAL_SECRETS_SECTION="secrets:\n  ${APP_NAME}_mongo_uri:\n    external: true"

    for key in "${!MAPPED_SECRETS[@]}"; do
        SECRET_NAME="${MAPPED_SECRETS[$key]}"
        SERVICES_SECRETS_SECTION="${SERVICES_SECRETS_SECTION}\n      - source: ${SECRET_NAME}\n        target: ${key}"
        GLOBAL_SECRETS_SECTION="${GLOBAL_SECRETS_SECTION}\n  ${SECRET_NAME}:\n    external: true"
    done

    # Write docker-compose.prod.yml
    COMPOSE_FILE="$APP_DIR/docker-compose.prod.yml"
    cat <<EOF > "$COMPOSE_FILE"
version: "3.8"

services:
  backend-${APP_NAME}:
    image: ${IMAGE}
    container_name: app_${APP_NAME}_backend
    restart: unless-stopped
    env_file:
      - .env.production
    networks:
      - web_gateway
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
EOF

    if [ -n "$ACTIVE_CPUS" ]; then
        echo "    cpus: \"${ACTIVE_CPUS}\"" >> "$COMPOSE_FILE"
    fi
    if [ -n "$ACTIVE_MEM" ]; then
        echo "    mem_limit: \"${ACTIVE_MEM}\"" >> "$COMPOSE_FILE"
    fi

    echo -e "$SERVICES_SECRETS_SECTION" >> "$COMPOSE_FILE"

    cat <<EOF >> "$COMPOSE_FILE"
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.${APP_NAME}.rule=PathPrefix(\`/${APP_NAME}\`)"
      - "traefik.http.routers.${APP_NAME}.entrypoints=websecure"
      - "traefik.http.routers.${APP_NAME}.tls=true"
      - "traefik.http.middlewares.${APP_NAME}-strip.stripprefix.prefixes=/${APP_NAME}"
      - "traefik.http.routers.${APP_NAME}.middlewares=${APP_NAME}-strip"
      - "traefik.http.services.${APP_NAME}.loadbalancer.server.port=3000"

EOF

    echo -e "$GLOBAL_SECRETS_SECTION" >> "$COMPOSE_FILE"

    cat <<EOF >> "$COMPOSE_FILE"

networks:
  web_gateway:
    external: true
EOF

    log_success "Configuration updated successfully!"
    log_success "Run './appRouter.sh restart $APP_NAME' to apply changes."
}

do_update() {
    APP_NAME=$(echo "$1" | tr '.' '-')
    NEW_IMAGE="$2"
    APP_DIR="/opt/$APP_NAME"
    ENV_FILE="$INFRA_DIR/.env"
    
    if [ ! -d "$APP_DIR" ] || [ ! -f "$APP_DIR/docker-compose.prod.yml" ]; then
        log_error "Application '$APP_NAME' is not deployed or missing docker-compose.prod.yml."
        exit 1
    fi
    
    # Resolve image to pull
    if [ -n "$NEW_IMAGE" ]; then
        IMAGE="$NEW_IMAGE"
    else
        IMAGE=$(grep "image:" "$APP_DIR/docker-compose.prod.yml" | head -n 1 | awk '{print $2}')
    fi
    
    log_info "1. Pulling updated image: $IMAGE..."
    podman pull "$IMAGE" >/dev/null
    
    # Read existing configurations for contract verification
    declare -A MERGED_PARAMS
    ACTIVE_CPUS=""
    ACTIVE_MEM=""

    if [ -f "$APP_DIR/.env.production" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            line=$(echo "$line" | tr -d '\r')
            [[ "$line" =~ ^[[:space:]]*# ]] && continue
            [[ "$line" =~ ^[[:space:]]*$ ]] && continue
            if [[ "$line" != *=* ]]; then continue; fi
            
            KEY="${line%%=*}"
            VAL="${line#*=}"
            if [ "$KEY" != "PORT" ] && [ "$KEY" != "NODE_ENV" ] && [ "$KEY" != "APP_DOMAIN" ] && [ "$KEY" != "APP_CPUS" ] && [ "$KEY" != "APP_MEM_LIMIT" ]; then
                MERGED_PARAMS["$KEY"]="$VAL"
            fi
        done < "$APP_DIR/.env.production"

        set +e
        ENV_CPUS=$(grep "^APP_CPUS=" "$APP_DIR/.env.production" | cut -d= -f2)
        ENV_MEM=$(grep "^APP_MEM_LIMIT=" "$APP_DIR/.env.production" | cut -d= -f2)
        set -e
        if [ -n "$ENV_CPUS" ]; then ACTIVE_CPUS="$ENV_CPUS"; fi
        if [ -n "$ENV_MEM" ]; then ACTIVE_MEM="$ENV_MEM"; fi
    fi
    
    declare -A MAPPED_SECRETS
    if [ -f "$APP_DIR/docker-compose.prod.yml" ]; then
        for s_source in $(grep -o "${APP_NAME}_secret_[A-Za-z0-9_]*" "$APP_DIR/docker-compose.prod.yml" 2>/dev/null | sort -u || true); do
            KEY="${s_source#${APP_NAME}_secret_}"
            MAPPED_SECRETS["$KEY"]="$s_source"
        done
    fi
    
    log_info "2. Inspecting contract of new image via --show-spec..."
    ENTRYPOINT_JSON=$(podman image inspect "$IMAGE" --format '{{json .Config.Entrypoint}}' 2>/dev/null || echo "null")
    IS_WRAPPER=$(echo "$ENTRYPOINT_JSON" | jq -e 'type == "array" and (.[0] | sub(".*/"; "") | in({"npm":1, "yarn":1, "pnpm":1, "bun":1}))' >/dev/null 2>&1 && echo "true" || echo "false")
    SPEC_ERR_FILE=$(mktemp)
    if [ "$IS_WRAPPER" = "true" ]; then
        log_info "Package manager entrypoint wrapper detected. Injecting '--' before contract flags."
        SPEC_OUTPUT=$(podman run --rm "$IMAGE" -- --show-spec 2>"$SPEC_ERR_FILE" || true)
    else
        SPEC_OUTPUT=$(podman run --rm "$IMAGE" --show-spec 2>"$SPEC_ERR_FILE" || true)
    fi
    
    if ! echo "$SPEC_OUTPUT" | grep -q "^REQUIRED_PARAMETERS="; then
        log_error "Application contract validation failed: Updated image does not support --show-spec or is invalid."
        if [ -s "$SPEC_ERR_FILE" ]; then
            log_error "Container error output:"
            cat "$SPEC_ERR_FILE" >&2
        fi
        rm -f "$SPEC_ERR_FILE"
        exit 1
    fi
    rm -f "$SPEC_ERR_FILE"

    REQ_PARAMS_STR=$(echo "$SPEC_OUTPUT" | grep "^REQUIRED_PARAMETERS=" | cut -d= -f2 | tr -d '\r' | tr -d '[:space:]')
    REQ_SECRETS_STR=$(echo "$SPEC_OUTPUT" | grep "^REQUIRED_SECRETS=" | cut -d= -f2 | tr -d '\r' | tr -d '[:space:]')

    # Validate parameters
    IFS=',' read -ra REQ_PARAMS <<< "$REQ_PARAMS_STR"
    MISSING_PARAMS=()
    for req in "${REQ_PARAMS[@]}"; do
        [ -z "$req" ] && continue
        if [ -z "${MERGED_PARAMS[$req]}" ]; then
            MISSING_PARAMS+=("$req")
        fi
    done

    # Validate secrets
    IFS=',' read -ra REQ_SECRETS <<< "$REQ_SECRETS_STR"
    MISSING_SECRETS=()
    for req in "${REQ_SECRETS[@]}"; do
        [ -z "$req" ] && continue
        if [ -z "${MAPPED_SECRETS[$req]}" ]; then
            MISSING_SECRETS+=("$req")
        fi
    done

    if [ ${#MISSING_PARAMS[@]} -gt 0 ] || [ ${#MISSING_SECRETS[@]} -gt 0 ]; then
        log_error "Pre-flight contract verification failed for the updated image!"
        log_error "To update, you must first pass the new required configs via the 'configure' subcommand."
        if [ ${#MISSING_PARAMS[@]} -gt 0 ]; then
            echo -e "${RED}Missing required parameters:${NC}"
            for m in "${MISSING_PARAMS[@]}"; do
                echo -e "  - $m"
            done
        fi
        if [ ${#MISSING_SECRETS[@]} -gt 0 ]; then
            echo -e "${RED}Missing required secrets:${NC}"
            for s in "${MISSING_SECRETS[@]}"; do
                echo -e "  - $s"
            done
        fi
        exit 1
    fi
    log_success "Contract check passed."

    log_info "3. Re-generating compose file with image: $IMAGE..."
    SERVICES_SECRETS_SECTION="    secrets:\n      - source: ${APP_NAME}_mongo_uri\n        target: MONGO_URI"
    GLOBAL_SECRETS_SECTION="secrets:\n  ${APP_NAME}_mongo_uri:\n    external: true"

    for key in "${!MAPPED_SECRETS[@]}"; do
        SECRET_NAME="${MAPPED_SECRETS[$key]}"
        SERVICES_SECRETS_SECTION="${SERVICES_SECRETS_SECTION}\n      - source: ${SECRET_NAME}\n        target: ${key}"
        GLOBAL_SECRETS_SECTION="${GLOBAL_SECRETS_SECTION}\n  ${SECRET_NAME}:\n    external: true"
    done

    COMPOSE_FILE="$APP_DIR/docker-compose.prod.yml"
    cat <<EOF > "$COMPOSE_FILE"
version: "3.8"

services:
  backend-${APP_NAME}:
    image: ${IMAGE}
    container_name: app_${APP_NAME}_backend
    restart: unless-stopped
    env_file:
      - .env.production
    networks:
      - web_gateway
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
EOF

    if [ -n "$ACTIVE_CPUS" ]; then
        echo "    cpus: \"${ACTIVE_CPUS}\"" >> "$COMPOSE_FILE"
    fi
    if [ -n "$ACTIVE_MEM" ]; then
        echo "    mem_limit: \"${ACTIVE_MEM}\"" >> "$COMPOSE_FILE"
    fi

    # Append mounted secrets
    echo -e "$SERVICES_SECRETS_SECTION" >> "$COMPOSE_FILE"

    cat <<EOF >> "$COMPOSE_FILE"
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.${APP_NAME}.rule=PathPrefix(\`/${APP_NAME}\`)"
      - "traefik.http.routers.${APP_NAME}.entrypoints=websecure"
      - "traefik.http.routers.${APP_NAME}.tls=true"
      - "traefik.http.middlewares.${APP_NAME}-strip.stripprefix.prefixes=/${APP_NAME}"
      - "traefik.http.routers.${APP_NAME}.middlewares=${APP_NAME}-strip"
      - "traefik.http.services.${APP_NAME}.loadbalancer.server.port=3000"

EOF

    echo -e "$GLOBAL_SECRETS_SECTION" >> "$COMPOSE_FILE"

    cat <<EOF >> "$COMPOSE_FILE"

networks:
  web_gateway:
    external: true
EOF

    log_info "4. Re-deploying application..."
    cd "$APP_DIR"
    podman-compose -f docker-compose.prod.yml down
    podman-compose -f docker-compose.prod.yml up -d
    
    log_success "Application '$APP_NAME' updated and re-deployed successfully!"
}

do_destroy_app() {
    APP_NAME=$(echo "$1" | tr '.' '-')
    APP_DIR="/opt/$APP_NAME"
    ENV_FILE="$INFRA_DIR/.env"
    
    # 1. Stop container if it is running and workspace exists
    if [ -d "$APP_DIR" ] && [ -f "$APP_DIR/docker-compose.prod.yml" ]; then
        log_info "1. Halting container services for '$APP_NAME'..."
        cd "$APP_DIR"
        podman-compose down || true
    else
        log_warn "Application directory or compose file not found at $APP_DIR. Skipping service teardown."
    fi

    # 2. Handle Secrets cleanup
    if [ "$DESTROY_SECRETS" = "delete" ]; then
        log_info "2. Deleting registered secrets from Podman..."
        podman secret rm "${APP_NAME}_mongo_uri" >/dev/null 2>&1 || true
        for s in $(podman secret ls --format "{{.Name}}" 2>/dev/null | grep "^${APP_NAME}_secret_"); do
            podman secret rm "$s" >/dev/null 2>&1 || true
        done
        log_success "Secrets deleted."
    else
        log_info "2. Preserving registered secrets in Podman."
    fi

    # 3. Handle Data cleanup (database drop and user drop)
    if [ "$DESTROY_DATA" = "delete" ]; then
        log_info "3. Dropping database and user from MongoDB..."
        if [ -f "$ENV_FILE" ]; then
            set +e
            MONGO_ROOT_USER=$(grep "^MONGO_ROOT_USER=" "$ENV_FILE" | cut -d= -f2 | tr -d '\r')
            MONGO_ROOT_PASSWORD=$(grep "^MONGO_ROOT_PASSWORD=" "$ENV_FILE" | cut -d= -f2 | tr -d '\r')
            set -e
            
            if [ -n "$MONGO_ROOT_USER" ] && [ -n "$MONGO_ROOT_PASSWORD" ]; then
                APP_DB_USER="user_$(echo "$APP_NAME" | tr '-' '_' | tr '.' '_')"
                DB_NAME=$(echo "$APP_NAME" | tr '-' '_' | tr '.' '_')_db
                
                podman exec -i shared_production_mongodb mongosh \
                    -u "$MONGO_ROOT_USER" \
                    -p "$MONGO_ROOT_PASSWORD" \
                    --authenticationDatabase admin \
                    --eval "
                        db.getSiblingDB('${DB_NAME}').dropUser('${APP_DB_USER}');
                        db.getSiblingDB('${DB_NAME}').dropDatabase();
                    " >/dev/null
                log_success "Database '${DB_NAME}' and user '${APP_DB_USER}' dropped."
            else
                log_error "Could not retrieve root Mongo credentials. Skipping database cleanup."
            fi
        else
            log_error "Central infrastructure .env not found. Skipping database cleanup."
        fi
    else
        log_info "3. Preserving database data and user permissions."
    fi

    # 4. Handle Backups cleanup
    if [ "$DESTROY_BACKUPS" = "delete" ]; then
        if [ -d "$APP_DIR/backups" ]; then
            log_info "4. Deleting backups under '$APP_DIR/backups'..."
            sudo rm -rf "$APP_DIR/backups"
            log_success "Backups deleted."
        fi
    else
        log_info "4. Preserving backups under '$APP_DIR/backups'."
    fi

    # 5. Handle Parameters / Workspace cleanup
    if [ "$DESTROY_PARAMS" = "delete" ]; then
        if [ "$DESTROY_BACKUPS" = "keep" ] && [ -d "$APP_DIR/backups" ]; then
            log_info "5. Deleting application configurations inside '$APP_DIR' while preserving backups..."
            sudo find "$APP_DIR" -mindepth 1 -maxdepth 1 ! -name "backups" -exec rm -rf {} +
            log_success "Application configurations deleted, backups preserved."
        else
            log_info "5. Deleting application directory '$APP_DIR' completely..."
            sudo rm -rf "$APP_DIR"
            log_success "Application directory deleted."
        fi
    else
        log_info "5. Preserving application configurations directory '$APP_DIR'."
    fi

    log_success "Application '$APP_NAME' destroyed successfully!"
}

do_backup() {
    APP_NAME=$(echo "$APP_NAME" | tr '.' '-')
    # Sanitize backup description to prevent path traversal and invalid filename characters
    BACKUP_DESC=$(printf "%s" "$BACKUP_DESC" | tr -c 'a-zA-Z0-9_-' '_')
    ENV_FILE="$INFRA_DIR/.env"
    if [ ! -f "$ENV_FILE" ]; then
        log_error "Central infrastructure is not installed or .env is missing. Run install first."
        exit 1
    fi
    set +e
    MONGO_ROOT_USER=$(grep "^MONGO_ROOT_USER=" "$ENV_FILE" | cut -d= -f2 | tr -d '\r')
    MONGO_ROOT_PASSWORD=$(grep "^MONGO_ROOT_PASSWORD=" "$ENV_FILE" | cut -d= -f2 | tr -d '\r')
    set -e
    if [ -z "$MONGO_ROOT_USER" ] || [ -z "$MONGO_ROOT_PASSWORD" ]; then
        log_error "Failed to retrieve MongoDB root credentials from $ENV_FILE."
        exit 1
    fi
    if ! podman ps --format "{{.Names}}" | grep -q "^shared_production_mongodb$"; then
        log_error "MongoDB container 'shared_production_mongodb' is not running."
        exit 1
    fi

    # Determine target applications
    declare -a TARGET_APPS=()
    if [ "$ALL_APPS" = true ]; then
        for d in /opt/*; do
            if [ -d "$d" ] && [ -f "$d/docker-compose.prod.yml" ]; then
                TARGET_APPS+=("${d##*/}")
            fi
        done
        if [ ${#TARGET_APPS[@]} -eq 0 ]; then
            log_warn "No deployed applications found to back up."
            return 0
        fi
    else
        APP_DIR="/opt/$APP_NAME"
        if [ ! -d "$APP_DIR" ] || [ ! -f "$APP_DIR/docker-compose.prod.yml" ]; then
            log_error "Application '$APP_NAME' is not deployed or missing docker-compose.prod.yml."
            exit 1
        fi
        TARGET_APPS+=("$APP_NAME")
    fi

    # Run backup for each target
    TIMESTAMP=$(date +"%Y_%m_%d__%H_%M_%S")
    for app in "${TARGET_APPS[@]}"; do
        DB_NAME=$(echo "$app" | tr '-' '_' | tr '.' '_')_db
        BACKUP_DIR="/opt/$app/backups"
        
        # Ensure backup dir exists with proper permissions
        sudo mkdir -p "$BACKUP_DIR"
        sudo chown -R "$(id -u):$(id -g)" "$BACKUP_DIR"

        if [ -n "$BACKUP_DESC" ]; then
            FILE_NAME="${TIMESTAMP}__${BACKUP_DESC}.gzip"
        else
            FILE_NAME="${TIMESTAMP}.gzip"
        fi
        BACKUP_FILE="${BACKUP_DIR}/${FILE_NAME}"

        log_info "Backing up database '${DB_NAME}' for app '${app}'..."
        set +e
        podman exec -i shared_production_mongodb mongodump \
            --username="$MONGO_ROOT_USER" \
            --password="$MONGO_ROOT_PASSWORD" \
            --authenticationDatabase=admin \
            --db="$DB_NAME" \
            --archive \
            --gzip \
            --quiet > "$BACKUP_FILE"
        STATUS=$?
        set -e

        if [ $STATUS -eq 0 ] && [ -s "$BACKUP_FILE" ]; then
            log_success "Backup completed successfully: ${BACKUP_FILE}"
        else
            log_error "Failed to create database backup for app '${app}'."
            rm -f "$BACKUP_FILE"
        fi
    done
}

do_restore() {
    APP_NAME=$(echo "$APP_NAME" | tr '.' '-')
    ENV_FILE="$INFRA_DIR/.env"
    if [ ! -f "$ENV_FILE" ]; then
        log_error "Central infrastructure is not installed or .env is missing. Run install first."
        exit 1
    fi
    set +e
    MONGO_ROOT_USER=$(grep "^MONGO_ROOT_USER=" "$ENV_FILE" | cut -d= -f2 | tr -d '\r')
    MONGO_ROOT_PASSWORD=$(grep "^MONGO_ROOT_PASSWORD=" "$ENV_FILE" | cut -d= -f2 | tr -d '\r')
    set -e
    if [ -z "$MONGO_ROOT_USER" ] || [ -z "$MONGO_ROOT_PASSWORD" ]; then
        log_error "Failed to retrieve MongoDB root credentials from $ENV_FILE."
        exit 1
    fi
    if ! podman ps --format "{{.Names}}" | grep -q "^shared_production_mongodb$"; then
        log_error "MongoDB container 'shared_production_mongodb' is not running."
        exit 1
    fi

    # Determine target applications and backups
    declare -a TARGET_APPS=()
    declare -a BACKUP_FILES=()

    if [ "$ALL_APPS" = true ]; then
        for d in /opt/*; do
            if [ -d "$d" ] && [ -f "$d/docker-compose.prod.yml" ]; then
                app="${d##*/}"
                # Find the latest backup
                BACKUP_DIR="/opt/$app/backups"
                if [ -d "$BACKUP_DIR" ]; then
                    LATEST_FILE=$(ls -1 "$BACKUP_DIR"/*.gzip 2>/dev/null | sort | tail -n 1)
                    if [ -n "$LATEST_FILE" ]; then
                        TARGET_APPS+=("$app")
                        BACKUP_FILES+=("$LATEST_FILE")
                    else
                        log_warn "No backups found for app '$app'. Skipping restore."
                    fi
                else
                    log_warn "No backups folder found for app '$app'. Skipping restore."
                fi
            fi
        done
        if [ ${#TARGET_APPS[@]} -eq 0 ]; then
            log_warn "No applications found with available backups to restore."
            return 0
        fi
    else
        APP_DIR="/opt/$APP_NAME"
        if [ ! -d "$APP_DIR" ] || [ ! -f "$APP_DIR/docker-compose.prod.yml" ]; then
            log_error "Application '$APP_NAME' is not deployed or missing docker-compose.prod.yml."
            exit 1
        fi
        
        # Verify the specified backup exists
        # Sanitize backup name to prevent path traversal
        SAFE_BACKUP_NAME=$(basename "$BACKUP_NAME")
        if [ "$SAFE_BACKUP_NAME" != "$BACKUP_NAME" ]; then
            log_error "Backup name contains invalid path characters."
            exit 1
        fi
        
        BACKUP_FILE="/opt/$APP_NAME/backups/$BACKUP_NAME"
        if [ ! -f "$BACKUP_FILE" ]; then
            log_error "Backup file '$BACKUP_NAME' not found under /opt/$APP_NAME/backups/."
            exit 1
        fi
        
        TARGET_APPS+=("$APP_NAME")
        BACKUP_FILES+=("$BACKUP_FILE")
    fi

    # Execute restore for each target
    for i in "${!TARGET_APPS[@]}"; do
        app="${TARGET_APPS[$i]}"
        backup_file="${BACKUP_FILES[$i]}"
        DB_NAME=$(echo "$app" | tr '-' '_' | tr '.' '_')_db
        
        # 1. Stop application
        log_info "1. Stopping application '$app' before restore..."
        do_stop "$app" >/dev/null || true

        # 2. Run mongorestore
        log_info "2. Restoring database '$DB_NAME' from '$backup_file'..."
        set +e
        podman exec -i shared_production_mongodb mongorestore \
            --username="$MONGO_ROOT_USER" \
            --password="$MONGO_ROOT_PASSWORD" \
            --authenticationDatabase=admin \
            --drop \
            --archive \
            --gzip \
            --quiet < "$backup_file"
        STATUS=$?
        set -e

        if [ $STATUS -eq 0 ]; then
            log_success "Database restore completed successfully."
        else
            log_error "Failed to restore database for app '$app'."
        fi

        # 3. Start application
        log_info "3. Restarting application '$app'..."
        do_start "$app" >/dev/null || true
    done
}

case "$ACTION" in
    install)
        do_install
        ;;
    uninstall)
        do_uninstall
        ;;
    create-app)
        do_create_app "$APP_IMAGE"
        ;;
    list)
        do_list
        ;;
    start)
        do_start "$APP_NAME"
        ;;
    stop)
        do_stop "$APP_NAME"
        ;;
    restart)
        do_restart "$APP_NAME"
        ;;
    logs)
        do_logs "$APP_NAME" "${LOG_ARGS[@]}"
        ;;
    configure)
        do_configure "$APP_NAME"
        ;;
    update)
        do_update "$APP_NAME" "$UPDATE_IMAGE"
        ;;
    destroy-app)
        do_destroy_app "$APP_NAME"
        ;;
    backup)
        do_backup
        ;;
    restore)
        do_restore
        ;;
    *)
        show_usage
        ;;
esac
