# Self-Hosted AI Chat with SSO: Integrating Open WebUI and Keycloak Using OIDC

I've been running [Open WebUI](https://github.com/open-webui/open-webui) locally as a frontend for local LLMs and wanted to replace its built-in auth with a proper identity provider. Keycloak is an obvious choice — it's open source, battle-tested, and supports OpenID Connect out of the box. This post walks through the full Docker Compose setup plus a subtle bug I hit with logout that took some digging to find.

---

## Architecture Overview

```
Browser
  │
  ├──> Open WebUI  (localhost:3000)
  │        │
  │        │  OIDC Authorization Code Flow
  │        ▼
  └──> Keycloak    (keycloak.127.0.0.1.nip.io:9999)
           │
           ▼
        PostgreSQL  (Keycloak DB)
```

The trick of using `keycloak.127.0.0.1.nip.io` is that the subdomain resolves to `127.0.0.1` (courtesy of the public [nip.io](https://nip.io) wildcard DNS service), so we get a real hostname without editing `/etc/hosts`. This matters because Open WebUI needs to reach Keycloak at the same hostname from both inside the Docker network and from the host browser — two different namespaces that can't share `localhost`.

---

### Key config decisions

| Option | Value | Why |
|---|---|---|
| `KC_HOSTNAME` | `http://keycloak.127.0.0.1.nip.io:9999` | Reachable from both browser and container via `extra_hosts` |
| `KC_HOSTNAME_STRICT` | `false` | Allows health checks and internal traffic to bypass hostname check |
| `ENABLE_LOGIN_FORM` | `false` | Forces users straight to Keycloak; no Open WebUI login page shown |
| `ENABLE_OAUTH_SIGNUP` | `true` | Auto-provisions an Open WebUI user on first Keycloak login |
| `WEBUI_AUTH_SIGNOUT_REDIRECT_URL` | `http://localhost:3000/auth` | Where to land after logout |

---

## Keycloak Auto-Initialization Script

Rather than manually clicking through the Keycloak admin UI every time, I use a one-shot `curl`-based init container (`keycloak-init`) that runs the Keycloak Admin REST API to provision everything automatically on first boot.

The most important detail is setting `post.logout.redirect.uris` on the client. Keycloak uses this list to validate the `post_logout_redirect_uri` parameter in the end-session request. Without it, Keycloak rejects the redirect and the user is not sent back to the app cleanly.

---

## The Logout Bug [Open WebUI v0.8.12 has a bug]

Everything worked fine at first glance: login redirected to Keycloak, authentication completed, and the user landed in Open WebUI. But clicking **Log Out** in the WebUI did nothing useful — it simply cleared the local session and reloaded the Open WebUI login page, leaving the Keycloak SSO session fully alive. A refresh would auto-log the user back in silently.

Logging out directly from the Keycloak account console *did* work. So Keycloak itself was fine. Something in the WebUI-to-Keycloak logout handoff was broken.

### Debugging

Watching `docker compose logs -f webui` during a login attempt revealed the smoking gun:

```
ERROR | open_webui.utils.oauth:handle_callback:1693 -
  Failed to store OAuth session server-side: name 'cookie_expires' is not defined
```

This error is thrown during the OIDC callback (after a successful Keycloak login). Open WebUI's logout support works like this:

1. On login callback, it creates an `OAuthSession` record in the database and stores its ID in an `oauth_session_id` cookie on the browser.
2. On logout (`/api/v1/auths/signout`), it reads that cookie, looks up the stored token, reads the `end_session_endpoint` from the OIDC discovery document, and redirects the browser to Keycloak's logout URL with the `id_token_hint` and `post_logout_redirect_uri` parameters.

Because step 1 crashed before setting the cookie, step 2 had no session to look up, and the signout endpoint fell back to just returning `WEBUI_AUTH_SIGNOUT_REDIRECT_URL` directly — bypassing Keycloak entirely.

### Root Cause

In `open_webui/utils/oauth.py`, the session cookie is set like this (Open WebUI v0.8.12):

```python
response.set_cookie(
    key='oauth_session_id',
    value=session.id,
    httponly=True,
    samesite=WEBUI_AUTH_COOKIE_SAME_SITE,
    secure=WEBUI_AUTH_COOKIE_SECURE,
    **({'max_age': cookie_max_age, 'expires': cookie_expires} if cookie_max_age is not None else {}),
)
```

`cookie_max_age` is defined a few lines earlier:

```python
expires_delta = parse_duration(auth_manager_config.JWT_EXPIRES_IN)
cookie_max_age = int(expires_delta.total_seconds()) if expires_delta else None
```

But `cookie_expires` is **never assigned**. It's a regression — the variable was presumably removed or renamed during a refactor but its reference in the `oauth_session_id` cookie setter was missed. The `token` cookie above it only uses `max_age` correctly; only the session cookie has the dangling `expires` reference.

Because the code path is wrapped in a broad `try/except`, the exception is swallowed and logged as a warning rather than bubbling up to crash the login. The user sees a successful login, has no idea anything went wrong, and only notices the problem later when logout silently fails.

### The Fix

The fix is simply to remove the undefined `cookie_expires` argument:

**Before (broken):**
```python
**({'max_age': cookie_max_age, 'expires': cookie_expires} if cookie_max_age is not None else {}),
```

**After (fixed):**
```python
**({'max_age': cookie_max_age} if cookie_max_age is not None else {}),
```

Since we're using an upstream Docker image and can't rebuild it from source on every deploy, the most practical workaround is to patch the file at container startup before the app process begins. This is done by overriding the `command` in `docker-compose.yml`:

```yaml
  webui:
    image: ghcr.io/open-webui/open-webui:latest
    command:
      - /bin/sh
      - -c
      - >
        sed -i "s/, 'expires': cookie_expires//g" /app/backend/open_webui/utils/oauth.py &&
        exec bash start.sh
```

The `sed` runs first, removes the undefined argument in-place, then hands off to the normal startup script. It's idempotent — if the upstream image is ever fixed and `cookie_expires` is no longer present, the pattern simply won't match and nothing breaks.

After redeploying:

```sh
docker compose up -d webui
```

Login, then logout from the WebUI — the browser is now redirected to Keycloak's end-session endpoint, the SSO session is terminated, and the user lands on `http://localhost:3000/auth`. No silent re-login on refresh.

---

## Access URLs

| Service | URL | Credentials |
|---|---|---|
| Open WebUI | http://localhost:3000 | SSO via Keycloak |
| Keycloak Admin | http://keycloak.127.0.0.1.nip.io:9999/admin | admin / admin |
| Keycloak Account | http://keycloak.127.0.0.1.nip.io:9999/realms/master/account | mohan / mohan |

---

## Starting Fresh

```sh
# First boot (everything auto-provisioned)
docker compose up -d

# Check init logs
docker compose logs -f keycloak-init

# Reset everything (wipes Keycloak DB)
docker compose down -v && docker compose up -d
```

---

## Takeaways

- **nip.io** solves the hostname split-brain problem between browser and container without touching `/etc/hosts`.
- **`post.logout.redirect.uris`** on the Keycloak client is mandatory for WebUI logout to validate the redirect destination correctly.
- **Open WebUI v0.8.12 has a bug** where `cookie_expires` is referenced but never defined when setting the `oauth_session_id` cookie. This silently breaks the entire OIDC session-backed logout flow.
- Wrapping the fix in the Docker Compose startup `command` is a clean way to patch an upstream image without forking it — especially useful for self-hosted setups that track `latest`.

A proper upstream fix would be a one-line PR against `open_webui/utils/oauth.py`. Until that's merged and released, the startup-patch approach works reliably.
