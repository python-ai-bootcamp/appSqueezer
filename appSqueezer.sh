#!/usr/bin/env bash

# Exit immediately if a command exits with a non-zero status
set -e

# Ensure standard user runtime directory is exported for systemd user services
export XDG_RUNTIME_DIR="/run/user/$(id -u)"

# Configuration / Output paths
INFRA_DIR="/opt/web-infrastructure"

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

verify_container_running() {
    local container_name="$1"
    local max_attempts=15
    local attempt=1
    log_info "Waiting for container '$container_name' to start..."
    while [ $attempt -le $max_attempts ]; do
        local status
        status=$(podman inspect --format '{{.State.Running}}' "$container_name" 2>/dev/null || echo "false")
        if [ "$status" = "true" ]; then
            log_success "Container '$container_name' is running."
            return 0
        fi
        sleep 1
        attempt=$((attempt + 1))
    done
    log_error "Timeout: Container '$container_name' did not start or is not running."
    local inspect_err
    inspect_err=$(podman inspect --format '{{.State.Error}}' "$container_name" 2>/dev/null)
    if [ -n "$inspect_err" ]; then
        log_error "Container inspect error: $inspect_err"
    fi
    log_error "Recent logs for '$container_name':"
    podman logs "$container_name" 2>&1 | tail -n 20 >&2
    exit 1
}

verify_mongodb_ready() {
    if ! podman ps --format "{{.Names}}" | grep -q "^shared_production_mongodb$"; then
        log_error "MongoDB container 'shared_production_mongodb' is not running. Start infrastructure first."
        exit 1
    fi
    local max_attempts=30
    local attempt=1
    log_info "Verifying MongoDB connectivity..."
    while [ $attempt -le $max_attempts ]; do
        set +e
        podman exec -i shared_production_mongodb mongosh \
            -u "$MONGO_ROOT_USER" \
            -p "$MONGO_ROOT_PASSWORD" \
            --authenticationDatabase admin \
            --eval "db.adminCommand('ping')" >/dev/null 2>&1
        STATUS=$?
        set -e
        if [ $STATUS -eq 0 ]; then
            log_success "MongoDB is ready."
            return 0
        fi
        log_info "MongoDB is not ready yet (attempt $attempt/$max_attempts), retrying in 2 seconds..."
        sleep 2
        attempt=$((attempt + 1))
    done
    log_error "Timeout: MongoDB did not become ready to accept connections."
    exit 1
}

verify_container_contract() {
    local image="$1"
    local error_msg_prefix="$2"
    
    log_info "Inspecting application contract via --show-spec..." >&2
    
    local entrypoint_json
    local cmd_json
    entrypoint_json=$(podman image inspect "$image" --format '{{json .Config.Entrypoint}}' 2>/dev/null || echo "null")
    cmd_json=$(podman image inspect "$image" --format '{{json .Config.Cmd}}' 2>/dev/null || echo "null")
    
    local is_wrapper="false"
    local spec_err_file
    spec_err_file=$(mktemp)
    local spec_output=""
    
    if [ "$entrypoint_json" = "null" ] || [ "$entrypoint_json" = "[]" ]; then
        if [ "$cmd_json" != "null" ] && [ "$cmd_json" != "[]" ]; then
            is_wrapper=$(echo "$cmd_json" | jq -e 'type == "array" and (.[0] | strings | sub(".*/"; "") | in({"npm":1, "yarn":1, "pnpm":1, "bun":1}))' >/dev/null 2>&1 && echo "true" || echo "false")
            
            local cmd_args=()
            while IFS= read -r arg; do
                cmd_args+=("$arg")
            done < <(echo "$cmd_json" | jq -r '.[]')
            
            if [ "$is_wrapper" = "true" ]; then
                log_info "Package manager command wrapper detected in CMD. Overriding Entrypoint and injecting '--'." >&2
                spec_output=$(timeout 10 podman run --rm --entrypoint "" "$image" "${cmd_args[@]}" -- --show-spec 2>"$spec_err_file" || true)
            else
                log_info "Using CMD elements as args. Overriding Entrypoint." >&2
                spec_output=$(timeout 10 podman run --rm --entrypoint "" "$image" "${cmd_args[@]}" --show-spec 2>"$spec_err_file" || true)
            fi
        else
            spec_output=$(timeout 10 podman run --rm "$image" --show-spec 2>"$spec_err_file" || true)
        fi
    else
        is_wrapper=$(echo "$entrypoint_json" | jq -e 'type == "array" and (.[0] | strings | sub(".*/"; "") | in({"npm":1, "yarn":1, "pnpm":1, "bun":1}))' >/dev/null 2>&1 && echo "true" || echo "false")
        
        local entry_args=()
        while IFS= read -r arg; do
            entry_args+=("$arg")
        done < <(echo "$entrypoint_json" | jq -r '.[]')
        
        local cmd_args=()
        if [ "$cmd_json" != "null" ] && [ "$cmd_json" != "[]" ]; then
            while IFS= read -r arg; do
                cmd_args+=("$arg")
            done < <(echo "$cmd_json" | jq -r '.[]')
        fi
        
        if [ "$is_wrapper" = "true" ]; then
            log_info "Package manager entrypoint wrapper detected. Overriding Entrypoint and injecting '--'." >&2
            spec_output=$(timeout 10 podman run --rm --entrypoint "" "$image" "${entry_args[@]}" "${cmd_args[@]}" -- --show-spec 2>"$spec_err_file" || true)
        else
            log_info "Combining Entrypoint and CMD. Overriding Entrypoint." >&2
            spec_output=$(timeout 10 podman run --rm --entrypoint "" "$image" "${entry_args[@]}" "${cmd_args[@]}" --show-spec 2>"$spec_err_file" || true)
        fi
    fi
    
    if ! echo "$spec_output" | grep -q "^REQUIRED_PARAMETERS=" || ! echo "$spec_output" | grep -q "^REQUIRED_SECRETS="; then
        log_error "$error_msg_prefix" >&2
        if [ -s "$spec_err_file" ]; then
            log_error "Container error output:" >&2
            cat "$spec_err_file" >&2
        fi
        rm -f "$spec_err_file"
        exit 1
    fi
    rm -f "$spec_err_file"
    echo "$spec_output"
}

# Ensure script is NOT run directly as root to preserve user-level Podman environment
if [ "$EUID" -eq 0 ]; then
    log_error "Please do not run this script as root/sudo directly."
    log_error "Run it as a standard user with sudo privileges: ./appSqueezer.sh install ..."
    exit 1
fi

show_usage() {
    local exit_code="${1:-1}"
    echo "Usage: $0 <command> [options]"
    echo ""
    echo "Commands:"
    echo "  install      Install central infrastructure (Traefik, MongoDB)"
    echo "  uninstall    Uninstall infrastructure and cleanup"
    echo "  create-app   Deploy a new web application"
    echo "  list         List all deployed applications"
    echo "  start        Start a stopped application"
    echo "  stop         Stop a running application"
    echo "  restart      Restart an application"
    echo "  logs         Show logs of an application"
    echo "  configure    Update application configuration"
    echo "  update       Update application image"
    echo "  destroy-app  Destroy an application and its resources"
    echo "  backup       Backup application databases"
    echo "  restore      Restore application databases from backups"
    echo "  completion   Generate shell autocompletion script"
    echo "  help         Show detailed help for a subcommand"
    echo ""
    echo "Run '$0 <command> --help' or '$0 help <command>' for detailed help on a command."
    exit "$exit_code"
}

show_command_help() {
    local cmd="$1"
    local exit_code="${2:-1}"
    case "$cmd" in
        install)
            echo "Usage: $0 install -d <domain> [-e <email>] [-u <mongo-user>] [-p <mongo-password>]"
            echo ""
            echo "Install central infrastructure (Traefik edge router, shared MongoDB database)."
            echo ""
            echo "Options:"
            echo "  -d, --domain          Domain name for routing (Mandatory)"
            echo "  -e, --email           Let's Encrypt admin email (Default: admin@example.com)"
            echo "  -u, --mongo-user      MongoDB admin username (Default: admin_user)"
            echo "  -p, --mongo-password  MongoDB admin password (Default: auto-generated)"
            ;;
        uninstall)
            echo "Usage: $0 uninstall [-y|--non-interactive] [--keep-apps | --destroy-apps]"
            echo ""
            echo "Uninstall infrastructure services, network configurations, and files."
            echo ""
            echo "Options:"
            echo "  -y, --non-interactive Force uninstall without prompting (Automatic cleanup of files)"
            echo "  --keep-apps           Retain all application databases, secrets, backups, and parameters"
            echo "  --destroy-apps        Completely purge all applications, parameters, secrets, databases, and backups"
            ;;
        create-app)
            echo "Usage: $0 create-app <image> [options]"
            echo ""
            echo "Deploy a new containerized application and set up database/routing rules."
            echo ""
            echo "Options:"
            echo "  --app-parameter                  Pass environment variables to app (e.g. --app-parameter \"K=V\")"
            echo "  --app-secret                     Pass sensitive secrets to app via secure file mounts (e.g. --app-secret \"K=V\")"
            echo "  --cpu                            CPU limit constraints (e.g. --cpu \"0.5\")"
            echo "  --memory                         Memory limit constraints (e.g. --memory \"512M\")"
            echo "  --use-existing-parameters        Re-use existing parameters if leftovers are found"
            echo "  --disregard-existing-parameters   Discard/overwrite existing parameters if leftovers are found"
            echo "  --use-existing-secrets           Re-use existing secrets if leftovers are found"
            echo "  --disregard-existing-secrets      Discard/re-create existing secrets if leftovers are found"
            echo "  --use-existing-data              Re-use existing database and user in MongoDB if leftovers are found"
            echo "  --disregard-existing-data         Drop and re-create database and user in MongoDB if leftovers are found"
            ;;
        list)
            echo "Usage: $0 list"
            echo ""
            echo "List all deployed applications, their routing URLs, and container status."
            ;;
        start)
            echo "Usage: $0 start <app-name>"
            echo ""
            echo "Start a stopped application's containers."
            ;;
        stop)
            echo "Usage: $0 stop <app-name>"
            echo ""
            echo "Stop a running application's containers."
            ;;
        restart)
            echo "Usage: $0 restart <app-name>"
            echo ""
            echo "Restart an application (recreates containers to apply config updates)."
            ;;
        logs)
            echo "Usage: $0 logs <app-name> [compose-options...]"
            echo ""
            echo "Show logs of an application container (supports all podman-compose log options like -f, --tail)."
            ;;
        configure)
            echo "Usage: $0 configure <app-name> [options]"
            echo ""
            echo "Update configuration parameters, secrets, or resource constraints of an app."
            echo ""
            echo "Options:"
            echo "  --app-parameter         Pass environment variables to app (e.g. --app-parameter \"K=V\")"
            echo "  --app-secret            Pass sensitive secrets to app via secure file mounts (e.g. --app-secret \"K=V\")"
            echo "  --cpu                   CPU limit constraints (e.g. --cpu \"0.5\")"
            echo "  --memory                Memory limit constraints (e.g. --memory \"512M\")"
            echo "  --clear-app-parameters  Discard existing app parameters"
            echo "  --clear-app-secrets     Discard existing app secrets"
            echo "  --clear-app-limits      Discard existing CPU and memory limits"
            ;;
        update)
            echo "Usage: $0 update <app-name> [--image <new-image-url>]"
            echo ""
            echo "Update the container image URL and re-deploy the application."
            echo ""
            echo "Options:"
            echo "  --image <new-image-url> Change the container image URL to the specified one"
            ;;
        destroy-app)
            echo "Usage: $0 destroy-app <app-name> [options]"
            echo ""
            echo "Halt services and permanently destroy app configurations, secrets, database, or backups."
            echo ""
            echo "Options:"
            echo "  --keep-secrets | --delete-secrets      Keep or delete registered secret files"
            echo "  --keep-parameters | --delete-parameters Keep or delete configuration parameters"
            echo "  --keep-data | --delete-data            Keep or drop database and database user in MongoDB"
            echo "  --keep-backups | --delete-backups      Keep or delete database backup files"
            ;;
        backup)
            echo "Usage: $0 backup [--app-name=<name> | --all] [--description=<suffix>]"
            echo ""
            echo "Backup databases of one or all deployed applications using mongodump."
            echo ""
            echo "Options:"
            echo "  --app-name=<name>     Select single application context"
            echo "  --all                 Target all deployed applications"
            echo "  --description=<suffix> Optional description suffix for the backup file name"
            echo "                         (Only alphanumeric characters, hyphens, and underscores are allowed)"
            ;;
        restore)
            echo "Usage: $0 restore [--app-name=<name> --backup-name=<file> | --all]"
            echo ""
            echo "Restore database of one or all deployed applications using mongorestore."
            echo ""
            echo "Options:"
            echo "  --app-name=<name>     Select single application context"
            echo "  --backup-name=<file>  Name of database backup file (Mandatory when restoring a single application)"
            echo "  --all                 Target all deployed applications (Restores latest backup for each)"
            ;;
        completion)
            echo "Usage: $0 completion generate"
            echo ""
            echo "Generate shell autocompletion script for Bash."
            echo ""
            echo "To enable autocompletion, run:"
            echo "  source <( $0 completion generate )"
            echo ""
            echo "To make it permanent, run either one of the following commands:"
            echo "    echo 'source <( /path/to/appSqueezer.sh completion generate )' >> ~/.bashrc"
            echo "    ./appSqueezer.sh completion generate >> ~/.bash_completion"
            ;;
        *)
            log_error "Unknown command: $cmd"
            echo "Run '$0 --help' to see list of valid commands."
            exit_code=1
            ;;
    esac
    exit "$exit_code"
}

