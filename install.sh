#!/bin/bash

# Exit on error
set -e

ENV_FILE=".env"
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# --- SERVICES LIST ---
# Format: "Name|Image|Internal_Port"
SERVICES=(
    "filebrowser|filebrowser/filebrowser|80"
    "memos|neosmemo/memos:stable|5230"
    "pingvin-share|stonith404/pingvin-share|3000"
    "excalidraw|excalidraw/excalidraw|80"
    "searxng|searxng/searxng|8080"
    "sharry|jlesage/sharry|9090"
    "audiobookshelf|advplyr/audiobookshelf|80"
    "kavita|jvmilazz0/kavita|5000"
    "kodbox|kodcloud/kodbox|80"
    "navidrome|deluan/navidrome|4533"
    "gitea|gitea/gitea|3000"
    "fluffy-web|aceberg/fluffychat|80"
)

# Load existing .env if it exists
if [ -f "$ENV_FILE" ]; then
    # Export variables but ignore comments
    export $(grep -v '^#' "$ENV_FILE" | xargs)
fi

ask_variable() {
    local var_name=$1
    local prompt_text=$2
    local current_val=${!var_name}

    if [ ! -z "$current_val" ]; then
        read -p "$prompt_text (Current: $current_val). Use previous? [Y/n]: " use_old
        if [[ "$use_old" =~ ^[Nn]$ ]]; then
            read -p "Enter new $var_name: " new_val
            eval "$var_name=\"$new_val\""
        fi
    else
        read -p "Enter $prompt_text: " new_val
        eval "$var_name=\"$new_val\""
    fi
}

# --- DATA COLLECTION ---
echo "--- Configuration ---"
ask_variable "EMAIL" "Email (for SSL)"
ask_variable "DOMAIN" "Domain (e.g., node.example.com)"
ask_variable "SECRET_KEY" "SECRET_KEY (from panel)"

# --- SERVICE SELECTION ---
SELECTED_SERVICE=""

if [ ! -z "$SERVICE_NAME" ]; then
    read -p "Saved service is '$SERVICE_NAME'. Use previous? [Y/n]: " use_old_service
    if [[ "$use_old_service" =~ ^[Yy]$ || -z "$use_old_service" ]]; then
        for s in "${SERVICES[@]}"; do
            if [[ "$(echo "$s" | cut -d'|' -f1)" == "$SERVICE_NAME" ]]; then
                SELECTED_SERVICE="$s"
                break
            fi
        done
        if [ -z "$SELECTED_SERVICE" ]; then
            echo "Warning: Saved service '$SERVICE_NAME' not found in the available list. Forced re-selection."
        fi
    fi
fi

if [ -z "$SELECTED_SERVICE" ]; then
    echo "------------------------------------------------"
    echo "Select the service you want to install:"
    for i in "${!SERVICES[@]}"; do
        NAME=$(echo "${SERVICES[$i]}" | cut -d'|' -f1)
        echo "[$((i+1))] $NAME"
    done

    read -p "Service number (Press Enter for a random one): " CHOICE

    if [ -z "$CHOICE" ]; then
        RAND_IDX=$(( RANDOM % ${#SERVICES[@]} ))
        SELECTED_SERVICE="${SERVICES[$RAND_IDX]}"
    else
        SELECTED_SERVICE="${SERVICES[$((CHOICE-1))]}"
    fi
    SERVICE_NAME=$(echo "$SELECTED_SERVICE" | cut -d'|' -f1)
fi

SERVICE_IMAGE=$(echo "$SELECTED_SERVICE" | cut -d'|' -f2)
SERVICE_PORT=$(echo "$SELECTED_SERVICE" | cut -d'|' -f3)

cat <<EOF > "$ENV_FILE"
EMAIL=$EMAIL
DOMAIN=$DOMAIN
SECRET_KEY=$SECRET_KEY
SERVICE_NAME=$SERVICE_NAME
EOF

echo "--- Installing service: $SERVICE_NAME ---"
echo "------------------------------------------------"

echo "--- 1. Checking and Installing Dependencies ---"

if command -v docker &> /dev/null; then
    echo "Docker is already installed ($(docker --version | head -n1)). Skipping installation."
else
    echo "Docker not found. Installing..."
    sudo curl -fsSL https://get.docker.com | sh
fi

if docker compose version &> /dev/null; then
    echo "Docker Compose plugin is available. Skipping installation."
else
    echo "Docker Compose not found or outdated. Updating docker packages..."
    sudo apt-get update
    sudo apt-get install -y docker-compose-plugin
fi

echo "Ensuring system utilities are installed..."
sudo apt-get update
sudo apt-get install -y cron socat curl ufw expect

echo "--- 2. Installing acme.sh ---"
curl https://get.acme.sh | sh -s email=$EMAIL
export LE_WORKING_DIR="${HOME}/.acme.sh"
alias acme.sh="${HOME}/.acme.sh/acme.sh"

echo "Select default Certificate Authority (CA):"
echo "1) Let's Encrypt"
echo "2) ZeroSSL"
read -p "Enter choice [1-2]: " CA_CHOICE

case $CA_CHOICE in
    1)
        echo "Setting default CA to Let's Encrypt..."
        ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
        ;;
    2)
        echo "Setting default CA to ZeroSSL..."
        ~/.acme.sh/acme.sh --set-default-ca --server zerossl
        ;;
    *)
        echo "Invalid choice. Defaulting to Let's Encrypt to be safe."
        ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
        ;;
