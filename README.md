# Spexgram Deploy

Docker Compose setup for running Spexgram (API, web, MySQL, the media server and Immich with its machine learning,
PostgreSQL and Valkey) on a single host, next to [spexregister-deploy][1] and [fgv-infra-deploy][2], which runs
Keycloak, the shared network `fgv-<DEPLOY_ENV>`, Umami, Mailpit (staging) and what serves the media hostname: Tailscale
Funnel on staging, the edge proxy on production.

Cloudflare and Tailscale are used on staging only. Production uses neither: its own reverse proxy serves `WEB_HOST` and
`MEDIA_HOST` (see *Production*).

```
Staging:
Browser ──https──▶ Cloudflare ──tunnel──▶ cloudflared ──▶ spexgram-web:3000                         (WEB_HOST)
Browser ──https──▶ Tailscale Funnel ──▶ tailnet-spexgram-media (fgv-infra-deploy) ──▶ spexgram-media:80  (MEDIA_HOST)

spexgram-web ──▶ spexgram-api ──▶ spexgram-mysql
                 spexgram-api ──x-api-key──▶ immich-server:2283        (internal network "immich" only)
spexgram-media ──x-api-key (read only)──▶ immich-server:2283           (internal network "immich" only)
immich-server ──▶ immich-machine-learning, immich-postgres, immich-valkey
spexgram-api ──▶ keycloak-server, spexregister-api, mailpit/SMTP      (fgv network)
```

- The web goes through the Cloudflare Tunnel like Spexregister, and serves visitors without login too: what editors
  have made public. Uploads are tus chunks of at most 50 MB through the web, below the request limit of Cloudflare's
  free plan. The API has no public hostname: the web calls it on the shared network.
- Photos and videos don't go through Cloudflare, whose CDN terms restrict serving video on the free plans. They come from
  `spexgram-media`: nginx, which checks the signed, expiring address (`media/default.conf.template`, nginx
  `secure_link`) and passes the request to Immich's matching endpoint with a read-only API key. It caches thumbnails and
  previews, passes byte ranges for videos, answers only `GET`, `HEAD` and `OPTIONS`, allows CORS only from
  `https://WEB_HOST`, and leaves the signature out of its log.
- Immich is pinned (`IMMICH_VERSION`) and on an internal network only. Its web interface is not exposed; admins reach it
  through an SSH tunnel, e.g. `ssh -L 2283:<immich-server's address on the immich network>:2283 host`.

## Files

| File                          | Purpose                                                                    |
|-------------------------------|----------------------------------------------------------------------------|
| `compose.yaml`                | `spexgram-mysql`, `spexgram-api`, `spexgram-web`, `spexgram-media`, `immich-server`, `immich-machine-learning`, `immich-postgres`, `immich-valkey` |
| `compose.tunnel.yaml`         | `cloudflared` connector for `WEB_HOST`, staging only                       |
| `media/default.conf.template` | The media server's nginx configuration                                     |
| `staging.env.example`, `production.env.example` | Templates for `.env`                                     |
| `bin/init-secrets.sh`         | Generates secrets into `secrets/` and copies the client secrets from `fgv-infra-deploy` |
| `bin/backup-db.sh`            | Dumps Spexgram's and Immich's databases into `backups/`, pruning dumps older than 14 days |
| `bin/backup-media.sh`         | Backs up Immich's originals and its own database dumps with restic        |

| `.env` variable | Image                                    | Source repo           |
|-----------------|------------------------------------------|-----------------------|
| `API_IMAGE`     | `bloomper/fgv-spexgram-server`           | `fgv-spexgram-server` |
| `WEB_IMAGE`     | `bloomper/fgv-spexgram-web`              | `fgv-spexgram-web`    |
| `IMMICH_VERSION`| `ghcr.io/immich-app/immich-server`, `immich-machine-learning` | Immich        |

## Immich's API keys

Immich makes an API key's secret itself and shows it only once, so the deployment cannot generate the keys. The API
creates them when it starts (and again if they are missing, invalid or have other permissions), each with only the
permissions it needs, and keeps them as files in `data/immich-keys/`:

| File              | Permissions                                       | Used by                                   |
|-------------------|---------------------------------------------------|-------------------------------------------|
| `api.key`         | asset read, view, download, upload, update, delete; jobs; queues; server about and storage | `spexgram-api` |
| `media.key`       | `asset.read`, `asset.view`, `asset.download`      | `spexgram-media`, which mounts the folder read-only and waits for the file at start |
| `bulk-import.key` | `asset.upload`                                    | Admins' bulk imports with Immich's command line tool (5.6 of the spec) |

The API also creates Immich's admin, Spexgram's system user, with the password in `secrets/API_IMMICH_ADMIN_PASSWORD`,
and turns off the storage template, face recognition, Immich's own trash and its version check, and picks the
multilingual CLIP model `IMMICH_CLIP_MODEL`. If a key is replaced, restart `spexgram-media` to read the new one:
`docker compose restart spexgram-media`.

