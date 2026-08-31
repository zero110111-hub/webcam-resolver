# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Webcam Resolver is a Ruby Sinatra web service that resolves the true streaming URLs of publicly hosted webcams from providers that cycle their URLs. Used as a proxy for apps like Channels Custom Channels.

## Development Commands

```bash
# Run locally (port 4567)
bundle exec rackup --host 0.0.0.0 -p 4567

# Build Docker image
docker build -t webcam-resolver .

# Run via Docker (maps to port 8000)
docker run -it --name webcam-resolver -p 8000:4567 webcam-resolver
```

## Architecture

Single-file application (`webcam-resolver.rb`) with two endpoints:
- `GET /camera/:provider/:camera` - returns streaming URL as text
- `GET /stream/:provider/:camera` - redirects to streaming URL (surfline and surfchex serve a rewritten playlist instead, see below)

### Adding a Provider

Add a new `when` clause in `get_camera_url()`. Each provider has different resolution logic:
- **surfchex**: `:camera` is the cam's page slug (`/cams/<slug>/`) or its hls cam id. Maps slug to cam id via the `CAM_PAGES` map in the page markup, then signs `https://www.surfchex.com/hls/<cam id>/index.m3u8` with a stream pass
- **ipcamlive**: Fetches JSON API, constructs stream URL from response
- **surfline**: `:camera` is the cam's hex id (the part after `/cam/` in an embed URL like `https://embed.cdn-surfline.com/cam/<id>.html`). Scrapes that embed page for the `hls.cdn-surfline.com` m3u8 URL.

If the resolved URL can't be handed to a client as-is, also add the provider to
`PLAYLIST_HEADERS` -- that table is what makes `/stream` serve the playlist itself
instead of redirecting, and it carries whatever headers the CDN wants.

### Surfchex: stream passes

Surfchex signs its playlists. An unsigned `/hls/<cam id>/index.m3u8` returns `200` with a
short promo loop instead of the live stream, which is silent -- no error to notice. The
site's player fetches `https://surfchex.com/api/stream-pass?cam=<cam id>` (`{"st","e"}`,
`404 {"error":"unknown cam"}` for an unknown cam, which is what makes `/camera` return a
real 404) and appends `?st=<token>&e=<expiry>` to the playlist URL. Passes last about ten
minutes, so they're cached in-process until shortly before expiry; slug -> cam id
mappings are cached once resolved. Segments are signed the same way, but the tokens come
baked into the playlist's segment names, so nothing extra is needed to fetch them.

### Surfline and surfchex: why `/stream` is special-cased

Neither provider's playlist URL can simply be handed to a client. Surfline gates both the embed `.html` page and the `.m3u8` playlist behind a `Referer` header (a bare request returns `403`), so resolution and playlist fetches both send `Referer: https://www.surfline.com/`. The `.ts` segments, however, are served publicly. A plain redirect would `403` because the client can't supply that header. So `/stream/surfline` does not redirect — it fetches the playlist with the `Referer` itself and rewrites the relative segment names to absolute CDN URLs, so the client streams segments straight from Surfline's CDN (no proxying/buffering/disk on the server). The playlist is a live sliding window with no `#EXT-X-ENDLIST`, so the player keeps re-requesting `/stream/surfline/:camera` and always gets the current segments. `/camera/surfline` returns the raw (referer-gated) playlist URL.

Surfchex needs the same treatment for a different reason: its stream pass expires, so a
redirect would hand the client a URL that dies mid-stream. Serving the playlist ourselves
means every refresh is re-signed with a current pass. `/camera/surfchex` returns a signed
URL, so it too is only good until that pass expires.

Both go through `resolve_playlist`, which follows a master playlist to its highest-bitrate
variant before rewriting, so segment and `#EXT-X-MAP` URIs always come back absolute.

## Deployment

Docker image published to `ghcr.io/maddox/webcam-resolver` via GitHub Actions on push to main. Builds for both amd64 and arm64 platforms.