esac

# Preparing directories
mkdir -p /opt/remnanode/nginx
mkdir -p "/opt/$SERVICE_NAME"

echo "--- 3. Issuing SSL Certificate ---"

CERT_KEY="/opt/remnanode/nginx/privkey.key"
CERT_PEM="/opt/remnanode/nginx/fullchain.pem"

PRE_HOOK="ufw allow 8443/tcp && ufw reload"
POST_HOOK="ufw delete allow 8443/tcp && ufw reload"

ACME_ECC_DIR="${HOME}/.acme.sh/${DOMAIN}_ecc"
ACME_RSA_DIR="${HOME}/.acme.sh/${DOMAIN}"

# Standard certbot / letsencrypt-auto layout
LE_LIVE_DIR="/etc/letsencrypt/live/${DOMAIN}"

# Tracks where the certificate actually came from, used later to decide
# how to wire up auto-renewal.
CERT_SOURCE=""

if [ -f "$LE_LIVE_DIR/fullchain.pem" ] && [ -f "$LE_LIVE_DIR/privkey.pem" ]; then
    echo "Found a certbot/Let's Encrypt certificate for $DOMAIN in $LE_LIVE_DIR. Using it..."
    # -L to dereference the symlinks certbot creates in the live/ folder.
    # Checked FIRST and unconditionally (even if nginx already has a copy
    # from a previous run) so a certbot-issued cert is always recognized as
    # such and always gets the certbot renewal hook below — not acme.sh.
    cp -L "$LE_LIVE_DIR/fullchain.pem" "$CERT_PEM"
    cp -L "$LE_LIVE_DIR/privkey.pem" "$CERT_KEY"
    chmod 600 "$CERT_KEY"
    CERT_SOURCE="letsencrypt_live"

elif [ -f "$CERT_PEM" ] && [ -f "$CERT_KEY" ]; then
    echo "SSL certificates already exist at $CERT_PEM (no matching /etc/letsencrypt/live entry). Skipping initial issuance."
    CERT_SOURCE="nginx_existing"

elif [ -f "$ACME_ECC_DIR/fullchain.cer" ] && [ -f "$ACME_ECC_DIR/${DOMAIN}.key" ]; then
    echo "Certificate for $DOMAIN already exists in acme.sh cache. Installing to Nginx directory..."
    ~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" \
        --key-file "$CERT_KEY" \
        --fullchain-file "$CERT_PEM" \
        --ecc
    CERT_SOURCE="acme_ecc"

elif [ -f "$ACME_RSA_DIR/fullchain.cer" ] && [ -f "$ACME_RSA_DIR/${DOMAIN}.key" ]; then
    echo "RSA Certificate for $DOMAIN already exists in acme.sh cache. Installing to Nginx directory..."
    ~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" \
        --key-file "$CERT_KEY" \
        --fullchain-file "$CERT_PEM"
    CERT_SOURCE="acme_rsa"

else
    echo "No existing certificates found."
    echo "Select SSL validation method:"
    echo "1) Standalone (HTTP/TLS-ALPN-01 on port 8443 - requires this port reachable from the internet)"
    echo "2) DNS-01 via Cloudflare (certbot + API Token only, no inbound port needed)"
    read -p "Enter choice [1-2]: " VALIDATION_CHOICE

    if [ "$VALIDATION_CHOICE" == "2" ]; then
        echo "--- Cloudflare DNS-01 challenge (certbot) ---"
        ask_variable "CF_Token" "Cloudflare API Token (Zone:DNS:Edit permission for the zone of $DOMAIN)"

        # Persist for reuse on future re-runs
        echo "CF_Token=$CF_Token" >> "$ENV_FILE"

        echo "Installing certbot + Cloudflare DNS plugin..."
        sudo apt-get update
        sudo apt-get install -y certbot python3-certbot-dns-cloudflare

        CF_INI="/opt/remnanode/cloudflare.ini"
        cat <<EOF > "$CF_INI"
