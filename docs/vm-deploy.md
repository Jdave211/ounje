# Ounje VM Deploy

The iOS app already resolves production traffic to `https://api.ounje.app`. This adds a Linux-friendly process model for the droplet.

## Processes

- `ounje-api.service`: serves the Node API.
- `ounje-recipe-ingestion.service`: runs the recipe ingestion worker as a separate daemon.

The API service disables inline recipe-ingestion polling so background work stays out of the request-serving process.

## Droplet setup

1. Install Node 24 and clone the repo to `/opt/ounje`.
2. Create `/etc/ounje/ounje.env`.
3. Copy [`deploy/systemd/ounje-api.service`](/Users/davejaga/Desktop/startups/ounje/deploy/systemd/ounje-api.service) and [`deploy/systemd/ounje-recipe-ingestion.service`](/Users/davejaga/Desktop/startups/ounje/deploy/systemd/ounje-recipe-ingestion.service) into `/etc/systemd/system/`.
4. Run `sudo systemctl daemon-reload`.
5. Run `sudo systemctl enable --now ounje-api ounje-recipe-ingestion`.

## Required env

Add these to `/etc/ounje/ounje.env`:

```bash
PORT=8080
HOST=0.0.0.0
OPENAI_API_KEY=...
SUPABASE_URL=...
SUPABASE_ANON_KEY=...
SUPABASE_SERVICE_ROLE_KEY=...
KROGER_CLIENT_ID=...
KROGER_CLIENT_SECRET=...
BROWSER_USE_API_KEY=...
LUMBOX_API_KEY=...
AGENTSIM_API_KEY=...
```

Optional:

```bash
RECIPE_INGESTION_BATCH_SIZE=4
RECIPE_INGESTION_POLL_MS=4000
```

## Manual checks

```bash
cd /opt/ounje
npm install
npm run start:vm
```

In a second shell:

```bash
cd /opt/ounje
npm run recipes:ingestion-worker:vm
```

## Nginx + TLS

The repo includes an nginx site file at [`deploy/nginx/api.ounje.app.conf`](/Users/davejaga/Desktop/startups/ounje/deploy/nginx/api.ounje.app.conf).

Ubuntu 24.04 steps:

```bash
sudo apt update
sudo apt install -y nginx certbot python3-certbot-nginx
sudo mkdir -p /var/www/certbot
sudo cp /opt/ounje/deploy/nginx/api.ounje.app.conf /etc/nginx/sites-available/api.ounje.app.conf
sudo ln -sf /etc/nginx/sites-available/api.ounje.app.conf /etc/nginx/sites-enabled/api.ounje.app.conf
sudo nginx -t
sudo systemctl reload nginx
sudo certbot --nginx -d api.ounje.app
sudo systemctl reload nginx
```

The nginx site terminates TLS and proxies traffic to `127.0.0.1:8080`.

## SSH access

The key you provided matches the local private key at `~/.ssh/id_ed25519`:

```text
SHA256:vvuetihhOhsWpDNyGm+62a7hTfGy1HtzKlC9y5Y6gl8
```

The droplet at `161.35.129.11` is not accepting it yet. Add this public key to the droplet user's `~/.ssh/authorized_keys` via the DigitalOcean console or control panel:

```text
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICMgMqjBnPuOH2IC/8QGs9Ol4vxcfb4ME95zUdqbnHvj davejaga@Mac
```