A bulk import runs on the host against Immich on the internal network, e.g.
`docker run --rm --network fgv-spexgram-<DEPLOY_ENV>_immich -v /path/to/photos:/import ghcr.io/immich-app/immich-cli
upload --recursive /import` with `IMMICH_INSTANCE_URL=http://immich-server:2283/api` and `IMMICH_API_KEY` from
`data/immich-keys/bulk-import.key`. The API lists the new items as unsorted within minutes.

## 1. Host

- `fgv-infra-deploy` running with a realm that has the `fgv-spexgram` and `fgv-spexgram-service` clients. Its `.env`
  names this deployment's `WEB_HOST` as `SPEXGRAM_WEB_HOST`. On staging, its tailnet containers (`compose.tailnet.yaml`)
  run; on production, its edge proxy (`compose.edge.yaml`, whose `.env` names `MEDIA_HOST` as `SPEXGRAM_MEDIA_HOST`) or
  production's own reverse proxy.
- `spexregister-deploy` running a `spexregister-server` release that lets `fgv-spexgram-service` use the `MEDIA` role.
- Disk for the archive: a photo is 3–10 MB plus about 10 % for Immich's thumbnails and previews.
- Memory for Immich's machine learning: a few GB for the multilingual search model (`IMMICH_ML_MEMORY`, `IMMICH_ML_CPUS`).

## 2. Cloudflare (staging only)

1. Create a tunnel (Networking → Tunnels → *Create a tunnel* → Cloudflared), e.g. `fgv-spexgram-staging`, and copy
   its token.
2. On the tunnel's **Routes** tab, add a published application for `WEB_HOST` with the service URL
   `http://spexgram-web:3000`.
3. Don't restrict `WEB_HOST` with Cloudflare Access: Spexgram has a public side.
4. Create a Turnstile widget for `WEB_HOST` for production (Turnstile → *Add widget*); staging uses Cloudflare's test
   keys, which always pass. Put the site key in `TURNSTILE_SITE_KEY` and the secret in
   `secrets/API_TURNSTILE_SECRET_KEY`.

## 3. Checkout and configuration

```shell
git clone https://github.com/bloomper/fgv-spexgram-deploy.git
cd fgv-spexgram-deploy

cp staging.env.example .env          # set the hostnames
bin/init-secrets.sh                  # copies the client secrets from ../fgv-infra-deploy
nano secrets/cloudflared.env         # staging only: TUNNEL_TOKEN=<token from step 2>
mkdir -p data/api/log_data data/uploads data/immich-keys data/immich
sudo chown -R 1000:1000 data/api data/uploads data/immich-keys
docker compose up -d
```

| Variable                          | Purpose                                                                      |
|-----------------------------------|------------------------------------------------------------------------------|
| `WEB_HOST`                        | Spexgram's address                                                           |
| `MEDIA_HOST`                      | The media hostname: on staging the Funnel name of `tailnet-spexgram-media`   |
| `KEYCLOAK_HOST`, `KEYCLOAK_REALM` | Keycloak's public address and realm                                          |
| `IMMICH_VERSION`                  | The pinned Immich release                                                    |
| `IMMICH_CLIP_MODEL`               | The multilingual model for search by content                                 |
| `IMMICH_ML_CPUS`, `IMMICH_ML_MEMORY` | Limits for Immich's machine learning                                      |
| `MAX_UPLOAD_SIZE`                 | The largest upload the deployment accepts; admins can lower it in the web    |
| `MEDIA_CACHE_SIZE`                | The media server's cache of thumbnails and previews                          |
| `SPEXREGISTER_GRAPHQL_URL`        | Spexregister's GraphQL endpoint on the shared network                        |
| `SPEXREGISTER_WEB_URL`, `FGV_REVIVAL_WEB_URL`, `SPEXIFY_WEB_URL`, `SPEXFLIX_WEB_URL`, `ARCHIVE_WEB_URL` | The other applications, for links and the application switcher |
| `TURNSTILE_SITE_KEY`              | Cloudflare Turnstile's site key, for visitors' reports (`NEXT_PUBLIC_TURNSTILE_SITE_KEY` in the web) |
| `SMTP_*`, `MAIL_FROM`             | The mail server for notifications to editors, reporters and contributors     |
| `API_IMPORT_SAMPLE_DATA`          | `true` on staging only: replaces all data, Immich's assets included, at every start |
| `API_SAMPLE_DATA_SIZE`            | `small` (about 15 albums, 300 items) or `large` (about 300 albums, 20,000 items) |
| `SUPPORT_EMAIL`, `FEEDBACK_EMAIL` | Shown on the Support and About pages                                         |
| `UMAMI_WEBSITE_ID`                | Umami website for `WEB_HOST`; without it the web sends no statistics         |