# Ensure action is provided
if [ $# -lt 1 ]; then
    show_usage
fi

ACTION=$1

# Handle progressive help if ACTION is help
if [ "$ACTION" = "help" ]; then
    if [ -n "$2" ]; then
        show_command_help "$2" 0
    else
        show_usage 0
    fi
fi

if [ "$ACTION" = "--help" ] || [ "$ACTION" = "-h" ]; then
    show_usage 0
fi

# Also check if any subcommand arguments contain --help or -h
for arg in "$@"; do
    if [ "$arg" = "--help" ] || [ "$arg" = "-h" ]; then
        show_command_help "$ACTION" 0
    fi
done

shift

# Defaults
APP_DOMAIN=""
LETSENCRYPT_EMAIL="admin@example.com"
MONGO_ROOT_USER=""
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
USE_EXISTING_PARAMS=false
DISREGARD_EXISTING_PARAMS=false
USE_EXISTING_SECRETS=false
DISREGARD_EXISTING_SECRETS=false
USE_EXISTING_DATA=false
DISREGARD_EXISTING_DATA=false
UNINSTALL_APPS_ACTION=""



if [ "$ACTION" = "create-app" ]; then
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --app-parameter)
                if [ -z "$2" ]; then
                    log_error "Missing value for --app-parameter"
                    show_command_help "$ACTION"
                fi
                if [[ "$2" != *=* ]]; then
                    log_error "App parameter must be in KEY=VALUE format: $2"
                    exit 1
                fi
                PARAM_KEY="${2%%=*}"
                if [[ "$PARAM_KEY" =~ ^(PORT|APP_ENV|APP_DOMAIN|APP_CPUS|APP_MEM_LIMIT|MONGO_URI|MONGO_ROOT_USER|MONGO_ROOT_PASSWORD)$ ]]; then
                    log_error "Parameter '$PARAM_KEY' is a reserved gateway configuration and cannot be overridden."
                    exit 1
                fi
                if [[ ! "$PARAM_KEY" =~ ^[A-Za-z0-9._-]+$ ]]; then
                    log_error "Parameter key '$PARAM_KEY' contains invalid characters. Only alphanumerics, hyphens, dots, and underscores are allowed."
                    exit 1
                fi
                APP_PARAMS+=("$2")
                shift 2
                ;;
            --app-secret)
                if [ -z "$2" ]; then
                    log_error "Missing value for --app-secret"
                    show_command_help "$ACTION"
                fi
                if [[ "$2" != *=* ]]; then
                    log_error "App secret must be in KEY=VALUE format: $2"
                    exit 1
                fi
                PARAM_KEY="${2%%=*}"
                if [[ ! "$PARAM_KEY" =~ ^[A-Za-z0-9._-]+$ ]]; then
                    log_error "Secret key '$PARAM_KEY' contains invalid characters. Only alphanumerics, hyphens, dots, and underscores are allowed."
                    exit 1
                fi
                APP_SECRETS+=("$2")
                shift 2
                ;;
            --cpu)
                if [ -z "$2" ]; then
                    log_error "Missing value for --cpu"
                    show_command_help "$ACTION"
                fi
                if [[ ! "$2" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
                    log_error "Invalid CPU limit: '$2'. Must be a positive decimal or integer (e.g. 0.5 or 2)."
                    exit 1
                fi
                APP_CPU="$2"
                shift 2
                ;;
            --memory)
                if [ -z "$2" ]; then
                    log_error "Missing value for --memory"
                    show_command_help "$ACTION"
                fi
                if [[ ! "$2" =~ ^[0-9]+[bBkKmMgG]?$ ]]; then
                    log_error "Invalid memory limit: '$2'. Must be a number optionally followed by a unit (e.g. 512M, 2G)."
                    exit 1
                fi
                APP_MEM="$2"
                shift 2
                ;;
            --use-existing-parameters)
                USE_EXISTING_PARAMS=true
                shift
                ;;
            --disregard-existing-parameters)
                DISREGARD_EXISTING_PARAMS=true
                shift
                ;;
            --use-existing-secrets)
                USE_EXISTING_SECRETS=true
                shift
                ;;
            --disregard-existing-secrets)
                DISREGARD_EXISTING_SECRETS=true
                shift
                ;;
            --use-existing-data)
                USE_EXISTING_DATA=true
                shift
                ;;
            --disregard-existing-data)
                DISREGARD_EXISTING_DATA=true
                shift
                ;;
            -*)
                log_error "Unknown option for create-app: $1"
                show_command_help "$ACTION"
                ;;
            *)
                if [ -n "$APP_IMAGE" ]; then
                    log_error "Multiple image names specified: $APP_IMAGE and $1"
                    exit 1
                fi
                APP_IMAGE="$1"
                shift
                ;;
        esac
    done

    if [ -z "$APP_IMAGE" ]; then
        log_error "Missing image name for create-app."
        show_command_help "$ACTION"
    fi

    # Validate mutually exclusive options
    if [ "$USE_EXISTING_PARAMS" = true ] && [ "$DISREGARD_EXISTING_PARAMS" = true ]; then
        log_error "Cannot specify both --use-existing-parameters and --disregard-existing-parameters."
        exit 1
    fi
    if [ "$USE_EXISTING_SECRETS" = true ] && [ "$DISREGARD_EXISTING_SECRETS" = true ]; then
        log_error "Cannot specify both --use-existing-secrets and --disregard-existing-secrets."
        exit 1
    fi
    if [ "$USE_EXISTING_DATA" = true ] && [ "$DISREGARD_EXISTING_DATA" = true ]; then
        log_error "Cannot specify both --use-existing-data and --disregard-existing-data."
        exit 1
    fi
elif [ "$ACTION" = "configure" ]; then
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --app-parameter)
                if [ -z "$2" ]; then
                    log_error "Missing value for --app-parameter"
                    show_command_help "$ACTION"
                fi
                if [[ "$2" != *=* ]]; then
                    log_error "App parameter must be in KEY=VALUE format: $2"
                    exit 1
                fi
                PARAM_KEY="${2%%=*}"
                if [[ "$PARAM_KEY" =~ ^(PORT|APP_ENV|APP_DOMAIN|APP_CPUS|APP_MEM_LIMIT|MONGO_URI|MONGO_ROOT_USER|MONGO_ROOT_PASSWORD)$ ]]; then
                    log_error "Parameter '$PARAM_KEY' is a reserved gateway configuration and cannot be overridden."
                    exit 1
                fi
                if [[ ! "$PARAM_KEY" =~ ^[A-Za-z0-9._-]+$ ]]; then
                    log_error "Parameter key '$PARAM_KEY' contains invalid characters. Only alphanumerics, hyphens, dots, and underscores are allowed."
                    exit 1
                fi
                APP_PARAMS+=("$2")
                shift 2
                ;;
            --app-secret)
                if [ -z "$2" ]; then
                    log_error "Missing value for --app-secret"
                    show_command_help "$ACTION"
                fi
                if [[ "$2" != *=* ]]; then
                    log_error "App secret must be in KEY=VALUE format: $2"
                    exit 1
                fi
                PARAM_KEY="${2%%=*}"
                if [[ ! "$PARAM_KEY" =~ ^[A-Za-z0-9._-]+$ ]]; then
                    log_error "Secret key '$PARAM_KEY' contains invalid characters. Only alphanumerics, hyphens, dots, and underscores are allowed."
                    exit 1
                fi
                APP_SECRETS+=("$2")
                shift 2
                ;;
            --cpu)
                if [ -z "$2" ]; then
                    log_error "Missing value for --cpu"
                    show_command_help "$ACTION"
                fi
                if [[ ! "$2" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
                    log_error "Invalid CPU limit: '$2'. Must be a positive decimal or integer (e.g. 0.5 or 2)."
                    exit 1
                fi
                APP_CPU="$2"
                shift 2
                ;;
            --memory)
                if [ -z "$2" ]; then
                    log_error "Missing value for --memory"
                    show_command_help "$ACTION"
                fi
                if [[ ! "$2" =~ ^[0-9]+[bBkKmMgG]?$ ]]; then
                    log_error "Invalid memory limit: '$2'. Must be a number optionally followed by a unit (e.g. 512M, 2G)."
                    exit 1
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
            -*)
                log_error "Unknown option for configure: $1"
                show_command_help "$ACTION"
                ;;
            *)
                if [ -n "$APP_NAME" ]; then
                    log_error "Multiple app names specified: $APP_NAME and $1"
                    exit 1
                fi
                APP_NAME="$1"
                shift
                ;;
        esac
    done

    if [ -z "$APP_NAME" ]; then
        log_error "Missing app-name for configure."
        show_command_help "$ACTION"
    fi
elif [ "$ACTION" = "update" ]; then
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --image)
                if [ -z "$2" ]; then
                    log_error "Missing value for --image"
                    show_command_help "$ACTION"
                fi
                UPDATE_IMAGE="$2"
                shift 2
                ;;
            -*)
                log_error "Unknown option for update: $1"
                show_command_help "$ACTION"
                ;;
            *)
                if [ -n "$APP_NAME" ]; then
                    log_error "Multiple app names specified: $APP_NAME and $1"
                    exit 1
                fi
                APP_NAME="$1"
                shift
                ;;
        esac
    done

    if [ -z "$APP_NAME" ]; then
        log_error "Missing app-name for update."
        show_command_help "$ACTION"
    fi
