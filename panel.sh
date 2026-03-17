#!/usr/bin/env bash
# =============================================================================
# Pterodactyl Panel - POWERFUL Docker Compose Installer (2026 Edition)
# Install location: $HOME/.ks/pterodactyl/panel
# Features: Full editable panel (themes + Blueprint work instantly)
#           Port 80 + Nginx + MariaDB + Redis + Queue + Cron
#           ./www = complete /app (upload ANY theme or Blueprint files → works)
# =============================================================================

set -euo pipefail

INSTALL_DIR="$HOME/.ks/pterodactyl/panel"
COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
ENV_FILE="$INSTALL_DIR/.env"
WWW_DIR="$INSTALL_DIR/www"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "\( {GREEN}Creating POWERFUL Pterodactyl Panel (full theme/Blueprint support) in: \){NC}"
echo "  $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR" || exit 1

# ────────────────────────────────────────────────
# Generate secure passwords
# ────────────────────────────────────────────────

DB_PASS=$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 20)
ROOT_DB_PASS=$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 24)

echo -e "\( {YELLOW}Generated secure passwords (save these!): \){NC}"
echo "MariaDB root password   : $ROOT_DB_PASS"
echo "Pterodactyl DB password : $DB_PASS"
echo ""

# ────────────────────────────────────────────────
# Ask for real domain / IP
# ────────────────────────────────────────────────

echo -e "\( {YELLOW}What is your panel URL? (example: http://panel.yourdomain.com or http://123.45.67.89) \){NC}"
echo -e "Press Enter for default (http://localhost): "
read -r INPUT_URL
APP_URL="${INPUT_URL:-http://localhost}"

# ────────────────────────────────────────────────
# Create .env for easy editing
# ────────────────────────────────────────────────

cat > "$ENV_FILE" << EOF
# Pterodactyl Panel Settings
APP_URL=$APP_URL
DB_PASSWORD=$DB_PASS
MYSQL_ROOT_PASSWORD=$ROOT_DB_PASS
EOF
chmod 600 "$ENV_FILE"

# ────────────────────────────────────────────────
# Copy full panel files to ./www (this makes EVERY theme + Blueprint work)
# ────────────────────────────────────────────────

echo -e "\( {YELLOW}Copying complete panel files to ./www (editable on host)... \){NC}"
docker pull ghcr.io/pterodactyl/panel:latest

docker create --name temp-panel-copy ghcr.io/pterodactyl/panel:latest
docker cp temp-panel-copy:/app/. "$WWW_DIR"
docker rm temp-panel-copy

echo -e "\( {YELLOW}Setting permissions (for panel + Blueprint compatibility)... \){NC}"
chown -R 1000:1000 "$WWW_DIR" 2>/dev/null || true
chmod -R 755 "$WWW_DIR"
chmod -R 777 "$WWW_DIR/storage" 2>/dev/null || true   # Laravel storage writable

# ────────────────────────────────────────────────
# Generate docker-compose.yml
# ────────────────────────────────────────────────

echo -e "\( {YELLOW}Writing docker-compose.yml ... \){NC}"

cat > "$COMPOSE_FILE" << EOF
services:
  panel:
    image: ghcr.io/pterodactyl/panel:latest
    container_name: ptero-panel
    restart: unless-stopped
    depends_on:
      - db
      - redis
    environment:
      APP_URL:              \${APP_URL}
      APP_TIMEZONE:         Asia/Kolkata
      APP_SERVICE_AUTHOR:   noreply@example.com

      DB_HOST:              db
      DB_PORT:              3306
      DB_DATABASE:          panel
      DB_USERNAME:          pterouser
      DB_PASSWORD:          \${DB_PASSWORD}

      CACHE_DRIVER:         redis
      SESSION_DRIVER:       redis
      QUEUE_CONNECTION:     redis

      REDIS_HOST:           redis
      REDIS_PASSWORD:       null
      REDIS_PORT:           6379

      MAIL_DRIVER:          log
      MAIL_FROM:            noreply@example.com

    volumes:
      - ./www:/app                # ← FULL editable panel (themes + Blueprint)
    networks:
      - ptero_net

  web:
    image: nginx:alpine
    container_name: ptero-web
    restart: unless-stopped
    ports:
      - "80:80"                   # ← Direct access on port 80
      # - "443:443"               # uncomment later for HTTPS
    volumes:
      - ./www:/app:ro
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
    depends_on:
      - panel
    networks:
      - ptero_net

  db:
    image: mariadb:10.11
    container_name: ptero-db
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD:  \${MYSQL_ROOT_PASSWORD}
      MYSQL_DATABASE:       panel
      MYSQL_USER:           pterouser
      MYSQL_PASSWORD:       \${DB_PASSWORD}
    volumes:
      - db_data:/var/lib/mysql
    networks:
      - ptero_net

  redis:
    image: redis:alpine
    container_name: ptero-redis
    restart: unless-stopped
    networks:
      - ptero_net

  queue:
    image: ghcr.io/pterodactyl/panel:latest
    container_name: ptero-queue
    restart: unless-stopped
    command: php artisan queue:work --sleep=3 --tries=3
    depends_on:
      - panel
    volumes:
      - ./www:/app
    environment:
      APP_URL:              \${APP_URL}
      DB_HOST:              db
      DB_DATABASE:          panel
      DB_USERNAME:          pterouser
      DB_PASSWORD:          \${DB_PASSWORD}
      REDIS_HOST:           redis
      QUEUE_CONNECTION:     redis
    networks:
      - ptero_net

  cron:
    image: ghcr.io/pterodactyl/panel:latest
    container_name: ptero-cron
    restart: unless-stopped
    command: >
      sh -c "while true; do php /app/artisan schedule:run --verbose --no-interaction; sleep 60; done"
    depends_on:
      - panel
    volumes:
      - ./www:/app
    environment:
      APP_URL:              \${APP_URL}
      DB_HOST:              db
      DB_DATABASE:          panel
      DB_USERNAME:          pterouser
      DB_PASSWORD:          \${DB_PASSWORD}
      REDIS_HOST:           redis
    networks:
      - ptero_net