| Secret                            | Purpose                                                                      |
|-----------------------------------|------------------------------------------------------------------------------|
| `MYSQL_ROOT_PASSWORD`, `MYSQL_USER_PASSWORD` | Spexgram's database                                               |
| `API_MEDIA_SIGNING_KEY`           | Shared by the API, which signs media addresses, and `spexgram-media`, which checks them. Changing it invalidates every address handed out, which only makes open pages ask for new ones |
| `IMMICH_DB_PASSWORD`              | Immich's PostgreSQL                                                          |
| `API_IMMICH_ADMIN_PASSWORD`       | Immich's admin, which the API creates; also for logging in to Immich's web interface through the SSH tunnel |
| `API_TURNSTILE_SECRET_KEY`        | Cloudflare Turnstile's secret                                                |
| `KEYCLOAK_CLIENT_SECRET`, `KEYCLOAK_SERVICE_CLIENT_SECRET` | `fgv-spexgram` (the web) and `fgv-spexgram-service` (Spexregister, editors' email addresses) |
| `KEYCLOAK_ADMIN_CLIENT_SECRET`, `SAMPLE_USER_PASSWORD` | Only with sample data: `fgv-admin`, which grants the sample users roles |
| `SMTP_PASSWORD`                   | The mail server's password, when `SMTP_AUTH=true`                            |
| `WEB_AUTH_SECRET`                 | The web's session secret                                                     |

For visitor statistics, run `bin/configure-umami.sh` in `fgv-infra-deploy` (see *Umami* in its README), which adds a
website `SPEXGRAM_NAME` for `SPEXGRAM_WEB_HOST`; put its ID in `UMAMI_WEBSITE_ID`.

## Storage

| Folder                  | Content                                                      | Back up |
|-------------------------|--------------------------------------------------------------|---------|
| `data/immich/upload/`, `data/immich/library/` | Originals                              | Yes, `bin/backup-media.sh` |
| `data/immich/thumbs/`, `data/immich/encoded-video/` | Thumbnails, previews, transcoded videos | No; Immich makes them again |
| `data/immich/backups/`  | Immich's own nightly database dumps                          | Yes, `bin/backup-media.sh` |
| `data/immich-keys/`     | Immich's API keys, created by the API                        | No; the API makes new ones |
| `data/uploads/`         | Unfinished uploads to Spexgram, deleted after 24 hours       | No      |
| `backups/`              | `bin/backup-db.sh`'s dumps of both databases                 | Copy off the host |

## First start

The API creates its tables and sets Immich up; on staging (`API_IMPORT_SAMPLE_DATA=true`) it then replaces all data
with sample data built on Spexregister's sample spex, uploads the generated photos and videos to Immich and waits for
them to be processed; see *Sample data* in `fgv-spexgram-server`'s getting started guide for the users. Spexregister
deletes all Keycloak users on every start of its sample import, so restart Spexgram after it:
`docker compose restart spexgram-api`.

## Production

- `.env` from `production.env.example`: `DEPLOY_ENV=production` (the API then refuses sample data),
  `API_IMPORT_SAMPLE_DATA=false`, and images pinned to release versions.
- No Cloudflare: `COMPOSE_FILE` leaves out `compose.tunnel.yaml`. Production's own reverse proxy terminates TLS and
  forwards `WEB_HOST` to `spexgram-web:3000` (tus chunks of up to 50 MB) and `MEDIA_HOST` to `spexgram-media:80` (GET,
  HEAD and OPTIONS only), as `fgv-infra-deploy`'s *Edge proxy* describes.
- `bin/backup-db.sh` and `bin/backup-media.sh` in cron, with `backups/` copied off the host.
- Upgrading Immich: run `fgv-spexgram-server`'s integration tests against the new version first (its `IMMICH_VERSION`
  and the checked-in OpenAPI document), then change `IMMICH_VERSION` here.

## Troubleshooting

| Symptom                                           | Cause                                                                       |
|---------------------------------------------------|-----------------------------------------------------------------------------|
| Images show placeholders; `MEDIA_HOST` answers 403 | `API_MEDIA_SIGNING_KEY` differs between the API and `spexgram-media`, or the clocks differ |
| `MEDIA_HOST` answers 410                          | The page has been open more than four hours; reloading it gets new addresses |
| `MEDIA_HOST` answers 404 for a valid address      | Immich has not made the thumbnail yet, or `media.key` is stale: `docker compose restart spexgram-media` |
| `spexgram-media` keeps logging "waiting for spexgram-api to create media.key" | The API cannot reach or set up Immich; see its log |
| Items stay "processing"                           | Immich's queues are stuck; see *Immich* under *Admin* in the web            |
| Visitors' reports fail                            | `API_TURNSTILE_SECRET_KEY` doesn't match `TURNSTILE_SITE_KEY`, or Cloudflare can't be reached |
| Login fails with "Invalid parameter: redirect_uri" | `SPEXGRAM_WEB_HOST` in `fgv-infra-deploy` doesn't match `WEB_HOST`         |

[1]: https://github.com/bloomper/spexregister-deploy
[2]: https://github.com/bloomper/fgv-infra-deploy