elif [ "$ACTION" = "destroy-app" ]; then
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
            -*)
                log_error "Unknown option for destroy-app: $1"
                show_command_help "$ACTION"
                ;;
            *)
                if [ -n "$APP_NAME" ]; then
                    log_error "Multiple app names specified: $APP_NAME and $1"
                    exit 1
                fi
                APP_NAME="$1"
                shift
                ;;
        esac
    done

    if [ -z "$APP_NAME" ]; then
        log_error "Missing app-name for destroy-app."
        show_command_help "$ACTION"
    fi
    
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
                    show_command_help "$ACTION"
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
                    show_command_help "$ACTION"
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
                    show_command_help "$ACTION"
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
                show_command_help "$ACTION"
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
        show_command_help "$ACTION"
    fi
    APP_NAME="$1"
    shift
    if [ $# -gt 0 ]; then
        log_error "Too many arguments for $ACTION: $@"
        show_command_help "$ACTION"
    fi
elif [ "$ACTION" = "logs" ]; then
    if [ $# -lt 1 ]; then
        log_error "Missing app-name for logs."
        show_command_help "$ACTION"
    fi
    APP_NAME="$1"
    shift
    LOG_ARGS=("$@")
elif [ "$ACTION" = "list" ]; then
    if [ $# -gt 0 ]; then
        log_error "Too many arguments for list: $@"
        show_command_help "$ACTION"
    fi
elif [ "$ACTION" = "completion" ]; then
    if [ $# -lt 1 ]; then
        show_command_help "$ACTION" 0
    fi
    SUB_ACTION="$1"
    shift
    if [ "$SUB_ACTION" != "generate" ]; then
        log_error "Unknown argument for completion: $SUB_ACTION"
        show_command_help "$ACTION"
    fi
    if [ $# -gt 0 ]; then
        log_error "Too many arguments for completion generate."
        show_command_help "$ACTION"
    fi
elif [ "$ACTION" = "install" ]; then
    # Parse named parameters for install
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -d|--domain)
                if [ -z "$2" ]; then
                    log_error "Missing value for -d/--domain"
                    show_command_help "$ACTION"
                fi
                APP_DOMAIN="$2"
                shift 2
                ;;
            -e|--email)
                if [ -z "$2" ]; then
                    log_error "Missing value for -e/--email"
                    show_command_help "$ACTION"
                fi
                LETSENCRYPT_EMAIL="$2"
                shift 2
                ;;
            -u|--mongo-user)
                if [ -z "$2" ]; then
                    log_error "Missing value for -u/--mongo-user"
                    show_command_help "$ACTION"
                fi
                MONGO_ROOT_USER="$2"
                shift 2
                ;;
            -p|--mongo-password)
                if [ -z "$2" ]; then
                    log_error "Missing value for -p/--mongo-password"
                    show_command_help "$ACTION"
                fi
                MONGO_ROOT_PASSWORD="$2"
                shift 2
                ;;
            *)
                log_error "Unknown argument for install: $1"
                show_command_help "$ACTION"
                ;;
        esac
    done
elif [ "$ACTION" = "uninstall" ]; then
    # Parse named parameters for uninstall
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -y|--non-interactive)
                NON_INTERACTIVE=true
                shift
                ;;
            --keep-apps)
                if [ -n "$UNINSTALL_APPS_ACTION" ]; then
                    log_error "Cannot specify both --keep-apps and --destroy-apps."
                    exit 1
                fi
                UNINSTALL_APPS_ACTION="keep"
                shift
                ;;
            --destroy-apps)
                if [ -n "$UNINSTALL_APPS_ACTION" ]; then
                    log_error "Cannot specify both --keep-apps and --destroy-apps."
                    exit 1
                fi
                UNINSTALL_APPS_ACTION="destroy"
                shift
                ;;
            *)
                log_error "Unknown argument for uninstall: $1"
                show_command_help "$ACTION"
                ;;
        esac
    done
fi

