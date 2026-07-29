# Mapbox basemaps

The maps use Mapbox when a token is set, and the free servers when it isn't.
Both paths work; the token only changes which one draws.

## Getting a token

1. **mapbox.com** → sign up → Account → **Tokens**.
2. Use the **default public token** (`pk.…`) or create one. Public tokens are
   designed to ship inside a client.
3. **Restrict it to your URLs** in the token's settings. A public token is
   readable by anyone with the app; a URL restriction is what stops it being
   used to spend your quota somewhere else.

## Setting it

| Where | How |
|---|---|
| Local build | `--dart-define=MAPBOX_TOKEN=pk...` |
| Web (GitHub Pages) | repo → Settings → Secrets → Actions → `MAPBOX_TOKEN` |
| iOS (Codemagic) | environment variable `MAPBOX_TOKEN` in the workflow |

Unset is fine — the app falls back to CARTO, OpenTopoMap and Esri, exactly as
before.

**It has to be the public token.** Only a `pk.` token is accepted. A secret
token (`sk.`) authenticates from a server and returns 401 to a client, so every
tile would fail and quietly fall back — a map that looks identical to having no
token at all.

## Checking which one a build shipped

Both basemaps draw a working map, so nothing on screen distinguishes them at a
glance. Two places say it outright:

- **In the app** — Map style sheet (the layers button), bottom line: *"Maps by
  Mapbox"* or *"Maps by OpenStreetMap"*. Outside release builds it also names
  why a token didn't take.
- **In the deploy log** — the *Basemap* step in `.github/workflows/deploy-web.yml`
  prints `Basemap: Mapbox` or the reason it isn't.

If it says OpenStreetMap after you set the secret, re-run the workflow: the
token is compiled in at build time, so an existing deploy doesn't pick it up.

## What changes with a token on

| Layer | Mapbox style | Free fallback |
|---|---|---|
| Standard | `mapbox/streets-v12` | CARTO Voyager |
| Dark | `mapbox/dark-v11` | CARTO `dark_all` + brightness lift |
| Satellite | `mapbox/satellite-streets-v12` | Esri World Imagery |
| Terrain | `mapbox/outdoors-v12` | OpenTopoMap |

The dark style is Mapbox's own, drawn to be read at night — so the brightness
lift that corrects CARTO's near-black tiles is not applied over it. That lift
stays for the fallback, where it is still needed.

## The fallback is load-bearing

Every Mapbox layer sets `fallbackUrl` to the free server that style used
before. A revoked token, an exhausted quota, or a style id Mapbox retires all
degrade to the old map instead of leaving a grey rectangle. All four fallback
URLs are checked in the test suite for shape and were confirmed to serve real
tiles.

## Cost

**Mapbox raster tiles are metered.** There is a free allowance and then it
bills per request — check the current rates on Mapbox's pricing page rather
than trusting a number written here, because it changes and the rest of this
project's economics are documented from real figures.

Two things worth knowing before turning it on:

- The free servers cost nothing, which is why they remain the default and the
  fallback. Turning Mapbox on is a deliberate spend.
- Map loads scale with *use*, not with users signing up — panning and zooming
  fetch tiles. Set a spending limit in the Mapbox dashboard.

## Attribution

Mapbox's terms require crediting both Mapbox and OpenStreetMap, which
`attributionFor()` does automatically once a token is set. Their terms also
ask for the Mapbox wordmark on the map; this ships the text credit only, so
check their current attribution requirements before release.
