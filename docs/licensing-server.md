# Licensing Server (Docker + Local Activation Workflow)

Glitcho ships with a reference activation service and host-ready Docker deployment for license validation.

> Note: For storefront + payments + customer/admin license management, use the separate commerce stack documented in `docs/commerce-site.md`. This document covers the lightweight validation-only service.

## Components

- Reference server implementation: `Scripts/license_server_example.mjs`
- Docker deployment:
  - `deploy/license-server/Dockerfile`
  - `deploy/license-server/docker-compose.yml`
  - `deploy/license-server/.env.example`
  - `deploy/license-server/data/license-keys.example.json`
- Startup helpers:
  - `Scripts/start_activation_server.sh`
  - `Scripts/stop_activation_server.sh`

## Quick Start

Start activation server:

```bash
./Scripts/start_activation_server.sh
```

Stop activation server:

```bash
./Scripts/stop_activation_server.sh
```

Optional (write defaults directly for local app bundle):

```bash
./Scripts/start_activation_server.sh --apply-app-defaults --bundle-id com.glitcho.app
```

## What `start_activation_server.sh` does

- Ensures Docker daemon is running.
- Creates `deploy/license-server/.env` from template if missing.
- Creates `deploy/license-server/data/license-keys.json` from template if missing.
- Generates P256 private key if missing:
  - `deploy/license-server/data/license-private.pem`
- Derives and saves public key outputs:
  - `deploy/license-server/data/license-public.pem`
  - `deploy/license-server/data/license-public-raw.b64`
- Starts compose stack and waits for `/health`.
- Prints the Base64 raw public key to paste into app settings.

## Runtime Endpoints

- `GET /health`
- `GET /plans`
- `POST /license/validate`

Validation request body:

```json
{
  "key": "PRO-LIFETIME-TEST",
  "device_id": "device-123",
  "app_version": "1.3.0"
}
```

Validation response body:

```json
{
  "valid": true,
  "expires_at": null,
  "entitlements": ["recording"],
  "plan": "lifetime",
  "device_id": "device-123",
  "issued_at": "2026-02-13T00:00:00.000Z",
  "signature_version": 2,
  "signature": "<base64-der-signature>"
}
```

## Signature Contract

Client verifies this canonical payload string (`v2`):

```text
v=2;valid=<true|false>;expires_at=<iso8601-or-empty>;entitlements=<sorted,comma-separated>;device_id=<device-id>;issued_at=<iso8601>;plan=<annual|lifetime|empty>
```

Compatibility signatures are only for local/dev. Production should always provide a signing key and app-side public key pin.

## Config Files and Environment

`deploy/license-server/.env`:
- `LICENSE_SERVER_PORT` (host port mapped to container `8787`)

Container environment (`docker-compose.yml`):
- `PORT=8787`
- `LICENSE_PRIVATE_KEY_PEM_FILE=/data/license-private.pem`
- `LICENSE_KEY_STORE_FILE=/data/license-keys.json`
- `LICENSE_INCLUDE_DEFAULT_TEST_KEYS=false` (recommended outside local dev)
- `LICENSE_ALLOW_COMPAT_SIGNATURE=false` (recommended)

License key store format (`deploy/license-server/data/license-keys.json`):

```json
{
  "PRO-LIFETIME-TEST": {
    "entitlements": ["recording"],
    "expiresAt": null,
    "revoked": false,
    "plan": "lifetime"
  }
}
```

## Glitcho App Settings

Open `Settings -> Pro License` and set:
- `License key`
- `Validation server URL` (example: `http://127.0.0.1:8787`)
- `Validation public key (Base64)` (raw key from startup script output)

Expected app behavior:
- Valid server response with `recording` entitlement unlocks recording + Pro video features.
- Failed validation uses cached offline grace window if available.
- When build pinning is enabled, server URL/public key fields are read-only in app settings.

## Build-Time Pinning (Recommended)

`Scripts/make_app.sh` supports activation pinning:
- `LICENSE_ALLOW_USER_OVERRIDE=false`
- `LICENSE_PINNED_SERVER_URL=https://license.example.com`
- `LICENSE_PINNED_PUBLIC_KEY=<base64-raw-p256-public-key>`

When pinned, users cannot switch to another validation server or public key from app settings.

## Local Test Keys

Default sample keys in template store:
- `PRO-ANNUAL-TEST`
- `PRO-LIFETIME-TEST`

## Operational Notes

- Use `--volumes` with stop script to remove compose volumes:

```bash
./Scripts/stop_activation_server.sh --volumes
```

- Keep `license-private.pem` secure.
- Rotate keys by replacing private key + distributing new public key to clients.
- Prefer TLS termination in front of the activation service for non-local deployments.