do_install() {
    # Check mandatory parameter
    if [ -z "$APP_DOMAIN" ]; then
        log_error "Missing required parameter: -d/--domain is mandatory for install."
        show_command_help "$ACTION"
    fi

    # Reuse existing MongoDB credentials if installer is re-run and CLI arguments were not explicitly passed
    local env_file_path="$INFRA_DIR/.env"
    if [ -f "$env_file_path" ]; then
        set +e
        local existing_user
        local existing_pass
        existing_user=$(grep "^MONGO_ROOT_USER=" "$env_file_path" | cut -d= -f2- | tr -d '\r' | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")
        existing_pass=$(grep "^MONGO_ROOT_PASSWORD=" "$env_file_path" | cut -d= -f2- | tr -d '\r' | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")
        set -e
        if [ -n "$existing_user" ] && [ -z "$MONGO_ROOT_USER" ]; then
            MONGO_ROOT_USER="$existing_user"
            log_info "Reusing existing MongoDB root user from $env_file_path."
        fi
        if [ -n "$existing_pass" ] && [ -z "$MONGO_ROOT_PASSWORD" ]; then
            MONGO_ROOT_PASSWORD="$existing_pass"
            log_info "Reusing existing MongoDB root password from $env_file_path."
        fi
    fi

    # Set fallback default user if not loaded or specified
    if [ -z "$MONGO_ROOT_USER" ]; then
        MONGO_ROOT_USER="admin_user"
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
    if command -v apt-get &>/dev/null; then
        log_info "Debian/Ubuntu detected. Installing dependencies via apt-get..."
        sudo apt update
        sudo apt install -y git podman podman-compose gnupg pass jq
    elif command -v dnf &>/dev/null; then
        log_info "RHEL/Rocky/Fedora detected..."
        # Fedora has podman-compose in base; RHEL/Rocky require EPEL
        if ! grep -qi "fedora" /etc/os-release 2>/dev/null; then
            if ! dnf repolist | grep -iq "epel"; then
                log_error "EPEL repository is not enabled. Rocky/RHEL requires EPEL to install 'podman-compose' and 'pass'."
                log_error "Please enable it first (e.g., 'sudo dnf install epel-release') and retry."
                exit 1
            fi
        fi
        log_info "Installing dependencies via dnf..."
        sudo dnf install -y git podman podman-compose gnupg2 pass jq
    elif command -v yum &>/dev/null; then
        log_info "RHEL/CentOS detected..."
        if ! yum repolist | grep -iq "epel"; then
            log_error "EPEL repository is not enabled. RHEL/CentOS requires EPEL to install 'podman-compose' and 'pass'."
            log_error "Please enable it first (e.g., 'sudo yum install epel-release') and retry."
            exit 1
        fi
        log_info "Installing dependencies via yum..."
        sudo yum install -y git podman podman-compose gnupg2 pass jq
    elif command -v zypper &>/dev/null; then
        log_info "openSUSE detected. Installing dependencies via zypper..."
        sudo zypper install -y git podman podman-compose gnupg2 pass jq
    elif command -v pacman &>/dev/null; then
        log_info "Arch Linux detected. Installing dependencies via pacman..."
        sudo pacman -S --noconfirm git podman podman-compose gnupg pass jq
    else
        log_error "Unsupported package manager. Please manually install the dependencies: git, podman, podman-compose, gnupg, pass, jq"
        exit 1
    fi

    log_info "Configuring unprivileged port access for ports 80 and 443..."
    sudo sysctl -w net.ipv4.ip_unprivileged_port_start=80
    echo "net.ipv4.ip_unprivileged_port_start=80" | sudo tee /etc/sysctl.d/99-podman-ports.conf > /dev/null

    log_info "2. Enabling and starting Podman user socket and restart service..."
    # Enable lingering to allow user services to run when not logged in
    sudo loginctl enable-linger "$(whoami)"
    systemctl --user daemon-reload
    systemctl --user enable --now podman.socket

    # Check if podman-restart.service exists before enabling
    log_info "Checking if podman-restart.service is registered for systemd user services..."
    if ! systemctl --user list-unit-files --type=service | grep -q "podman-restart"; then
        log_error "podman-restart.service is missing or not registered for systemd user services."
        log_error "This service is required to auto-restart containers upon system reboot."
        log_error "Please make sure Podman is installed correctly and user services are supported."
        exit 1
    fi
    systemctl --user enable --now podman-restart.service

    # Verify socket status (with wait/retry loop)
    SOCKET_PATH="/run/user/$(id -u)/podman/podman.sock"
    local socket_attempts=10
    local socket_wait=1
    log_info "Waiting for Podman user socket to become active at $SOCKET_PATH..."
    for ((i=1; i<=socket_attempts; i++)); do
        if [ -S "$SOCKET_PATH" ]; then
            log_success "Podman user socket is active at $SOCKET_PATH."
            break
        fi
        if [ "$i" -eq "$socket_attempts" ]; then
            log_warn "Timeout: Podman socket not found or not active at $SOCKET_PATH after ${socket_attempts}s."
            log_warn "Traefik might fail to dynamically discover containers until the socket is active."
        else
            sleep "$socket_wait"
        fi
    done

    log_info "3. Creating directory structure at $INFRA_DIR..."
    sudo mkdir -p "$INFRA_DIR/letsencrypt"
    # Change ownership to current user so compose/podman runs rootless
    sudo chown -R "$(id -u):$(id -g)" "$INFRA_DIR"

    # Create acme.json with strict permissions
    touch "$INFRA_DIR/letsencrypt/acme.json"
    chmod 600 "$INFRA_DIR/letsencrypt/acme.json"

    log_info "4. Configuring docker-compose and environment..."
    cat <<'EOF' > "$INFRA_DIR/docker-compose.yml"
services:
  traefik:
    image: docker.io/library/traefik:v2.10
    container_name: global_edge_router
    restart: unless-stopped
    command:
      # Provider Configuration
      - "--providers.docker=true"
      - "--providers.docker.exposedbydefault=false"
      - "--providers.docker.endpoint=unix:///var/run/docker.sock"
      
      # Entrypoints (Ports)
      - "--entrypoints.web.address=:80"
      - "--entrypoints.websecure.address=:443"
      - "--entrypoints.websecure.http.tls.certResolver=letsencryptresolver"
      
      # Automatic HTTP to HTTPS Redirection
      - "--entrypoints.web.http.redirections.entryPoint.to=websecure"
      - "--entrypoints.web.http.redirections.entryPoint.scheme=https"
      
      # Automated SSL Certificate Generation (Let's Encrypt)
      - "--certificatesresolvers.letsencryptresolver.acme.tlschallenge=true"
      - "--certificatesresolvers.letsencryptresolver.acme.email=${LETSENCRYPT_EMAIL}"
      - "--certificatesresolvers.letsencryptresolver.acme.storage=/letsencrypt/acme.json"
    ports:
      - "80:80"
      - "443:443"
    networks:
      - web_gateway
    volumes:
      # Map the system's user-level Podman socket to Traefik's expected Docker socket
      - "/run/user/${USER_UID}/podman/podman.sock:/var/run/docker.sock:ro"
      # Persist SSL certificates across container updates
      - "./letsencrypt:/letsencrypt"
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.global-tls.rule=Host(`${APP_DOMAIN}`)"
      - "traefik.http.routers.global-tls.entrypoints=websecure"
      - "traefik.http.routers.global-tls.tls.certresolver=letsencryptresolver"
      - "traefik.http.routers.global-tls.service=noop@internal"
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"

  mongo:
    image: docker.io/library/mongo:7.0
    container_name: shared_production_mongodb
    restart: unless-stopped
    environment:
      MONGO_INITDB_ROOT_USERNAME: ${MONGO_ROOT_USER}
      MONGO_INITDB_ROOT_PASSWORD: ${MONGO_ROOT_PASSWORD}
    volumes:
      - mongo_production_data:/data/db
    networks:
      - web_gateway
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"

volumes:
  mongo_production_data:

networks:
  web_gateway:
    external: true
EOF

    # Write .env file
    ENV_FILE="$INFRA_DIR/.env"
    cat <<EOF > "$ENV_FILE"
APP_DOMAIN="${APP_DOMAIN}"
LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL}"
USER_UID="$(id -u)"
MONGO_ROOT_USER="${MONGO_ROOT_USER}"
MONGO_ROOT_PASSWORD="${MONGO_ROOT_PASSWORD}"
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

    log_info "7. Verifying infrastructure services..."
    verify_container_running "global_edge_router"
    verify_container_running "shared_production_mongodb"
    verify_mongodb_ready

    log_success "Installation completed successfully!"
    log_success "Traefik and MongoDB are running rootless."
    echo -e "${YELLOW}MongoDB Root Credentials saved in $ENV_FILE${NC}"
}

do_uninstall() {
    # Check mandatory retention flag
    if [ -z "$UNINSTALL_APPS_ACTION" ]; then
        if [ "$NON_INTERACTIVE" = false ]; then
            log_warn "No application retention policy specified."
            echo "Select retention policy for deployed applications:"
            echo "  [1] Keep (retain all application databases, secrets, backups, and parameters)"
            echo "  [2] Destroy (completely purge all applications, parameters, secrets, databases, and backups)"
            read -r -p "Enter choice [1 or 2]: " RETENTION_CHOICE
            case "$RETENTION_CHOICE" in
                1)
                    UNINSTALL_APPS_ACTION="keep"
                    ;;
                2)
                    UNINSTALL_APPS_ACTION="destroy"
                    ;;
                *)
                    log_error "Invalid choice. Uninstall aborted."
                    exit 1
                    ;;
            esac
        else
            log_error "Missing mandatory uninstall flag: --keep-apps or --destroy-apps must be specified in non-interactive mode."
            show_command_help "$ACTION"
        fi
    fi

    if [ "$NON_INTERACTIVE" = false ]; then
        log_warn "This will stop services and delete configurations."
        read -r -p "Are you sure you want to uninstall? [y/N]: " CONFIRM
        if [[ ! "$CONFIRM" =~ ^[yY](es)?$ ]]; then
            log_info "Uninstall aborted."
            exit 0
        fi
    fi

    if [ "$UNINSTALL_APPS_ACTION" = "destroy" ]; then
        log_info "1. Completely destroying all deployed applications..."
        # Set destroy flags to delete all application components
        DESTROY_SECRETS="delete"
        DESTROY_PARAMS="delete"
        DESTROY_DATA="delete"
        DESTROY_BACKUPS="delete"
        export GLOBAL_UNINSTALL="true"
        
        declare -a APP_DESTROY_FAILURES=()
        for dir in /opt/*; do
            [ -d "$dir" ] || continue
            APP_DIR_NAME=$(basename "$dir")
            [ "$APP_DIR_NAME" = "web-infrastructure" ] && continue
            
            COMPOSE_PATH="$dir/docker-compose.prod.yml"
            if [ -f "$COMPOSE_PATH" ]; then
                log_info "Destroying application '$APP_DIR_NAME'..."
                if ! ( do_destroy_app "$APP_DIR_NAME" ); then
                    log_warn "Failed to fully destroy application '$APP_DIR_NAME'."
                    APP_DESTROY_FAILURES+=("$APP_DIR_NAME")
                fi
            fi
        done
        if [ ${#APP_DESTROY_FAILURES[@]} -gt 0 ]; then
            log_error "The following applications were not fully destroyed: ${APP_DESTROY_FAILURES[*]}"
        fi
    else
        log_info "1. Stopping all deployed applications (keeping configuration, data, secrets, and backups)..."
        for dir in /opt/*; do
            [ -d "$dir" ] || continue
            APP_DIR_NAME=$(basename "$dir")
            [ "$APP_DIR_NAME" = "web-infrastructure" ] && continue
            
            COMPOSE_PATH="$dir/docker-compose.prod.yml"
            if [ -f "$COMPOSE_PATH" ]; then
                log_info "Stopping application '$APP_DIR_NAME'..."
                (cd "$dir" && podman-compose -f docker-compose.prod.yml down) || true
            fi
        done
    fi

    log_info "2. Stopping infrastructure services..."
    if [ -f "$INFRA_DIR/docker-compose.yml" ]; then
        cd "$INFRA_DIR"
        if [ "$UNINSTALL_APPS_ACTION" = "destroy" ]; then
            log_info "Removing infrastructure containers and database volumes..."
            podman-compose down -v || true
        else
            podman-compose down || true
        fi
    else
        log_warn "docker-compose.yml not found at $INFRA_DIR, skipping service teardown."
    fi

    log_info "3. Removing network 'web_gateway'..."
    if podman network inspect web_gateway >/dev/null 2>&1; then
        podman network rm web_gateway || true
    fi

    if [ "$UNINSTALL_APPS_ACTION" = "destroy" ]; then
        log_info "4. Removing all registered secret files..."
        # Individual secret files are cleaned up in do_destroy_app loop
    else
        log_info "4. Keeping registered secret files intact."
    fi

    log_info "5. Disabling Podman user socket and restart services..."
    systemctl --user disable --now podman.socket || true
    systemctl --user disable --now podman-restart.service || true

    log_info "6. Cleaning up files..."
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
    APP_NAME=$(echo "$APP_NAME" | tr '[:upper:]' '[:lower:]' | tr '.' '-')
    # Ensure database name uses underscores instead of hyphens/periods
    DB_NAME=$(echo "$APP_NAME" | tr '-' '_' | tr '.' '_')_db
    APP_DB_USER="user_$(echo "$APP_NAME" | tr '-' '_' | tr '.' '_')"
    
    APP_DIR="/opt/$APP_NAME"
    ENV_FILE="$INFRA_DIR/.env"
    
    # Read database credentials from central .env
    if [ ! -f "$ENV_FILE" ]; then
        log_error "Central infrastructure is not installed or .env is missing. Run install first."
        exit 1
    fi
    
    # Extract root mongo credentials and APP_DOMAIN
    set +e
    MONGO_ROOT_USER=$(grep "^MONGO_ROOT_USER=" "$ENV_FILE" | cut -d= -f2- | tr -d '\r' | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")
    MONGO_ROOT_PASSWORD=$(grep "^MONGO_ROOT_PASSWORD=" "$ENV_FILE" | cut -d= -f2- | tr -d '\r' | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")
    APP_DOMAIN=$(grep "^APP_DOMAIN=" "$ENV_FILE" | cut -d= -f2- | tr -d '\r' | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")
    set -e
    
    if [ -z "$MONGO_ROOT_USER" ] || [ -z "$MONGO_ROOT_PASSWORD" ]; then
        log_error "Failed to retrieve MongoDB root credentials from $ENV_FILE."
        exit 1
    fi
    if [ -z "$APP_DOMAIN" ]; then
        log_error "Failed to retrieve APP_DOMAIN from $ENV_FILE."
        exit 1
    fi

    # --- Leftovers Verification & Handling ---
    local parameters_exist=false
    local secrets_exist=false
    local data_exist=false

    # Check parameters leftover
    if [ -d "$APP_DIR" ] && ( [ -f "$APP_DIR/docker-compose.prod.yml" ] || [ -f "$APP_DIR/.env.production" ] ); then
        parameters_exist=true
    fi

    # Check secrets leftover
    if [ -d "$APP_DIR/secrets" ]; then
        secrets_exist=true
    fi

    # Check data leftover
    if podman ps --format "{{.Names}}" | grep -q "^shared_production_mongodb$"; then
        verify_mongodb_ready
        local mongo_check
        mongo_check=$(podman exec -i \
            -e DB_NAME="${DB_NAME}" \
            -e APP_DB_USER="${APP_DB_USER}" \
            shared_production_mongodb mongosh \
            -u "$MONGO_ROOT_USER" \
            -p "$MONGO_ROOT_PASSWORD" \
            --authenticationDatabase admin \
            --quiet \
            --eval "
                var dbName = process.env.DB_NAME;
                var userExists = db.getSiblingDB(dbName).getUser(process.env.APP_DB_USER) !== null;
                var dbExists = false;
                try {
                    var dbList = db.adminCommand('listDatabases').databases;
                    for (var i = 0; i < dbList.length; i++) {
                        if (dbList[i].name === dbName) { dbExists = true; break; }
                    }
                } catch (e) {
                    dbExists = userExists;
                }
                print(userExists + ',' + dbExists);
            " 2>/dev/null | grep -E '^(true|false),(true|false)' | tr -d '[:space:]')
        if [ -z "$mongo_check" ]; then
            mongo_check="false,false"
        fi
        
        local user_exists="${mongo_check%%,*}"
        local db_exists="${mongo_check#*,}"
        if [ "$user_exists" = "true" ] || [ "$db_exists" = "true" ]; then
            data_exist=true
        fi
    fi

    # Enforce flags
    local validation_failed=false
    if [ "$parameters_exist" = true ] && [ "$USE_EXISTING_PARAMS" = false ] && [ "$DISREGARD_EXISTING_PARAMS" = false ]; then
        log_error "Leftover workspace parameters detected at $APP_DIR."
        log_error "Please re-run with either --use-existing-parameters or --disregard-existing-parameters."
        validation_failed=true
    fi
    if [ "$secrets_exist" = true ] && [ "$USE_EXISTING_SECRETS" = false ] && [ "$DISREGARD_EXISTING_SECRETS" = false ]; then
        log_error "Leftover Podman secrets detected for application '$APP_NAME'."
        log_error "Please re-run with either --use-existing-secrets or --disregard-existing-secrets."
        validation_failed=true
    fi
    if [ "$data_exist" = true ] && [ "$USE_EXISTING_DATA" = false ] && [ "$DISREGARD_EXISTING_DATA" = false ]; then
        log_error "Leftover database data or user detected in MongoDB for database '$DB_NAME'."
        log_error "Please re-run with either --use-existing-data or --disregard-existing-data."
        validation_failed=true
    fi

    if [ "$validation_failed" = true ]; then
        exit 1
    fi

    # Execute Leftovers Cleanup or Preparation
    if [ "$parameters_exist" = true ] && [ "$DISREGARD_EXISTING_PARAMS" = true ]; then
        log_info "Cleaning up existing configuration parameters in '$APP_DIR'..."
        if [ -d "$APP_DIR/backups" ]; then
            sudo find "$APP_DIR" -mindepth 1 -maxdepth 1 ! -name "backups" -exec rm -rf {} +
        else
            sudo rm -rf "$APP_DIR"
        fi
    fi

    if [ "$secrets_exist" = true ] && [ "$DISREGARD_EXISTING_SECRETS" = true ]; then
        log_info "Cleaning up existing secrets..."
        sudo rm -rf "$APP_DIR/secrets"
    fi

    if [ "$data_exist" = true ] && [ "$DISREGARD_EXISTING_DATA" = true ]; then
        log_info "Dropping existing database and user from MongoDB..."
        podman exec -i \
            -e DB_NAME="${DB_NAME}" \
            -e APP_DB_USER="${APP_DB_USER}" \
            shared_production_mongodb mongosh \
            -u "$MONGO_ROOT_USER" \
            -p "$MONGO_ROOT_PASSWORD" \
            --authenticationDatabase admin \
            --eval "
                db = db.getSiblingDB(process.env.DB_NAME);
                try { db.dropUser(process.env.APP_DB_USER); } catch (e) {}
                try { db.dropDatabase(); } catch (e) {}
            " >/dev/null
    fi

    # --- Pre-Flight Contract Verification ---
    log_info "1. Pulling container image to inspect contract: ${IMAGE}..."
    podman pull "$IMAGE" >/dev/null

    log_info "2. Inspecting application contract..."
    SPEC_OUTPUT=$(verify_container_contract "$IMAGE" "Application contract validation failed: Image does not support --show-spec or is invalid.")

    REQ_PARAMS_STR=$(echo "$SPEC_OUTPUT" | grep "^REQUIRED_PARAMETERS=" | cut -d= -f2- | tr -d '\r' | tr -d '[:space:]')
    REQ_SECRETS_STR=$(echo "$SPEC_OUTPUT" | grep "^REQUIRED_SECRETS=" | cut -d= -f2- | tr -d '\r' | tr -d '[:space:]')

    # Merge/Clear Parameters & Limits
    declare -A MERGED_PARAMS
    ACTIVE_CPUS=""
    ACTIVE_MEM=""

    if [ "$parameters_exist" = true ] && [ "$USE_EXISTING_PARAMS" = true ] && [ -f "$APP_DIR/.env.production" ]; then
        log_info "Reusing existing parameters..."
        while IFS= read -r line || [ -n "$line" ]; do
            line=$(echo "$line" | tr -d '\r')
            [[ "$line" =~ ^[[:space:]]*# ]] && continue
            [[ "$line" =~ ^[[:space:]]*$ ]] && continue
            if [[ "$line" != *=* ]]; then continue; fi
            
            KEY="${line%%=*}"
            VAL="${line#*=}"
            # Trim leading/trailing whitespace
            KEY="${KEY#"${KEY%%[![:space:]]*}"}"
            KEY="${KEY%"${KEY##*[![:space:]]}"}"
            VAL="${VAL#"${VAL%%[![:space:]]*}"}"
            VAL="${VAL%"${VAL##*[![:space:]]}"}"
            
            if [ "$KEY" != "PORT" ] && [ "$KEY" != "APP_ENV" ] && [ "$KEY" != "APP_DOMAIN" ] && [ "$KEY" != "APP_CPUS" ] && [ "$KEY" != "APP_MEM_LIMIT" ]; then
                MERGED_PARAMS["$KEY"]="$VAL"
            fi
        done < "$APP_DIR/.env.production"

        set +e
        ENV_CPUS=$(grep "^APP_CPUS=" "$APP_DIR/.env.production" | cut -d= -f2-)
        ENV_MEM=$(grep "^APP_MEM_LIMIT=" "$APP_DIR/.env.production" | cut -d= -f2-)
        set -e
        if [ -n "$ENV_CPUS" ]; then ACTIVE_CPUS="$ENV_CPUS"; fi
        if [ -n "$ENV_MEM" ]; then ACTIVE_MEM="$ENV_MEM"; fi
    fi

    # Add new CLI parameter inputs
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
    if [ "$secrets_exist" = true ] && [ "$USE_EXISTING_SECRETS" = true ] && [ -d "$APP_DIR/secrets" ]; then
        log_info "Reusing existing secrets..."
        for s_file in "$APP_DIR/secrets"/*; do
            [ -f "$s_file" ] || continue
            KEY=$(basename "$s_file")
            if [ "$KEY" != "MONGO_URI" ]; then
                MAPPED_SECRETS["$KEY"]="true"
            fi
        done
    fi

    # Write new app-specific secrets to disk
    if [ ${#APP_SECRETS[@]} -gt 0 ] || [ -n "$SCOPED_MONGO_URI" ]; then
        sudo mkdir -p "$APP_DIR/secrets"
        sudo chown -R "$(id -u):$(id -g)" "$APP_DIR/secrets"
        chmod 700 "$APP_DIR/secrets"
    fi

    for secret in "${APP_SECRETS[@]}"; do
        KEY="${secret%%=*}"
        VAL="${secret#*=}"
        
        log_info "Registering secret '$KEY'..."
        printf "%s" "$VAL" > "$APP_DIR/secrets/$KEY"
        chmod 600 "$APP_DIR/secrets/$KEY"
        MAPPED_SECRETS["$KEY"]="true"
    done

    # Validate parameters
    IFS=',' read -ra REQ_PARAMS <<< "$REQ_PARAMS_STR"
    MISSING_PARAMS=()
    for req in "${REQ_PARAMS[@]}"; do
        [ -z "$req" ] && continue
        if [[ "$req" =~ ^(PORT|APP_ENV|APP_DOMAIN)$ ]]; then
            continue
        fi
        if [ -z "${MERGED_PARAMS[$req]}" ]; then
            MISSING_PARAMS+=("$req")
        fi
    done

    # Validate secrets
    IFS=',' read -ra REQ_SECRETS <<< "$REQ_SECRETS_STR"
    MISSING_SECRETS=()
    for req in "${REQ_SECRETS[@]}"; do
        [ -z "$req" ] && continue
        if [ "$req" = "MONGO_URI" ]; then
            continue
        fi
        if [ ! -f "$APP_DIR/secrets/$req" ]; then
            MISSING_SECRETS+=("$req")
        else
            MAPPED_SECRETS["$req"]="true"
        fi
    done

    # Fail fast if requirements are missing
    if [ ${#MISSING_PARAMS[@]} -gt 0 ] || [ ${#MISSING_SECRETS[@]} -gt 0 ]; then
        log_error "Pre-flight contract verification failed! Missing mandatory configurations."
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
    log_success "Pre-flight contract verification passed."

    log_info "Creating application workspace..."
    echo -e "  App Name:   ${YELLOW}${APP_NAME}${NC}"
    echo -e "  Image:      ${YELLOW}${IMAGE}${NC}"
    echo -e "  Prefix:     ${YELLOW}/${APP_NAME}${NC}"
    echo -e "  DB Name:    ${YELLOW}${DB_NAME}${NC}"
    echo -e "  Directory:  ${YELLOW}${APP_DIR}${NC}"
    echo -e "  Domain:     ${YELLOW}${APP_DOMAIN}${NC}"
    echo ""

    # Generate unique scoped DB credentials or retrieve existing ones
    APP_DB_PASSWORD=""
    SCOPED_MONGO_URI=""

    if [ "$secrets_exist" = true ] && [ "$USE_EXISTING_SECRETS" = true ] && [ -f "$APP_DIR/secrets/MONGO_URI" ]; then
        log_info "Reading connection URI from existing secret file..."
        SCOPED_MONGO_URI=$(cat "$APP_DIR/secrets/MONGO_URI" 2>/dev/null || true)
        
        if [ -z "$SCOPED_MONGO_URI" ]; then
            log_error "Failed to retrieve connection URI from existing secret file."
            exit 1
        fi
        
        # Extract user and password from connection URI
        local uri_no_proto="${SCOPED_MONGO_URI#mongodb://}"
        local credentials="${uri_no_proto%%@*}"
        APP_DB_USER="${credentials%%:*}"
        APP_DB_PASSWORD="${credentials#*:}"
    else
        APP_DB_PASSWORD=$(openssl rand -hex 16 2>/dev/null || gpg --gen-random --armor 1 16 2>/dev/null || dd if=/dev/urandom bs=1 count=16 2>/dev/null | od -An -vtx1 | tr -d ' \n' || echo "AppPass$(date +%s%N)")
        SCOPED_MONGO_URI="mongodb://${APP_DB_USER}:${APP_DB_PASSWORD}@shared_production_mongodb:27017/${DB_NAME}?authSource=${DB_NAME}"
    fi

    # Create/update user in MongoDB
    if ! podman ps --format "{{.Names}}" | grep -q "^shared_production_mongodb$"; then
        log_error "MongoDB container 'shared_production_mongodb' is not running. Start infrastructure first."
        exit 1
    fi

    verify_mongodb_ready

    log_info "Provisioning/updating isolated database user '${APP_DB_USER}'..."
    podman exec -i \
        -e DB_NAME="${DB_NAME}" \
        -e APP_DB_USER="${APP_DB_USER}" \
        -e APP_DB_PASSWORD="${APP_DB_PASSWORD}" \
        shared_production_mongodb mongosh \
        -u "$MONGO_ROOT_USER" \
        -p "$MONGO_ROOT_PASSWORD" \
        --authenticationDatabase admin \
        --eval "
            db = db.getSiblingDB(process.env.DB_NAME);
            const dbUser = process.env.APP_DB_USER;
            const dbPassword = process.env.APP_DB_PASSWORD;
            if (!db.getUser(dbUser)) {
                db.createUser({
                    user: dbUser,
                    pwd: dbPassword,
                    roles: [{ role: 'readWrite', db: process.env.DB_NAME }]
                });
            } else {
                db.changeUserPassword(dbUser, dbPassword);
            }
        " >/dev/null

    log_info "Storing database connection string as a secret file..."
    sudo mkdir -p "$APP_DIR/secrets"
    sudo chown -R "$(id -u):$(id -g)" "$APP_DIR/secrets"
    chmod 700 "$APP_DIR/secrets"
    printf "%s" "$SCOPED_MONGO_URI" > "$APP_DIR/secrets/MONGO_URI"
    chmod 600 "$APP_DIR/secrets/MONGO_URI"

    # Create directory and assign permissions to current user
    sudo mkdir -p "$APP_DIR"
    sudo chown -R "$(id -u):$(id -g)" "$APP_DIR"

    # Write .env.production
    cat <<EOF > "$APP_DIR/.env.production"
PORT=3000
APP_ENV=production
APP_DOMAIN=${APP_DOMAIN}
EOF

    if [ -n "$ACTIVE_CPUS" ]; then
        echo "APP_CPUS=${ACTIVE_CPUS}" >> "$APP_DIR/.env.production"
    fi
    if [ -n "$ACTIVE_MEM" ]; then
        echo "APP_MEM_LIMIT=${ACTIVE_MEM}" >> "$APP_DIR/.env.production"
    fi

    # Write any app-specific parameters
    if [ ${#MERGED_PARAMS[@]} -gt 0 ]; then
        echo "" >> "$APP_DIR/.env.production"
        echo "# App-specific parameters" >> "$APP_DIR/.env.production"
        for key in "${!MERGED_PARAMS[@]}"; do
            echo "$key=${MERGED_PARAMS[$key]}" >> "$APP_DIR/.env.production"
        done
    fi
    chmod 600 "$APP_DIR/.env.production"

    # Generate docker-compose secrets sections dynamically
    SERVICES_SECRETS_SECTION="    secrets:\n      - MONGO_URI"
    GLOBAL_SECRETS_SECTION="secrets:\n  MONGO_URI:\n    file: ./secrets/MONGO_URI"

    for key in "${!MAPPED_SECRETS[@]}"; do
        SERVICES_SECRETS_SECTION="${SERVICES_SECRETS_SECTION}\n      - ${key}"
        GLOBAL_SECRETS_SECTION="${GLOBAL_SECRETS_SECTION}\n  ${key}:\n    file: ./secrets/${key}"
    done

    # Write docker-compose.prod.yml
    COMPOSE_FILE="$APP_DIR/docker-compose.prod.yml"
    cat <<EOF > "$COMPOSE_FILE"
# WARNING: THIS FILE IS AUTOGENERATED BY appSqueezer.sh
# ANY MANUAL CHANGES MADE TO THIS FILE WILL BE OVERWRITTEN
# DURING RECONFIGURATIONS, UPDATES, OR REDEPLOYMENTS.

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
    printf "%b\n" "$SERVICES_SECRETS_SECTION" >> "$COMPOSE_FILE"

    # Append Traefik routing labels
    cat <<EOF >> "$COMPOSE_FILE"
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.${APP_NAME}.rule=Host(\`${APP_DOMAIN}\`) && PathPrefix(\`/${APP_NAME}\`)"
      - "traefik.http.routers.${APP_NAME}.entrypoints=websecure"
      - "traefik.http.routers.${APP_NAME}.tls=true"
      - "traefik.http.routers.${APP_NAME}.tls.certresolver=letsencryptresolver"
      - "traefik.http.middlewares.${APP_NAME}-strip.stripprefix.prefixes=/${APP_NAME}"
      - "traefik.http.routers.${APP_NAME}.middlewares=${APP_NAME}-strip"
      - "traefik.http.services.${APP_NAME}.loadbalancer.server.port=3000"

EOF

    # Append global secrets definition
    printf "%b\n" "$GLOBAL_SECRETS_SECTION" >> "$COMPOSE_FILE"

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
    
    local app_count=0
    for dir in /opt/*; do
        [ -d "$dir" ] || continue
        APP_DIR_NAME=$(basename "$dir")
        [ "$APP_DIR_NAME" = "web-infrastructure" ] && continue
        
        COMPOSE_PATH="$dir/docker-compose.prod.yml"
        if [ -f "$COMPOSE_PATH" ]; then
            if [ $app_count -eq 0 ]; then
                printf "\n%-30s %-60s %-35s\n" "Application" "Route URL" "Container Status"
                printf "%-30s %-60s %-35s\n" "-----------" "---------" "----------------"
            fi
            
            ENV_PATH="$dir/.env.production"
            DOMAIN="unknown-domain"
            if [ -f "$ENV_PATH" ]; then
                DOMAIN=$(grep "^APP_DOMAIN=" "$ENV_PATH" | cut -d= -f2- | tr -d '\r' | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")
            fi
            
            ROUTE_URL="https://${DOMAIN}/${APP_DIR_NAME}"
            CONTAINER_NAME="app_${APP_DIR_NAME}_backend"
            STATUS=$(podman ps -a --filter "name=^${CONTAINER_NAME}$" --format "{{.Status}}" 2>/dev/null)
            
            if [ -z "$STATUS" ]; then
                STATUS="Not Found / Stopped"
            fi
            
            printf "%-30s %-60s %-35s\n" "$APP_DIR_NAME" "$ROUTE_URL" "$STATUS"
            app_count=$((app_count + 1))
        fi
    done
    
    if [ $app_count -eq 0 ]; then
        log_info "No deployed applications found."
    else
        echo ""
    fi
}

do_start() {
    local APP_NAME
    APP_NAME=$(echo "$1" | tr '[:upper:]' '[:lower:]' | tr '.' '-')
    local APP_DIR="/opt/$APP_NAME"
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
    local APP_NAME
    APP_NAME=$(echo "$1" | tr '[:upper:]' '[:lower:]' | tr '.' '-')
    local APP_DIR="/opt/$APP_NAME"
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
    local APP_NAME
    APP_NAME=$(echo "$1" | tr '[:upper:]' '[:lower:]' | tr '.' '-')
    local APP_DIR="/opt/$APP_NAME"
    if [ ! -d "$APP_DIR" ] || [ ! -f "$APP_DIR/docker-compose.prod.yml" ]; then
        log_error "Application '$APP_NAME' is not deployed or missing docker-compose.prod.yml."
        exit 1
    fi
    log_info "Restarting application '$APP_NAME' (recreating containers to apply configuration updates)..."
    cd "$APP_DIR"
    podman-compose -f docker-compose.prod.yml down
    podman-compose -f docker-compose.prod.yml up -d
    log_success "Application '$APP_NAME' restarted."
}

do_logs() {
    local APP_NAME
    APP_NAME=$(echo "$1" | tr '[:upper:]' '[:lower:]' | tr '.' '-')
    shift
    local APP_DIR="/opt/$APP_NAME"
    if [ ! -d "$APP_DIR" ] || [ ! -f "$APP_DIR/docker-compose.prod.yml" ]; then
        log_error "Application '$APP_NAME' is not deployed or missing docker-compose.prod.yml."
        exit 1
    fi
    cd "$APP_DIR"
    podman-compose -f docker-compose.prod.yml logs "$@"
}

do_configure() {
    local APP_NAME APP_DIR ENV_FILE APP_DOMAIN IMAGE
    APP_NAME=$(echo "$1" | tr '[:upper:]' '[:lower:]' | tr '.' '-')
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
    APP_DOMAIN=$(grep "^APP_DOMAIN=" "$ENV_FILE" | cut -d= -f2- | tr -d '\r' | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")
    set -e
    if [ -z "$APP_DOMAIN" ]; then
        log_error "Failed to retrieve APP_DOMAIN from $ENV_FILE."
        exit 1
    fi

    IMAGE=$(grep "image:" "$APP_DIR/docker-compose.prod.yml" | head -n 1 | awk '{print $2}')
    IMAGE=$(echo "$IMAGE" | tr -d '"'\')
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
            # Trim leading/trailing whitespace
            KEY="${KEY#"${KEY%%[![:space:]]*}"}"
            KEY="${KEY%"${KEY##*[![:space:]]}"}"
            VAL="${VAL#"${VAL%%[![:space:]]*}"}"
            VAL="${VAL%"${VAL##*[![:space:]]}"}"
            
            if [ "$KEY" != "PORT" ] && [ "$KEY" != "APP_ENV" ] && [ "$KEY" != "APP_DOMAIN" ] && [ "$KEY" != "APP_CPUS" ] && [ "$KEY" != "APP_MEM_LIMIT" ]; then
                MERGED_PARAMS["$KEY"]="$VAL"
            fi
        done < "$APP_DIR/.env.production"
    fi

    if [ "$CLEAR_LIMITS" = false ] && [ -f "$APP_DIR/.env.production" ]; then
        set +e
        ENV_CPUS=$(grep "^APP_CPUS=" "$APP_DIR/.env.production" | cut -d= -f2-)
        ENV_MEM=$(grep "^APP_MEM_LIMIT=" "$APP_DIR/.env.production" | cut -d= -f2-)
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
    if [ "$CLEAR_SECRETS" = false ] && [ -d "$APP_DIR/secrets" ]; then
        for s_file in "$APP_DIR/secrets"/*; do
            [ -f "$s_file" ] || continue
            KEY=$(basename "$s_file")
            if [ "$KEY" != "MONGO_URI" ]; then
                MAPPED_SECRETS["$KEY"]="true"
            fi
        done
    fi

    if [ "$CLEAR_SECRETS" = true ]; then
        log_info "Clearing existing secrets for application '$APP_NAME'..."
        if [ -d "$APP_DIR/secrets" ]; then
            find "$APP_DIR/secrets" -mindepth 1 ! -name "MONGO_URI" -delete
        fi
    fi

    if [ ${#APP_SECRETS[@]} -gt 0 ]; then
        sudo mkdir -p "$APP_DIR/secrets"
        sudo chown -R "$(id -u):$(id -g)" "$APP_DIR/secrets"
        chmod 700 "$APP_DIR/secrets"
    fi

    for secret in "${APP_SECRETS[@]}"; do
        KEY="${secret%%=*}"
        VAL="${secret#*=}"
        
        log_info "Registering secret '$KEY'..."
        printf "%s" "$VAL" > "$APP_DIR/secrets/$KEY"
        chmod 600 "$APP_DIR/secrets/$KEY"
        MAPPED_SECRETS["$KEY"]="true"
    done

    # Pre-Flight Contract Verification
    SPEC_OUTPUT=$(verify_container_contract "$IMAGE" "Application contract validation failed: Image does not support --show-spec or is invalid.")

    REQ_PARAMS_STR=$(echo "$SPEC_OUTPUT" | grep "^REQUIRED_PARAMETERS=" | cut -d= -f2- | tr -d '\r' | tr -d '[:space:]')
    REQ_SECRETS_STR=$(echo "$SPEC_OUTPUT" | grep "^REQUIRED_SECRETS=" | cut -d= -f2- | tr -d '\r' | tr -d '[:space:]')

    # Validate parameters
    IFS=',' read -ra REQ_PARAMS <<< "$REQ_PARAMS_STR"
    MISSING_PARAMS=()
    for req in "${REQ_PARAMS[@]}"; do
        [ -z "$req" ] && continue
        if [[ "$req" =~ ^(PORT|APP_ENV|APP_DOMAIN)$ ]]; then
            continue
        fi
        if [ -z "${MERGED_PARAMS[$req]}" ]; then
            MISSING_PARAMS+=("$req")
        fi
    done

    # Validate secrets
    IFS=',' read -ra REQ_SECRETS <<< "$REQ_SECRETS_STR"
    MISSING_SECRETS=()
    for req in "${REQ_SECRETS[@]}"; do
        [ -z "$req" ] && continue
        if [ "$req" = "MONGO_URI" ]; then
            continue
        fi
        if [ ! -f "$APP_DIR/secrets/$req" ]; then
            MISSING_SECRETS+=("$req")
        else
            MAPPED_SECRETS["$req"]="true"
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
APP_ENV=production
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
    SERVICES_SECRETS_SECTION="    secrets:\n      - MONGO_URI"
    GLOBAL_SECRETS_SECTION="secrets:\n  MONGO_URI:\n    file: ./secrets/MONGO_URI"

    for key in "${!MAPPED_SECRETS[@]}"; do
        SERVICES_SECRETS_SECTION="${SERVICES_SECRETS_SECTION}\n      - ${key}"
        GLOBAL_SECRETS_SECTION="${GLOBAL_SECRETS_SECTION}\n  ${key}:\n    file: ./secrets/${key}"
    done

    # Write docker-compose.prod.yml
    COMPOSE_FILE="$APP_DIR/docker-compose.prod.yml"
    cat <<EOF > "$COMPOSE_FILE"
# WARNING: THIS FILE IS AUTOGENERATED BY appSqueezer.sh
# ANY MANUAL CHANGES MADE TO THIS FILE WILL BE OVERWRITTEN
# DURING RECONFIGURATIONS, UPDATES, OR REDEPLOYMENTS.

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

    printf "%b\n" "$SERVICES_SECRETS_SECTION" >> "$COMPOSE_FILE"

    cat <<EOF >> "$COMPOSE_FILE"
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.${APP_NAME}.rule=Host(\`${APP_DOMAIN}\`) && PathPrefix(\`/${APP_NAME}\`)"
      - "traefik.http.routers.${APP_NAME}.entrypoints=websecure"
      - "traefik.http.routers.${APP_NAME}.tls=true"
      - "traefik.http.routers.${APP_NAME}.tls.certresolver=letsencryptresolver"
      - "traefik.http.middlewares.${APP_NAME}-strip.stripprefix.prefixes=/${APP_NAME}"
      - "traefik.http.routers.${APP_NAME}.middlewares=${APP_NAME}-strip"
      - "traefik.http.services.${APP_NAME}.loadbalancer.server.port=3000"

EOF

    printf "%b\n" "$GLOBAL_SECRETS_SECTION" >> "$COMPOSE_FILE"

    cat <<EOF >> "$COMPOSE_FILE"

networks:
  web_gateway:
    external: true
EOF

    log_success "Configuration updated successfully!"
    log_success "Run './appSqueezer.sh restart $APP_NAME' to apply changes."
}

do_update() {
    local APP_NAME NEW_IMAGE APP_DIR ENV_FILE IMAGE
    APP_NAME=$(echo "$1" | tr '[:upper:]' '[:lower:]' | tr '.' '-')
    NEW_IMAGE="$2"
    APP_DIR="/opt/$APP_NAME"
    ENV_FILE="$INFRA_DIR/.env"
    
    if [ ! -d "$APP_DIR" ] || [ ! -f "$APP_DIR/docker-compose.prod.yml" ]; then
        log_error "Application '$APP_NAME' is not deployed or missing docker-compose.prod.yml."
        exit 1
    fi

    # Read APP_DOMAIN from central .env
    if [ ! -f "$ENV_FILE" ]; then
        log_error "Central infrastructure is not installed or .env is missing. Run install first."
        exit 1
    fi
    set +e
    APP_DOMAIN=$(grep "^APP_DOMAIN=" "$ENV_FILE" | cut -d= -f2- | tr -d '\r' | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")
    set -e
    if [ -z "$APP_DOMAIN" ]; then
        log_error "Failed to retrieve APP_DOMAIN from $ENV_FILE."
        exit 1
    fi
    
    # Resolve image to pull
    if [ -n "$NEW_IMAGE" ]; then
        IMAGE="$NEW_IMAGE"
    else
        IMAGE=$(grep "image:" "$APP_DIR/docker-compose.prod.yml" | head -n 1 | awk '{print $2}')
    fi
    IMAGE=$(echo "$IMAGE" | tr -d '"'\')
    
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
            # Trim leading/trailing whitespace
            KEY="${KEY#"${KEY%%[![:space:]]*}"}"
            KEY="${KEY%"${KEY##*[![:space:]]}"}"
            VAL="${VAL#"${VAL%%[![:space:]]*}"}"
            VAL="${VAL%"${VAL##*[![:space:]]}"}"
            
            if [ "$KEY" != "PORT" ] && [ "$KEY" != "APP_ENV" ] && [ "$KEY" != "APP_DOMAIN" ] && [ "$KEY" != "APP_CPUS" ] && [ "$KEY" != "APP_MEM_LIMIT" ]; then
                MERGED_PARAMS["$KEY"]="$VAL"
            fi
        done < "$APP_DIR/.env.production"

        set +e
        ENV_CPUS=$(grep "^APP_CPUS=" "$APP_DIR/.env.production" | cut -d= -f2-)
        ENV_MEM=$(grep "^APP_MEM_LIMIT=" "$APP_DIR/.env.production" | cut -d= -f2-)
        set -e
        if [ -n "$ENV_CPUS" ]; then ACTIVE_CPUS="$ENV_CPUS"; fi
        if [ -n "$ENV_MEM" ]; then ACTIVE_MEM="$ENV_MEM"; fi
    fi
    
    declare -A MAPPED_SECRETS
    if [ -d "$APP_DIR/secrets" ]; then
        for s_file in "$APP_DIR/secrets"/*; do
            [ -f "$s_file" ] || continue
            KEY=$(basename "$s_file")
            if [ "$KEY" != "MONGO_URI" ]; then
                MAPPED_SECRETS["$KEY"]="true"
            fi
        done
    fi
    
    log_info "2. Inspecting contract of new image..."
    SPEC_OUTPUT=$(verify_container_contract "$IMAGE" "Pre-flight contract verification failed for the updated image!")

    REQ_PARAMS_STR=$(echo "$SPEC_OUTPUT" | grep "^REQUIRED_PARAMETERS=" | cut -d= -f2- | tr -d '\r' | tr -d '[:space:]')
    REQ_SECRETS_STR=$(echo "$SPEC_OUTPUT" | grep "^REQUIRED_SECRETS=" | cut -d= -f2- | tr -d '\r' | tr -d '[:space:]')

    # Validate parameters
    IFS=',' read -ra REQ_PARAMS <<< "$REQ_PARAMS_STR"
    MISSING_PARAMS=()
    for req in "${REQ_PARAMS[@]}"; do
        [ -z "$req" ] && continue
        if [[ "$req" =~ ^(PORT|APP_ENV|APP_DOMAIN)$ ]]; then
            continue
        fi
        if [ -z "${MERGED_PARAMS[$req]}" ]; then
            MISSING_PARAMS+=("$req")
        fi
    done

    # Validate secrets
    IFS=',' read -ra REQ_SECRETS <<< "$REQ_SECRETS_STR"
    MISSING_SECRETS=()
    for req in "${REQ_SECRETS[@]}"; do
        [ -z "$req" ] && continue
        if [ "$req" = "MONGO_URI" ]; then
            continue
        fi
        if [ ! -f "$APP_DIR/secrets/$req" ]; then
            MISSING_SECRETS+=("$req")
        else
            MAPPED_SECRETS["$req"]="true"
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
    SERVICES_SECRETS_SECTION="    secrets:\n      - MONGO_URI"
    GLOBAL_SECRETS_SECTION="secrets:\n  MONGO_URI:\n    file: ./secrets/MONGO_URI"

    for key in "${!MAPPED_SECRETS[@]}"; do
        SERVICES_SECRETS_SECTION="${SERVICES_SECRETS_SECTION}\n      - ${key}"
        GLOBAL_SECRETS_SECTION="${GLOBAL_SECRETS_SECTION}\n  ${key}:\n    file: ./secrets/${key}"
    done

    COMPOSE_FILE="$APP_DIR/docker-compose.prod.yml"
    cat <<EOF > "$COMPOSE_FILE"
# WARNING: THIS FILE IS AUTOGENERATED BY appSqueezer.sh
# ANY MANUAL CHANGES MADE TO THIS FILE WILL BE OVERWRITTEN
# DURING RECONFIGURATIONS, UPDATES, OR REDEPLOYMENTS.

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
    printf "%b\n" "$SERVICES_SECRETS_SECTION" >> "$COMPOSE_FILE"

    cat <<EOF >> "$COMPOSE_FILE"
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.${APP_NAME}.rule=Host(\`${APP_DOMAIN}\`) && PathPrefix(\`/${APP_NAME}\`)"
      - "traefik.http.routers.${APP_NAME}.entrypoints=websecure"
      - "traefik.http.routers.${APP_NAME}.tls=true"
      - "traefik.http.routers.${APP_NAME}.tls.certresolver=letsencryptresolver"
      - "traefik.http.middlewares.${APP_NAME}-strip.stripprefix.prefixes=/${APP_NAME}"
      - "traefik.http.routers.${APP_NAME}.middlewares=${APP_NAME}-strip"
      - "traefik.http.services.${APP_NAME}.loadbalancer.server.port=3000"

EOF

    printf "%b\n" "$GLOBAL_SECRETS_SECTION" >> "$COMPOSE_FILE"

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
    local APP_NAME
    APP_NAME=$(echo "$1" | tr '[:upper:]' '[:lower:]' | tr '.' '-')
    local APP_DIR="/opt/$APP_NAME"
    local ENV_FILE="$INFRA_DIR/.env"
    local MONGO_ROOT_USER
    local MONGO_ROOT_PASSWORD
    local APP_DB_USER
    local DB_NAME
    
    # Clean variable scoping with global defaults
    local local_destroy_secrets="${DESTROY_SECRETS:-keep}"
    local local_destroy_params="${DESTROY_PARAMS:-keep}"
    local local_destroy_data="${DESTROY_DATA:-keep}"
    local local_destroy_backups="${DESTROY_BACKUPS:-keep}"
    local is_global_uninstall="${GLOBAL_UNINSTALL:-false}"
    
    # 1. Stop container if it is running and workspace exists
    if [ -d "$APP_DIR" ] && [ -f "$APP_DIR/docker-compose.prod.yml" ]; then
        log_info "1. Halting container services for '$APP_NAME'..."
        (cd "$APP_DIR" && podman-compose -f docker-compose.prod.yml down) || true
    else
        log_warn "Application directory or compose file not found at $APP_DIR. Skipping service teardown."
    fi

    # 2. Handle Secrets cleanup
    if [ "$local_destroy_secrets" = "delete" ]; then
        if [ "$is_global_uninstall" = "true" ]; then
            log_info "2. Bypassing individual secret deletion (handled globally during uninstall)."
        else
            log_info "2. Deleting secret files..."
            sudo rm -rf "$APP_DIR/secrets"
            log_success "Secrets deleted."
        fi
    else
        log_info "2. Preserving secret files."
    fi

    # 3. Handle Data cleanup (database drop and user drop)
    if [ "$local_destroy_data" = "delete" ]; then
        if [ "$is_global_uninstall" = "true" ]; then
            log_info "3. Bypassing database/user drops (handled globally by volume removal during uninstall)."
        else
            log_info "3. Dropping database and user from MongoDB..."
            if [ -f "$ENV_FILE" ]; then
                set +e
                MONGO_ROOT_USER=$(grep "^MONGO_ROOT_USER=" "$ENV_FILE" | cut -d= -f2- | tr -d '\r' | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")
                MONGO_ROOT_PASSWORD=$(grep "^MONGO_ROOT_PASSWORD=" "$ENV_FILE" | cut -d= -f2- | tr -d '\r' | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")
                set -e
                
                if [ -n "$MONGO_ROOT_USER" ] && [ -n "$MONGO_ROOT_PASSWORD" ]; then
                    if ! podman ps --format "{{.Names}}" | grep -q "^shared_production_mongodb$"; then
                        log_warn "MongoDB container 'shared_production_mongodb' is not running. Skipping database cleanup."
                    else
                        verify_mongodb_ready
                        APP_DB_USER="user_$(echo "$APP_NAME" | tr '-' '_' | tr '.' '_')"
                        DB_NAME=$(echo "$APP_NAME" | tr '-' '_' | tr '.' '_')_db
                        
                        set +e
                        podman exec -i \
                            -e DB_NAME="${DB_NAME}" \
                            -e APP_DB_USER="${APP_DB_USER}" \
                            shared_production_mongodb mongosh \
                            -u "$MONGO_ROOT_USER" \
                            -p "$MONGO_ROOT_PASSWORD" \
                            --authenticationDatabase admin \
                            --eval "
                                db = db.getSiblingDB(process.env.DB_NAME);
                                try { db.dropUser(process.env.APP_DB_USER); } catch (e) {}
                                try { db.dropDatabase(); } catch (e) {}
                            " >/dev/null
                        STATUS=$?
                        set -e
                        if [ $STATUS -eq 0 ]; then
                            log_success "Database '${DB_NAME}' and user '${APP_DB_USER}' dropped."
                        else
                            log_warn "Failed to drop database '${DB_NAME}' or user '${APP_DB_USER}' from MongoDB (or container is unreachable)."
                        fi
                    fi
                else
                    log_error "Could not retrieve root Mongo credentials. Skipping database cleanup."
                fi
            else
                log_error "Central infrastructure .env not found. Skipping database cleanup."
            fi
        fi
    else
        log_info "3. Preserving database data and user permissions."
    fi

    # 4. Handle Backups cleanup
    if [ "$local_destroy_backups" = "delete" ]; then
        if [ -d "$APP_DIR/backups" ]; then
            log_info "4. Deleting backups under '$APP_DIR/backups'..."
            sudo rm -rf "$APP_DIR/backups"
            log_success "Backups deleted."
        fi
    else
        log_info "4. Preserving backups under '$APP_DIR/backups'."
    fi

    # 5. Handle Parameters / Workspace cleanup
    if [ "$local_destroy_params" = "delete" ]; then
        local -a preserve_opts=()
        if [ "$local_destroy_backups" = "keep" ] && [ -d "$APP_DIR/backups" ]; then
            preserve_opts+=("backups")
        fi
        if [ "$local_destroy_secrets" = "keep" ] && [ -d "$APP_DIR/secrets" ]; then
            preserve_opts+=("secrets")
        fi

        if [ ${#preserve_opts[@]} -gt 0 ]; then
            log_info "5. Deleting application configurations inside '$APP_DIR' while preserving selected folders (${preserve_opts[*]})..."
            local find_cmd="sudo find \"$APP_DIR\" -mindepth 1 -maxdepth 1"
            for folder in "${preserve_opts[@]}"; do
                find_cmd="${find_cmd} ! -name \"${folder}\""
            done
            find_cmd="${find_cmd} -exec rm -rf {} +"
            eval "$find_cmd"
            log_success "Application configurations deleted, preserved: ${preserve_opts[*]}."
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
    local ENV_FILE MONGO_ROOT_USER MONGO_ROOT_PASSWORD APP_DIR TIMESTAMP DB_NAME BACKUP_DIR FILE_NAME BACKUP_FILE STATUS
    APP_NAME=$(echo "$APP_NAME" | tr '[:upper:]' '[:lower:]' | tr '.' '-')
    # Validate backup description to prevent path traversal and invalid filename characters
    if [ -n "$BACKUP_DESC" ] && [[ ! "$BACKUP_DESC" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        log_error "Invalid --description value: '$BACKUP_DESC'. Only alphanumeric characters, hyphens, and underscores are allowed."
        exit 1
    fi
    ENV_FILE="$INFRA_DIR/.env"
    if [ ! -f "$ENV_FILE" ]; then
        log_error "Central infrastructure is not installed or .env is missing. Run install first."
        exit 1
    fi
    set +e
    MONGO_ROOT_USER=$(grep "^MONGO_ROOT_USER=" "$ENV_FILE" | cut -d= -f2- | tr -d '\r' | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")
    MONGO_ROOT_PASSWORD=$(grep "^MONGO_ROOT_PASSWORD=" "$ENV_FILE" | cut -d= -f2- | tr -d '\r' | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")
    set -e
    if [ -z "$MONGO_ROOT_USER" ] || [ -z "$MONGO_ROOT_PASSWORD" ]; then
        log_error "Failed to retrieve MongoDB root credentials from $ENV_FILE."
        exit 1
    fi
    if ! podman ps --format "{{.Names}}" | grep -q "^shared_production_mongodb$"; then
        log_error "MongoDB container 'shared_production_mongodb' is not running."
        exit 1
    fi

    verify_mongodb_ready

    # Determine target applications
    declare -a TARGET_APPS=()
    if [ "$ALL_APPS" = true ]; then
        for d in /opt/*; do
            [ -d "$d" ] || continue
            APP_DIR_NAME=$(basename "$d")
            [ "$APP_DIR_NAME" = "web-infrastructure" ] && continue
            if [ -f "$d/docker-compose.prod.yml" ]; then
                TARGET_APPS+=("$APP_DIR_NAME")
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
    local ENV_FILE MONGO_ROOT_USER MONGO_ROOT_PASSWORD APP_DOMAIN TARGET_APPS BACKUP_FILES app BACKUP_DIR LATEST_FILE APP_DIR SAFE_BACKUP_NAME BACKUP_FILE DB_NAME SCOPED_MONGO_URI STATUS backup_file
    APP_NAME=$(echo "$APP_NAME" | tr '[:upper:]' '[:lower:]' | tr '.' '-')
    ENV_FILE="$INFRA_DIR/.env"
    if [ ! -f "$ENV_FILE" ]; then
        log_error "Central infrastructure is not installed or .env is missing. Run install first."
        exit 1
    fi
    set +e
    MONGO_ROOT_USER=$(grep "^MONGO_ROOT_USER=" "$ENV_FILE" | cut -d= -f2- | tr -d '\r' | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")
    MONGO_ROOT_PASSWORD=$(grep "^MONGO_ROOT_PASSWORD=" "$ENV_FILE" | cut -d= -f2- | tr -d '\r' | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")
    APP_DOMAIN=$(grep "^APP_DOMAIN=" "$ENV_FILE" | cut -d= -f2- | tr -d '\r' | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")
    set -e
    if [ -z "$MONGO_ROOT_USER" ] || [ -z "$MONGO_ROOT_PASSWORD" ]; then
        log_error "Failed to retrieve MongoDB root credentials from $ENV_FILE."
        exit 1
    fi
    if [ -z "$APP_DOMAIN" ]; then
        log_error "Failed to retrieve APP_DOMAIN from $ENV_FILE."
        exit 1
    fi
    if ! podman ps --format "{{.Names}}" | grep -q "^shared_production_mongodb$"; then
        log_error "MongoDB container 'shared_production_mongodb' is not running."
        exit 1
    fi

    verify_mongodb_ready

    # Determine target applications and backups
    declare -a TARGET_APPS=()
    declare -a BACKUP_FILES=()

    if [ "$ALL_APPS" = true ]; then
        for d in /opt/*; do
            [ -d "$d" ] || continue
            APP_DIR_NAME=$(basename "$d")
            [ "$APP_DIR_NAME" = "web-infrastructure" ] && continue
            if [ -f "$d/docker-compose.prod.yml" ]; then
                app="$APP_DIR_NAME"
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

        # 1.5. Ensure database user exists (self-healing after data wipe)
        local IMAGE
        IMAGE=$(grep "image:" "/opt/$app/docker-compose.prod.yml" | head -n 1 | awk '{print $2}')
        IMAGE=$(echo "$IMAGE" | tr -d '"'\')

        local SCOPED_MONGO_URI=""
        SCOPED_MONGO_URI=$(timeout 10 podman run --rm --entrypoint "" --secret "${app}_mongo_uri" docker.io/library/mongo:7.0 cat "/run/secrets/${app}_mongo_uri" 2>/dev/null || \
                           timeout 10 podman run --rm --entrypoint "" --secret "${app}_mongo_uri" "${IMAGE}" cat "/run/secrets/${app}_mongo_uri" 2>/dev/null || \
                           timeout 10 podman run --rm --entrypoint "" --secret "${app}_mongo_uri" docker.io/library/busybox:latest cat "/run/secrets/${app}_mongo_uri" 2>/dev/null || \
                           timeout 10 podman run --rm --entrypoint "" --secret "${app}_mongo_uri" docker.io/library/alpine:latest cat "/run/secrets/${app}_mongo_uri" 2>/dev/null || true)
        local app_db_user="user_$(echo "$app" | tr '-' '_' | tr '.' '_')"
        local app_db_password=""

        local credentials_regenerated=false

        if [ -n "$SCOPED_MONGO_URI" ]; then
            local uri_no_proto="${SCOPED_MONGO_URI#mongodb://}"
            local credentials="${uri_no_proto%%@*}"
            app_db_user="${credentials%%:*}"
            app_db_password="${credentials#*:}"
            log_info "Ensuring existing database user '${app_db_user}' exists in MongoDB..."
        else
            credentials_regenerated=true
            log_warn "Podman secret '${app}_mongo_uri' is missing! Automatically regenerating database credentials..."
            app_db_password=$(openssl rand -hex 16 2>/dev/null || gpg --gen-random --armor 1 16 2>/dev/null || dd if=/dev/urandom bs=1 count=16 2>/dev/null | od -An -vtx1 | tr -d ' \n' || echo "AppPass$(date +%s%N)")
            SCOPED_MONGO_URI="mongodb://${app_db_user}:${app_db_password}@shared_production_mongodb:27017/${DB_NAME}?authSource=${DB_NAME}"
            
            podman secret rm "${app}_mongo_uri" >/dev/null 2>&1 || true
            printf "%s" "$SCOPED_MONGO_URI" | podman secret create "${app}_mongo_uri" -
            log_success "Regenerated Podman secret: ${app}_mongo_uri"
        fi

        # Ensure the compose file correctly references the regenerated/existing secret
        local compose_file="/opt/$app/docker-compose.prod.yml"
        if [ ! -f "$compose_file" ] || ! grep -q "${app}_mongo_uri" "$compose_file"; then
            log_warn "Compose file is missing or does not reference the regenerated secret. Regenerating compose file..."
            local env_prod="/opt/$app/.env.production"
            local app_domain=""
            local active_cpus=""
            local active_mem=""
            if [ -f "$env_prod" ]; then
                app_domain=$(grep "^APP_DOMAIN=" "$env_prod" | cut -d= -f2-)
                active_cpus=$(grep "^APP_CPUS=" "$env_prod" | cut -d= -f2-)
                active_mem=$(grep "^APP_MEM_LIMIT=" "$env_prod" | cut -d= -f2-)
            fi
            if [ -z "$app_domain" ]; then
                app_domain="$APP_DOMAIN"
            fi
            
            declare -A local_mapped_secrets
            if [ -f "$compose_file" ]; then
                for s_source in $(grep -o "${app}_secret_[A-Za-z0-9._-]*" "$compose_file" 2>/dev/null | sort -u || true); do
                    local key="${s_source#${app}_secret_}"
                    local_mapped_secrets["$key"]="$s_source"
                done
            fi
            
            local services_secrets="    secrets:\n      - source: ${app}_mongo_uri\n        target: MONGO_URI"
            local global_secrets="secrets:\n  ${app}_mongo_uri:\n    external: true"
            for key in "${!local_mapped_secrets[@]}"; do
                local s_name="${local_mapped_secrets[$key]}"
                services_secrets="${services_secrets}\n      - source: ${s_name}\n        target: ${key}"
                global_secrets="${global_secrets}\n  ${s_name}:\n    external: true"
            done
            
            cat <<EOF > "$compose_file"
# WARNING: THIS FILE IS AUTOGENERATED BY appSqueezer.sh
# ANY MANUAL CHANGES MADE TO THIS FILE WILL BE OVERWRITTEN
# DURING RECONFIGURATIONS, UPDATES, OR REDEPLOYMENTS.

services:
  backend-${app}:
    image: ${IMAGE}
    container_name: app_${app}_backend
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
            if [ -n "$active_cpus" ]; then
                echo "    cpus: \"${active_cpus}\"" >> "$compose_file"
            fi
            if [ -n "$active_mem" ]; then
                echo "    mem_limit: \"${active_mem}\"" >> "$compose_file"
            fi
            printf "%b\n" "$services_secrets" >> "$compose_file"
            cat <<EOF >> "$compose_file"
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.${app}.rule=Host(\`${app_domain}\`) && PathPrefix(\`/${app}\`)"
      - "traefik.http.routers.${app}.entrypoints=websecure"
      - "traefik.http.routers.${app}.tls=true"
      - "traefik.http.routers.${app}.tls.certresolver=letsencryptresolver"
      - "traefik.http.middlewares.${app}-strip.stripprefix.prefixes=/${app}"
      - "traefik.http.routers.${app}.middlewares=${app}-strip"
      - "traefik.http.services.${app}.loadbalancer.server.port=3000"

EOF
            printf "%b\n" "$global_secrets" >> "$compose_file"
            cat <<EOF >> "$compose_file"

networks:
  web_gateway:
    external: true
EOF
            log_success "Compose file regenerated successfully."
        fi

        set +e
        if [ "$credentials_regenerated" = true ]; then
            podman exec -i \
                -e DB_NAME="${DB_NAME}" \
                -e APP_DB_USER="${app_db_user}" \
                -e APP_DB_PASSWORD="${app_db_password}" \
                shared_production_mongodb mongosh \
                -u "$MONGO_ROOT_USER" \
                -p "$MONGO_ROOT_PASSWORD" \
                --authenticationDatabase admin \
                --eval "
                    db = db.getSiblingDB(process.env.DB_NAME);
                    const dbUser = process.env.APP_DB_USER;
                    const dbPassword = process.env.APP_DB_PASSWORD;
                    if (!db.getUser(dbUser)) {
                        db.createUser({
                            user: dbUser,
                            pwd: dbPassword,
                            roles: [{ role: 'readWrite', db: process.env.DB_NAME }]
                        });
                    } else {
                        db.changeUserPassword(dbUser, dbPassword);
                    }
                " >/dev/null
        else
            podman exec -i \
                -e DB_NAME="${DB_NAME}" \
                -e APP_DB_USER="${app_db_user}" \
                -e APP_DB_PASSWORD="${app_db_password}" \
                shared_production_mongodb mongosh \
                -u "$MONGO_ROOT_USER" \
                -p "$MONGO_ROOT_PASSWORD" \
                --authenticationDatabase admin \
                --eval "
                    db = db.getSiblingDB(process.env.DB_NAME);
                    const dbUser = process.env.APP_DB_USER;
                    const dbPassword = process.env.APP_DB_PASSWORD;
                    if (!db.getUser(dbUser)) {
                        db.createUser({
                            user: dbUser,
                            pwd: dbPassword,
                            roles: [{ role: 'readWrite', db: process.env.DB_NAME }]
                        });
                    }
                " >/dev/null
        fi
        STATUS=$?
        set -e
        if [ $STATUS -ne 0 ]; then
            log_warn "Failed to verify or provision database user '${app_db_user}' in MongoDB. Database operations might fail."
        fi

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

do_completion() {
    cat <<'EOF'
_appsqueezer_completion() {
    local cur prev opts
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"

    # Subcommands (including help)
    local subcommands="install uninstall create-app list start stop restart logs configure update destroy-app backup restore completion help"

    # Check if a subcommand is already typed in the command line
    local i cmd=""
    for ((i=1; i<COMP_CWORD; i++)); do
        if [[ " ${subcommands} " =~ " ${COMP_WORDS[i]} " ]]; then
            cmd="${COMP_WORDS[i]}"
            break
        fi
    done

    if [[ -n "$cmd" ]]; then
        # Complete app names for commands that take app name as positional argument
        if [[ " start stop restart logs configure update destroy-app " =~ " ${cmd} " ]] && [[ ! "$cur" =~ ^- ]] && [[ ! "$prev" =~ ^-- ]]; then
            local apps=""
            apps=$(find /opt/ -mindepth 2 -maxdepth 2 -name "docker-compose.prod.yml" 2>/dev/null | cut -d/ -f3)
            COMPREPLY=( $(compgen -W "${apps}" -- ${cur}) )
            return 0
        fi

        # Complete app names after --app-name option
        if [[ " backup restore " =~ " ${cmd} " ]] && [[ "$prev" == "--app-name" ]]; then
            local apps=""
            apps=$(find /opt/ -mindepth 2 -maxdepth 2 -name "docker-compose.prod.yml" 2>/dev/null | cut -d/ -f3)
            COMPREPLY=( $(compgen -W "${apps}" -- ${cur}) )
            return 0
        fi

        case "$cmd" in
            install)
                opts="-d --domain -e --email -u --mongo-user -p --mongo-password"
                ;;
            uninstall)
                opts="-y --non-interactive --keep-apps --destroy-apps"
                ;;
            create-app)
                opts="--app-parameter --app-secret --cpu --memory --use-existing-parameters --disregard-existing-parameters --use-existing-secrets --disregard-existing-secrets --use-existing-data --disregard-existing-data"
                ;;
            configure)
                opts="--app-parameter --app-secret --cpu --memory --clear-app-parameters --clear-app-secrets --clear-app-limits"
                ;;
            update)
                opts="--image"
                ;;
            destroy-app)
                opts="--keep-secrets --delete-secrets --keep-parameters --delete-parameters --keep-data --delete-data --keep-backups --delete-backups"
                ;;
            backup)
                opts="--app-name --description --all"
                ;;
            restore)
                opts="--app-name --backup-name --all"
                ;;
            completion)
                opts="generate"
                ;;
            help)
                opts="${subcommands}"
                ;;
            *)
                opts=""
                ;;
        esac
        COMPREPLY=( $(compgen -W "${opts}" -- ${cur}) )
        return 0
    fi

    # Otherwise complete subcommands
    COMPREPLY=( $(compgen -W "${subcommands}" -- ${cur}) )
    return 0
}
complete -F _appsqueezer_completion appSqueezer.sh ./appSqueezer.sh appSqueezer
EOF
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
    completion)
        do_completion
        ;;
    *)
        show_usage
        ;;
esac
