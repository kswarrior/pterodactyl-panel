#!/usr/bin/env bash
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "\( {GREEN}Pterodactyl Panel Docker Setup Wizard (2026 edition) \){NC}"
echo "This script will ask questions, generate docker-compose.yml and finish initial setup."
echo ""

# ────────────────────────────────────────────────
# Gather user input
# ────────────────────────────────────────────────

read -rp "Domain / Panel URL (example: https://panel.mydomain.com): " APP_URL
APP_URL="${APP_URL:-https://panel.example.com}"

# Basic URL validation
if [[ ! "$APP_URL" =\~ ^https?:// ]]; then
    echo -e "${RED}URL must start with http:// or https:// ${NC}"
    exit 1
fi

read -rp "Admin email (will be used for MAIL_FROM too) [admin@yourdomain.com]: " ADMIN_EMAIL
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@yourdomain.com}"

# Very basic email check
if [[ ! "\( ADMIN_EMAIL" =\~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,} \) ]]; then
    echo -e "\( {RED}Please enter a valid email address \){NC}"
    exit 1
fi

read -rp "Admin username [admin]: " ADMIN_USER
ADMIN_USER="${ADMIN_USER:-admin}"

read -rsp "Admin password (min 8 chars): " ADMIN_PASS
echo ""
read -rsp "Confirm admin password: " ADMIN_PASS2
echo ""

if [[ ${#ADMIN_PASS} -lt 8 ]]; then
    echo -e "\( {RED}Password must be at least 8 characters \){NC}"
    exit 1
fi
if [[ "$ADMIN_PASS" != "$ADMIN_PASS2" ]]; then
    echo -e "\( {RED}Passwords do not match \){NC}"
    exit 1
fi

# Database passwords
read -rsp "MySQL root password (strong!): " MYSQL_ROOT_PASS
echo ""
read -rsp "MySQL app user password (pterodactyl user): " MYSQL_APP_PASS
echo ""

if [[ -z "$MYSQL_ROOT_PASS" || -z "$MYSQL_APP_PASS" ]]; then
    echo -e "\( {RED}Both database passwords are required \){NC}"
    exit 1
fi

# Optional Let's Encrypt
read -rp "Enable Let's Encrypt? (y/n) [n]: " LE_ENABLE
LE_ENABLE="${LE_ENABLE:-n}"
LE_EMAIL=""
if [[ "\( LE_ENABLE" =\~ ^[Yy] \) ]]; then
    read -rp "Email for Let's Encrypt notifications: " LE_EMAIL
    if [[ -z "$LE_EMAIL" ]]; then
        echo -e "\( {YELLOW}No email provided → Let's Encrypt will be disabled \){NC}"
        LE_ENABLE="n"
    fi
fi

echo ""
echo -e "\( {YELLOW}Summary of settings: \){NC}"
echo "APP_URL          = $APP_URL"
echo "Admin email      = $ADMIN_EMAIL"
echo "Admin username   = $ADMIN_USER"
echo "Admin password   = [hidden]"
echo "DB root pass     = [hidden]"
echo "DB app pass      = [hidden]"
if [[ "\( LE_ENABLE" =\~ ^[Yy] \) ]]; then
    echo "Let's Encrypt    = yes ($LE_EMAIL)"
else
    echo "Let's Encrypt    = no"
fi
echo ""
read -p "Continue? (y/n): " CONFIRM
if [[ ! "\( CONFIRM" =\~ ^[Yy] \) ]]; then
    echo "Aborted."
    exit 0
fi

# ────────────────────────────────────────────────
# Prepare folders & files
# ────────────────────────────────────────────────

mkdir -p ./pterodactyl/{var,logs}

# Generate secure app key (40 chars base64-like)
APP_KEY=$(openssl rand -base64 32 | tr -d '/+' | head -c 32)

# ────────────────────────────────────────────────
# Write docker-compose.yml
# ────────────────────────────────────────────────

cat > docker-compose.yml <<EOF
version: '3.9'

x-common: &common
  restart: unless-stopped

x-db-environment: &db-environment
  MYSQL_PASSWORD: "$MYSQL_APP_PASS"
  MYSQL_ROOT_PASSWORD: "$MYSQL_ROOT_PASS"

x-panel-environment: &panel-environment
  APP_URL: "$APP_URL"
  APP_TIMEZONE: "Asia/Kolkata"
  APP_SERVICE_AUTHOR: "$ADMIN_EMAIL"
$(if [[ "\( LE_ENABLE" =\~ ^[Yy] \) ]]; then
    echo "  LE_EMAIL: \"$LE_EMAIL\""
fi)