volumes:
  db_data:

networks:
  ptero_net:
    driver: bridge
EOF

# ────────────────────────────────────────────────
# Create correct nginx.conf (root = /app/public)
# ────────────────────────────────────────────────

cat > "$INSTALL_DIR/nginx.conf" << 'NGINX'
server {
    listen 80;
    server_name _;

    root /app/public;
    index index.php;

    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }

    location \~ \.php$ {
        fastcgi_pass panel:9000;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        include fastcgi_params;
    }

    location \~ /\.ht {
        deny all;
    }
}
NGINX

echo -e "\( {GREEN}docker-compose.yml + nginx.conf created. \){NC}"

# ────────────────────────────────────────────────
# Start the stack
# ────────────────────────────────────────────────

echo -e "\n\( {YELLOW}Starting containers ... \){NC}"
docker compose up -d

echo -e "\n\( {GREEN}Containers started. \){NC}"
echo "Waiting 45 seconds for full initialization..."
sleep 45

docker compose exec panel php artisan p:environment:setup
docker compose exec panel php artisan p:environment:database
docker compose exec panel php artisan migrate --seed --force
docker compose exec panel php artisan key:generate --force
docker compose exec panel php artisan p:user:make
docker compose exec panel php artisan storage:link
# ────────────────────────────────────────────────
# Final instructions (POWERFUL edition)
# ────────────────────────────────────────────────

cat << EOF

${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
       Pterodactyl Panel — POWERFUL EDITABLE VERSION
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}

✅ Access the panel →  ${YELLOW}\( APP_URL \){NC}
   (no port needed — running on 80)

✅ Theme & Blueprint support:
   • Everything is in ${YELLOW}\( INSTALL_DIR/www \){NC}
   • Upload any theme files directly to ./www/public or ./www/resources
   • Run Blueprint installer — it works 100% (no container hacks needed)
   • Changes appear instantly after page refresh

Useful codes (run in $INSTALL_DIR):

1. Environment wizard
   \( {YELLOW}docker compose exec panel php artisan p:environment:setup \){NC}

2. Database
   \( {YELLOW}docker compose exec panel php artisan p:environment:database \){NC}

3. Migrate + seed
   \( {YELLOW}docker compose exec panel php artisan migrate --seed --force \){NC}

4. App key
   \( {YELLOW}docker compose exec panel php artisan key:generate --force \){NC}

5. Create admin user
   \( {YELLOW}docker compose exec panel php artisan p:user:make \){NC}

(Optional but recommended)
   \( {YELLOW}docker compose exec panel php artisan storage:link \){NC}

Security / Management:
• Edit passwords in $ENV_FILE then: docker compose down && docker compose up -d
• Backup: $INSTALL_DIR/www + db_data volume
• Stop:    docker compose down
• Update panel: docker compose down && docker pull ghcr.io/pterodactyl/panel:latest && docker cp (re-copy to www) && up -d
• HTTPS: later add Let's Encrypt/Caddy (change to 443 + update APP_URL to https)

\( {GREEN}Setup complete — run the 5 commands above one by one. \){NC}
You now have a REAL editable Pterodactyl installation inside Docker.
Any theme or Blueprint works exactly like a normal /var/www/pterodactyl install.

Enjoy your game servers! 🚀
EOF