dns_cloudflare_api_token = $CF_Token
EOF
        chmod 600 "$CF_INI"

        echo "Issuing certificate via Cloudflare DNS-01..."
        if ! certbot certonly \
            --dns-cloudflare \
            --dns-cloudflare-credentials "$CF_INI" \
            -d "$DOMAIN" \
            --non-interactive --agree-tos -m "$EMAIL"; then
            echo "Error: Failed to issue SSL certificate via Cloudflare DNS-01."
            echo "Check that the API Token has Zone:DNS:Edit permission for $DOMAIN."
            exit 1
        fi

        # certbot stores the cert under /etc/letsencrypt/live/$DOMAIN — reuse
        # the same handling (and renewal path) as an already-existing cert.
        cp -L "$LE_LIVE_DIR/fullchain.pem" "$CERT_PEM"
        cp -L "$LE_LIVE_DIR/privkey.pem" "$CERT_KEY"
        chmod 600 "$CERT_KEY"
        CERT_SOURCE="letsencrypt_live"
    else
        echo "Issuing a new certificate via standalone ALPN..."
        if ! ~/.acme.sh/acme.sh --issue --standalone -d "$DOMAIN" \
            --key-file "$CERT_KEY" \
            --fullchain-file "$CERT_PEM" \
            --alpn --tlsport 8443; then

            if [ -f "$ACME_ECC_DIR/fullchain.cer" ]; then
                echo "Issue reported an error, but certificate files were found. Copying..."
                ~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --key-file "$CERT_KEY" --fullchain-file "$CERT_PEM" --ecc
            else
                echo "Error: Failed to issue SSL certificate."
                exit 1
            fi
        fi
        CERT_SOURCE="acme_new"
    fi
fi

echo "--- 4. Setting up  $SERVICE_NAME ---"

cat <<EOF > "/opt/$SERVICE_NAME/docker-compose.yml"
services:
  $SERVICE_NAME:
    container_name: $SERVICE_NAME
    image: $SERVICE_IMAGE
    restart: unless-stopped
    ports:
      - "127.0.0.1:8080:$SERVICE_PORT"
EOF

docker compose -f "/opt/$SERVICE_NAME/docker-compose.yml" up -d