x-mail-environment: &mail-environment
  MAIL_FROM: "$ADMIN_EMAIL"
  MAIL_DRIVER: "smtp"
  MAIL_HOST: "mailhog"
  MAIL_PORT: "1025"
  MAIL_USERNAME: ""
  MAIL_PASSWORD: ""
  MAIL_ENCRYPTION: "null"
  MAIL_FROM_NAME: "Pterodactyl Panel"

services:

  database:
    <<: *common
    image: mariadb:10.11
    command: --default-authentication-plugin=mysql_native_password
    environment:
      <<: *db-environment
      MYSQL_DATABASE: panel
      MYSQL_USER: pterodactyl
    volumes:
      - db_data:/var/lib/mysql
    healthcheck:
      test: ["CMD", "mariadb-admin", "--protocol=tcp", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5
    networks:
      - pteronet

  cache:
    <<: *common
    image: redis:7-alpine
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5
    networks:
      - pteronet

  mailhog:
    <<: *common
    image: mailhog/mailhog:latest
    ports:
      - "8025:8025"
      - "1025:1025"
    networks:
      - pteronet

  panel:
    <<: *common
    image: ghcr.io/pterodactyl/panel:latest
    ports:
      - "8080:80"
      - "8443:443"
    depends_on:
      database:
        condition: service_healthy
      cache:
        condition: service_healthy
    volumes:
      - ./pterodactyl/var:/app/var/
      - ./pterodactyl/logs:/app/storage/logs
    environment:
      <<: [*panel-environment, *mail-environment]
      APP_ENV: production
      APP_DEBUG: "false"
      APP_KEY: "$APP_KEY"
      APP_ENVIRONMENT_ONLY: "false"
      CACHE_DRIVER: redis
      SESSION_DRIVER: redis
      QUEUE_DRIVER: redis
      REDIS_HOST: cache
      REDIS_PASSWORD: null
      REDIS_PORT: 6379
      DB_HOST: database
      DB_PORT: 3306
      DB_DATABASE: panel
      DB_USERNAME: pterodactyl
      DB_PASSWORD: "$MYSQL_APP_PASS"
    networks:
      - pteronet

networks:
  pteronet:
    driver: bridge

volumes:
  db_data:
EOF

echo -e "\( {GREEN}docker-compose.yml created. \){NC}"

# ────────────────────────────────────────────────
# Start stack
# ────────────────────────────────────────────────

echo -e "\( {YELLOW}Starting containers... (may take 1–3 minutes) \){NC}"
docker compose up -d --remove-orphans

echo -e "\( {YELLOW}Waiting for database & redis to be ready (up to 90 seconds)... \){NC}"
sleep 20

# Wait longer if needed
for i in {1..12}; do
    if docker compose exec -T database mariadb-admin --protocol=tcp ping >/dev/null 2>&1; then
        break
    fi
    echo "Still waiting... ($i/12)"
    sleep 5
done

# ────────────────────────────────────────────────
# Run setup inside panel container
# ────────────────────────────────────────────────

echo -e "\( {YELLOW}Running initial setup commands... \){NC}"

docker compose exec -u root -T panel chown -R www-data:www-data /app/var /app/storage

# Usually not needed in latest images, but safe
docker compose exec -T panel php artisan storage:link || true

# The panel image usually auto-runs migrations on first start,
# but we force full setup anyway

docker compose exec -T panel php artisan migrate --seed --force
docker compose exec -T panel php artisan key:generate --force || true   # already set, but safe

# Create admin user non-interactively
docker compose exec -T panel php artisan p:user:make \
    --email="$ADMIN_EMAIL" \
    --username="$ADMIN_USER" \
    --password="$ADMIN_PASS" \
    --admin=true \
    --no-interaction || {
        echo -e "\( {RED}Failed to create admin user. Try manually: \){NC}"
        echo "docker compose exec -it panel php artisan p:user:make"
    }

echo ""
echo -e "\( {GREEN}╔════════════════════════════════════════════════════════════╗ \){NC}"
echo -e "\( {GREEN}║                  Setup finished!                           ║ \){NC}"
echo -e "\( {GREEN}╚════════════════════════════════════════════════════════════╝ \){NC}"
echo ""
echo "Panel should be available at:   $APP_URL"
echo "If using HTTP → http://your-server-ip:8080"
echo "Mailhog (test emails) →         http://your-server-ip:8025"
echo ""
echo -e "\( {YELLOW}Next steps: \){NC}"
echo "1. Log in → $APP_URL"
echo "2. Create node + allocation"
echo "3. Install Wings on same/different machine"
echo "4. (recommended) Put real reverse proxy (nginx/traefik/caddy) + SSL"
echo ""
echo -e "\( {GREEN}Enjoy Pterodactyl! \){NC}"
echo ""
