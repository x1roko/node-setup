# 🚀 Remnanode Auto-Installer

An automated Bash script for deploying a Remnanode with Nginx proxy, a selected web service, and Cloudflare WARP integration.

## 📋 What Does This Script Do?

The script fully configures a server from scratch:

1. **Infrastructure:** Installs Docker Engine and Docker Compose.
2. **SSL Certification:** Installs `acme.sh` and issues **Let's Encrypt** certificates (Standalone mode).
3. **Nginx Proxy:** Configures a proxy server (port `9443`) for secure HTTPS access.
4. **Remnanode:** Installs the node with automatic `SECRET_KEY` and SSL certificate paths.
5. **Security:** Configures `ufw` firewall (only necessary ports are opened).
6. **Cloudflare WARP:** Downloads the WARP client installer.

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
4. **Service Selection** (enter a number or press Enter for random).

## 📂 Project Structure

- `/opt/remnanode/` — Node configuration.
- `/opt/remnanode/nginx/` — Nginx configs and SSL keys.
- `/opt/[service-name]/` — Selected web service files.

## ⚠️ Used Ports


| Port  | Service                         |
| ----- | ------------------------------- |
| 443   | xray (or custom)                |
| 9443  | Web Interface (HTTPS)           |
| 2222  | Remnanode Node Port             |
| 40000 | Cloudflare WARP SOCKS5 (closed) |