echo "================================================"
ask_variable "XHTTP_PATH" "XHTTP Location Path (e.g., /xhttppath/)"
ask_variable "GRPC_PATH" "gRPC Service Name/Path (e.g., /grpcpath)"

    XHTTP_PATH=${XHTTP_PATH:-/xhttppath/}
    GRPC_PATH=${GRPC_PATH:-/grpcpath}

    [[ "$XHTTP_PATH" != /* ]] && XHTTP_PATH="/$XHTTP_PATH"
    [[ "$XHTTP_PATH" != */ ]] && XHTTP_PATH="$XHTTP_PATH/"

    [[ "$GRPC_PATH" != /* ]] && GRPC_PATH="/$GRPC_PATH"

    echo "XHTTP_PATH=$XHTTP_PATH" >> "$ENV_FILE"
    echo "GRPC_PATH=$GRPC_PATH" >> "$ENV_FILE"

    echo "--- 5. Configuring Nginx Proxy ---"

    cat <<EOF > /opt/remnanode/nginx/nginx.conf
map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ''      close;
}

server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen unix:/dev/shm/nginx.sock ssl proxy_protocol;
    server_name $DOMAIN;
    http2 on;

    ssl_certificate /etc/nginx/certs/fullchain.pem;
    ssl_certificate_key /etc/nginx/certs/privkey.key;
    
    location $XHTTP_PATH {
        client_max_body_size 0;

        proxy_buffering off;
        proxy_request_buffering off; 

        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        
        proxy_set_header Host \$host;
        proxy_http_version 1.1;
        proxy_set_header Connection "keep-alive";

        client_body_timeout 5m;
        proxy_read_timeout 315s;
        proxy_send_timeout 5m;
        proxy_pass http://unix:/dev/shm/xrxh.socket;
    }

    location $GRPC_PATH {
        client_max_body_size 0;
        
        client_body_timeout 5m;
        grpc_set_header X-Real-IP \$proxy_protocol_addr;
        grpc_set_header X-Forwarded-For \$proxy_protocol_addr;
        grpc_set_header Host \$host;
        grpc_socket_keepalive on;
        grpc_read_timeout 315s;
        grpc_send_timeout 5m;
        
        grpc_pass grpc://unix:/dev/shm/grpc.socket;
    }

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
    }
}
EOF

    cat <<EOF > /opt/remnanode/nginx/docker-compose.yml
services:
  nginx:
    image: nginx:latest
    container_name: remnanode-proxy
    restart: always
    network_mode: host
    volumes:
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
      - ./fullchain.pem:/etc/nginx/certs/fullchain.pem:ro
      - ./privkey.key:/etc/nginx/certs/privkey.key:ro
      - /dev/shm:/dev/shm:rw
    command: sh -c 'rm -f /dev/shm/nginx.sock && exec nginx -g "daemon off;"'
EOF

    docker compose -f "/opt/remnanode/nginx/docker-compose.yml" up -d

    echo "--- 6. Installing Remnanode ---"

    cat <<EOF > /opt/remnanode/docker-compose.yml
services:
  remnanode:
    container_name: remnanode
    hostname: remnanode
    image: remnawave/node:latest
    network_mode: host
    restart: always
    cap_add:
      - NET_ADMIN
    volumes:
      - /opt/remnanode/nginx/fullchain.pem:/etc/nginx/certs/fullchain.pem:ro
      - /opt/remnanode/nginx/privkey.key:/etc/nginx/certs/privkey.key:ro
      - /dev/shm:/dev/shm:rw
      - /var/log/remnanode:/var/log/remnanode
    ulimits:
      nofile:
        soft: 1048576
        hard: 1048576
    environment:
      - NODE_PORT=2222
      - SECRET_KEY="$SECRET_KEY"
EOF

    docker compose -f "/opt/remnanode/docker-compose.yml" up -d


echo "--- 7. Configuring Firewall ---"

sudo ufw allow 22/tcp
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 2222/tcp
sudo ufw --force enable

echo "Configuring automatic renewal via crontab..."

# acme.sh stores each cert under either ~/.acme.sh/$DOMAIN (RSA) or
# ~/.acme.sh/${DOMAIN}_ecc (ECC, the default for new issuances). The
# install-cert call below needs the matching --ecc flag or it will fail
# with "is not a cert name" / "Cannot find path", so detect it here instead
# of assuming RSA.
ACME_CERT_FLAG=""
if [ "$CERT_SOURCE" != "letsencrypt_live" ]; then
    if [ -d "$ACME_ECC_DIR" ]; then
        ACME_CERT_FLAG="--ecc"
    elif [ -d "$ACME_RSA_DIR" ]; then
        ACME_CERT_FLAG=""
    else
        # Cert files exist on disk but acme.sh has no record of issuing them
        # (e.g. manually placed certs). Nothing to hook renewal into.
        CERT_SOURCE="unmanaged"
    fi
fi

if [ "$CERT_SOURCE" == "letsencrypt_live" ]; then
    # Cert is managed by certbot (either it pre-existed, or we just issued it
    # via the Cloudflare DNS-01 plugin) — let certbot keep renewing it and
    # just sync + restart when it does, instead of asking acme.sh to manage
    # a domain it never issued.
    echo "Certificate is managed by certbot ($LE_LIVE_DIR)."
    echo "Setting up a certbot deploy-hook to sync renewed certs and restart services..."

    sudo mkdir -p /etc/letsencrypt/renewal-hooks/deploy

    sudo tee "/etc/letsencrypt/renewal-hooks/deploy/remnanode-sync.sh" > /dev/null <<HOOKEOF
#!/bin/bash
# Auto-generated by remnanode install script.
# Copies the renewed certificate into the nginx dir and restarts the stack,
# but only if the renewed domain matches the one this node uses.
case ",\${RENEWED_DOMAINS// /,}," in
  *",$DOMAIN,"*)
    cp -L "$LE_LIVE_DIR/fullchain.pem" "$CERT_PEM"
    cp -L "$LE_LIVE_DIR/privkey.pem" "$CERT_KEY"
    chmod 600 "$CERT_KEY"
    docker compose -f /opt/remnanode/nginx/docker-compose.yml restart
    docker compose -f /opt/remnanode/docker-compose.yml restart
    ;;
esac
HOOKEOF
    sudo chmod +x "/etc/letsencrypt/renewal-hooks/deploy/remnanode-sync.sh"

    # Make sure certbot itself is actually being renewed periodically.
    # (If the cert was issued via the Cloudflare plugin, certbot already
    # remembers the credentials file path and will renew it the same way.)
    if ! crontab -l 2>/dev/null | grep -qF "certbot renew"; then
        (crontab -l 2>/dev/null; echo "0 3 * * * certbot renew --quiet") | crontab -
    fi

    echo "Certbot deploy-hook and renewal cron task configured."
elif [ "$CERT_SOURCE" == "unmanaged" ]; then
    echo "Warning: certificate files exist at $CERT_PEM but acme.sh has no record of issuing them"
    echo "(checked $ACME_ECC_DIR and $ACME_RSA_DIR). Skipping automatic renewal setup for it —"
    echo "please configure renewal manually for this certificate."
else
    ~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" $ACME_CERT_FLAG \
        --key-file "$CERT_KEY" \
        --fullchain-file "$CERT_PEM" \
        --pre-hook "$PRE_HOOK" \
        --post-hook "$POST_HOOK" \
        --reloadcmd "docker compose -f /opt/remnanode/nginx/docker-compose.yml restart && docker compose -f /opt/remnanode/docker-compose.yml restart"

    CRON_JOB="0 0 * * * \"${HOME}/.acme.sh\"/acme.sh --cron --home \"${HOME}/.acme.sh\" > /dev/null"
    (crontab -l 2>/dev/null | grep -F "acme.sh --cron" || (crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -)

    echo "Cron task successfully configured/verified."
fi

echo "--- [8/8] Installing WARP CLI ---"
chmod +x warp.sh
"./warp.sh"

echo "------------------------------------------------"
echo "INSTALLATION COMPLETE!"
echo "Selected Service: $SERVICE_NAME"
echo "Domain: $DOMAIN"
echo "Certificate source: $CERT_SOURCE"
echo "Remnanode Port: 2222"
echo "Checking WARP SOCKS5 proxy..."
curl -s --connect-timeout 4 --max-time 6 -x socks5h://127.0.0.1:40000 ifconfig.me
echo ""
echo "------------------------------------------------"
# read -p "Do you want to generate a ready-to-use Xray-core server config (VLESS+REALITY)? [y/N]: " SHOW_CONFIG

# if [[ "$SHOW_CONFIG" =~ ^[Yy]$ ]]; then
#     echo "Generating REALITY keys and shortIds..."
    
#     KEYS=$(docker exec remnanode xray x25519 2>/dev/null)
    
#     PRIVATE_KEY=$(echo "$KEYS" | grep "Private key:" | awk '{print $3}')
    
#     SHORT_ID=$(openssl rand -hex 8)

#     echo -e "\n=== GENERATED XRAY SERVER CONFIG ==="
#     cat <<EOF
# {
#   "log": {
#     "loglevel": "none"
#   },
#   "dns": {
#     "tag": "dns_inbound",
#     "servers": [
#       "9.9.9.9",
#       "149.112.112.112"
#     ],
#     "queryStrategy": "UseIPv4"
#   },
#   "inbounds": [
#     {
#       "tag": "TAG",
#       "port": 443,
#       "listen": "0.0.0.0",
#       "protocol": "vless",
#       "settings": {
#         "clients": [],
#         "decryption": "none"
#       },
#       "sniffing": {
#         "enabled": true,
#         "destOverride": [
#           "http",
#           "tls",
#           "quic"
#         ]
#       },
#       "streamSettings": {
#         "network": "raw",
#         "security": "reality",
#         "realitySettings": {
#           "xver": 1,
#           "target": "/dev/shm/nginx.sock",
#           "shortIds": [
#             "$SHORT_ID"
#           ],
#           "privateKey": "$PRIVATE_KEY",
#           "serverNames": [
#             "$DOMAIN"
#           ]
#         }
#       }
#     }
#   ],
#   "outbounds": [
#     {
#       "tag": "DIRECT",
#       "protocol": "freedom"
#     },
#     {
#       "tag": "BLOCK",
#       "protocol": "blackhole"
#     },
#     {
#       "tag": "warp",
#       "protocol": "socks",
#       "settings": {
#         "servers": [
#           {
#             "port": 40000,
#             "address": "127.0.0.1"
#           }
#         ]
#       }
#     }
#   ],
#   "routing": {
#     "rules": [
#     ]
#   }
# }
# EOF
#     echo -e "=====================================\n"
# fi
