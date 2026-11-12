# 🚀 Remnanode Auto-Installer

An automated Bash script for deploying a Remnanode with Nginx proxy, a selected web service, and Cloudflare WARP integration.

## 📋 What Does This Script Do?

The script fully configures a server from scratch:

1. **Infrastructure:** Installs Docker Engine and Docker Compose.
2. **SSL Certification:** Installs `acme.sh` and issues **Let's Encrypt** certificates (Standalone mode).
3. **Nginx Proxy:** Terminates TLS on port `443` and proxies to the node sockets; serves the fallback service as a selfsteal stub.
4. **Remnanode:** Installs the node with automatic `SECRET_KEY` and SSL certificate paths.
5. **Security:** Configures `ufw` firewall (only necessary ports are opened).
6. **Cloudflare WARP:** Downloads the WARP client installer.
7. **Anti-DPI hardening:** HTTP→301, TLS 1.2/1.3 only, HSTS, unknown-SNI rejection,
   node port `2222` firewalled to the panel IP only, and a built-in self-check (`verify.sh`).

---

## 🌍 Other Languages

- [Русский](docs/README_RU.md)
- [中文](docs/README_CN.md)

## 🛠 Prerequisites

- **OS:** Ubuntu 22.04+ or Debian 11+.
- **Domain:** Your A-record must point to the server's IP.
- **Permissions:** Run as **root** or with sudo.

## 🚀 Installation

1. Clone the repository:
  ```bash
   git clone https://github.com/x1roko/node-setup.git
  ```
2. Navigate to the project folder:
  ```bash
   cd node-setup
  ```
3. Grant execute permissions:
  ```bash
   chmod +x install.sh
  ```
4. Run the installation:
  ```bash
   ./install.sh
  ```

## 🚀 Installation (in one command)

```bash
git clone https://github.com/x1roko/node-setup.git && cd node-setup && sudo chmod +x install.sh && sudo ./install.sh 
```

## ⌨️ Input Parameters

The script will prompt for:

1. **Email** (for SSL registration).
2. **Domain** (e.g., `node.domain.com`).
3. **SECRET_KEY** (from Remnawave control panel).
4. **Panel IP** — the only address allowed to reach the node port `2222`.
   Take it from an existing node: `ss -tn state established '( sport = :2222 )'`.
5. **Service Selection** (enter a number or press Enter for random).

## 📂 Project Structure

- `/opt/remnanode/` — Node configuration.
- `/opt/remnanode/nginx/` — Nginx configs and SSL keys.
- `/opt/[service-name]/` — Selected web service files.

## ⚠️ Used Ports


| Port  | Service                                    |
| ----- | ------------------------------------------ |
| 80    | HTTP → HTTPS redirect (301)                    |
| 443   | xray + nginx selfsteal (single entrypoint) |
| 2222  | Remnanode node port — **panel IP only**        |
| 40000 | Cloudflare WARP SOCKS5 (127.0.0.1 only)    |

## 🛡 Anti-DPI hardening

Baked into the generated nginx config:

- `80 → 301` to HTTPS;
- `ssl_protocols TLSv1.2 TLSv1.3` (TLS 1.0/1.1 refused);
- `Strict-Transport-Security ... always` — the header is present on error responses too;
- `default_server` with `ssl_reject_handshake on` — unknown SNI gets alert 112
  instead of the stub page (clients must use SNI = `DOMAIN`);
- `server_tokens off` — nginx version is not advertised;
- `ufw` allows `2222` from the panel IP only.

Run the check any time:

```bash
bash verify.sh node1.example.com          # via 127.0.0.1
bash verify.sh node1.example.com 1.2.3.4  # against the public IP
```

The same check runs automatically at the end of the installation.


## Support me

**Tron**: ```TVfpYd9SZuYy9nZw5TwXUrdHTnR5YoSZn1```

**Sol**: ```CxP98kjB2DWE8oUi77tj5Dxgsrf5671i13XGoPws9gwv```