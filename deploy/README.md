# Deployment

Pipeline: push to `main` → **CI** (lint/test/typecheck/build) → **Docker** (build + push to
`ghcr.io/<owner>/<repo>/api`) → **Deploy** (SSH to the VPS, `docker compose pull && up -d --wait`).

Manual rollback: run the **Deploy** workflow with an older `tag` (e.g. `sha-abc1234`).

## One-time VPS setup

1. **Docker + Compose v2**

   ```bash
   curl -fsSL https://get.docker.com | sh
   docker compose version   # must print v2.x
   ```

2. **Deploy user and stack directory**

   ```bash
   sudo adduser --disabled-password --gecos "" deploy
   sudo usermod -aG docker deploy
   sudo mkdir -p /opt/toxicreactor
   sudo chown deploy:deploy /opt/toxicreactor
   ```

   Membership in the `docker` group is root-equivalent. Use a dedicated `deploy`
   user whose only purpose is this stack — do not reuse a login you also use
   interactively.

3. **GHCR pull access.** The `GITHUB_TOKEN` from CI is short-lived and cannot be
   reused on the server. Either make the package public (Package settings →
   Change visibility), or log in once with a PAT that has only `read:packages`:

   ```bash
   su - deploy
   echo "$GHCR_PAT" | docker login ghcr.io -u <github-username> --password-stdin
   ```

   The credentials land in `~/.docker/config.json` and persist across reboots.

4. **Environment file**

   ```bash
   # from your machine
   scp deploy/.env.example deploy@<host>:/opt/toxicreactor/.env
   # on the server
   chmod 600 /opt/toxicreactor/.env && nano /opt/toxicreactor/.env
   ```

5. **SSH key for CI** (generate locally, never reuse a personal key):

   ```bash
   ssh-keygen -t ed25519 -f deploy_key -N "" -C "github-actions-deploy"
   ssh-copy-id -i deploy_key.pub deploy@<host>
   ssh-keyscan -p 22 <host>          # output goes into VPS_SSH_KNOWN_HOSTS
   ```

6. **Reverse proxy** on the host, terminating TLS and forwarding to
   `127.0.0.1:3000`. Minimal nginx server block:

   ```nginx
   location / {
     proxy_pass http://127.0.0.1:3000;
     proxy_set_header Host $host;
     proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
     proxy_set_header X-Forwarded-Proto $scheme;
   }
   ```

## GitHub configuration

Repository secrets (Settings → Secrets and variables → Actions):

| Secret                | Value                                     |
| --------------------- | ----------------------------------------- |
| `VPS_HOST`            | VPS IP or hostname                        |
| `VPS_USER`            | `deploy`                                  |
| `VPS_PORT`            | SSH port, optional — defaults to `22`     |
| `VPS_SSH_KEY`         | full contents of the private `deploy_key` |
| `VPS_SSH_KNOWN_HOSTS` | `ssh-keyscan` output for the host         |

Repository variable: `DEPLOY_URL` (e.g. `https://api.example.com`) — enables the
post-deploy smoke test and shows the link on the environment.

## Assumptions baked into the compose file

- **Runtime image is node-based** (`node:22-slim`), because the healthcheck shells
  out to `node -e`. If the runtime ends up being `oven/bun`, swap `node` for `bun`
  in `docker-compose.yml`.
- **The app exposes `GET /health`** returning 200. `docker compose up --wait`
  blocks on that healthcheck, which is what makes a broken release detectable
  before it is marked as deployed. In NestJS:

  ```bash
  bun add @nestjs/terminus
  ```

  Without that endpoint the container never reports healthy and every deploy
  fails after 120s.

- **The container listens on port 3000** inside the network namespace.

## Open decision: failure policy

`remote-deploy.sh` has an unimplemented `handle_failed_deploy()`. The two sane
options:

- **Auto-rollback** — `docker compose` back to the tag in `.live-image`. Site
  stays up, but the broken revision is now invisible in production and the git
  state no longer matches what is running.
- **Fail loud** — leave the failed container stopped and page a human. Honest
  state, but downtime until someone reacts.

Note that `up -d --wait` replaces the old container _before_ waiting for health,
so a failed deploy means downtime either way. True zero-downtime needs two
container slots and a proxy switch — out of scope for a single VPS.
