# Commerce Website (Current Scope)

The website is intentionally simplified for now.

## Purpose

- Promote Glitcho with screenshots and feature highlights.
- Let users download the app `.zip`.
- Provide a donation option (PayPal):
  - `https://paypal.me/jcproulx`

## Active Endpoints

- `GET /` - landing page (promo + screenshots + donate)
- `GET /download` - download page
- `GET /download/latest` - serves local zip or redirects to `DOWNLOAD_URL`
- `GET /health` - service health
- `POST /license/validate` - app license validation contract (kept for app compatibility)

## Removed/Retired Web Flows

The following website sections are retired and return redirect/410 responses:

- Sign in / account / admin
- Pricing / checkout / payment portal
- Auth/account/admin API endpoints

## Run

Start:

```bash
./Scripts/start_commerce_site.sh
```

Stop:

```bash
./Scripts/stop_commerce_site.sh
```

## Configuration

In `deploy/commerce-site/.env`:

- `DOWNLOAD_URL` (optional direct hosted zip URL)
- `DOWNLOAD_FILE_PATH` (fallback local zip path, default `/data/Glitcho.zip`)
- `PORT` via `COMMERCE_SITE_PORT` in compose env

## License Validation

`POST /license/validate` remains active and uses the same response signature contract expected by the macOS app.
