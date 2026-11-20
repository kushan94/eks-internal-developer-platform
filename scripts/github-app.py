#!/usr/bin/env python3
"""Create the platform's GitHub Apps.

  argocd     Lets Argo CD read repositories (Contents: read)
  runner     Lets the VPC runner register itself with this repo (Administration: write)
  backstage  Signs users in to Backstage and opens its pull requests (Contents and
             Pull requests: write)

Uses GitHub's app manifest flow: this script defines the app, you click
Create in the browser, and GitHub hands the app's ID and private key back to
this script. Credentials are saved under ~/.config/eks-idp with owner-only
permissions and are never printed.

  scripts/github-app.py create [argocd|runner|backstage]   Create the app (opens your browser)
  scripts/github-app.py secret [argocd|runner|backstage]   After installing the app, write
                                                           the JSON for its Secrets Manager secret

Only uses the Python standard library and the openssl command.
"""

import base64
import http.server
import json
import os
import secrets
import subprocess
import sys
import time
import urllib.parse
import urllib.request
import webbrowser
from pathlib import Path

PORT = 8765
CONFIG_DIR = Path.home() / ".config" / "eks-idp"
API = "https://api.github.com"

PROFILES = {
    "argocd": {
        "name": "{owner}-idp-argocd",
        "description": "Lets Argo CD read repositories for the internal developer platform.",
        "permissions": {"contents": "read", "metadata": "read"},
        "file_stem": "github-app",
        "secret_id": "idp/argocd/github-app",
        "install_hint": "Install it on all repos, or the ones Argo CD may read",
    },
    "runner": {
        "name": "{owner}-idp-runner",
        "description": "Lets the platform's VPC runner register with the platform repo.",
        "permissions": {"administration": "write", "metadata": "read"},
        "file_stem": "github-runner-app",
        "secret_id": "idp/github/runner-app",
        "install_hint": "Install it ONLY on the platform repo, because it can administer the repos it's installed on",
    },
    "backstage": {
        "name": "{owner}-idp-backstage",
        "description": "Signs users in to the platform's Backstage portal and opens its pull requests.",
        # Commit statuses: read lets Backstage resolve a branch's latest commit
        # when it reads catalog files with a glob, such as catalog/**/*.yaml.
        "permissions": {"contents": "write", "pull_requests": "write", "statuses": "read", "metadata": "read"},
        "callback_urls": ["https://backstage.{domain}/api/auth/github/handler/frame"],
        "oauth": True,
        "file_stem": "github-backstage-app",
        "secret_id": "idp/backstage/github-app",
        "install_hint": "Install it ONLY on the platform repo, where Backstage reads the catalog and opens pull requests",
    },
}

KEY_FILE = APP_FILE = SECRET_FILE = PROFILE = None


def use_profile(name):
    global KEY_FILE, APP_FILE, SECRET_FILE, PROFILE
    if name not in PROFILES:
        sys.exit(f"Unknown app '{name}'. Choose one of: {', '.join(PROFILES)}")
    PROFILE = PROFILES[name]
    stem = PROFILE["file_stem"]
    KEY_FILE = CONFIG_DIR / f"{stem}.pem"
    APP_FILE = CONFIG_DIR / f"{stem}.json"
    SECRET_FILE = CONFIG_DIR / f"{stem}-secret.json"


use_profile("argocd")


def write_private(path, data):
    CONFIG_DIR.mkdir(mode=0o700, parents=True, exist_ok=True)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(data)


def api(method, path, token=None, body=None):
    request = urllib.request.Request(f"{API}{path}", method=method, data=body)
    request.add_header("Accept", "application/vnd.github+json")
    if token:
        request.add_header("Authorization", f"Bearer {token}")
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def create(owner, repo_url):
    if KEY_FILE.exists():
        sys.exit(f"{KEY_FILE} already exists. Delete it first to create another app.")
    state = secrets.token_urlsafe(16)
    manifest = {
        "name": PROFILE["name"].format(owner=owner),
        "url": repo_url,
        "description": PROFILE["description"],
        "public": False,
        "redirect_url": f"http://localhost:{PORT}/callback",
        "hook_attributes": {"url": "https://example.com/unused", "active": False},
        "default_permissions": PROFILE["permissions"],
    }
    if PROFILE.get("callback_urls"):
        # The platform's domain isn't committed. Set it for the Backstage app.
        domain = os.environ.get("PLATFORM_DOMAIN")
        if not domain:
            sys.exit("Set PLATFORM_DOMAIN to the platform's domain, for example idp.example.com.")
        manifest["callback_urls"] = [url.format(domain=domain) for url in PROFILE["callback_urls"]]
        manifest["request_oauth_on_install"] = False
    form = f"""<!doctype html><html><body>
<form id="f" method="post" action="https://github.com/settings/apps/new?state={state}">
<input type="hidden" name="manifest" value='{json.dumps(manifest).replace("'", "&#39;")}'>
</form><p>Opening GitHub...</p><script>document.getElementById("f").submit()</script>
</body></html>"""
    result = {}

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def reply(self, text):
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            self.wfile.write(text.encode())

        def do_GET(self):
            url = urllib.parse.urlparse(self.path)
            query = urllib.parse.parse_qs(url.query)
            if url.path == "/":
                self.reply(form)
            elif url.path == "/callback":
                if query.get("state", [""])[0] != state or "code" not in query:
                    self.reply("<p>Unexpected callback. Close this tab and run the script again.</p>")
                    return
                app = api("POST", f"/app-manifests/{query['code'][0]}/conversions")
                write_private(KEY_FILE, app["pem"])
                details = {"id": app["id"], "slug": app["slug"], "html_url": app["html_url"]}
                if PROFILE.get("oauth"):
                    details["clientId"] = app["client_id"]
                    details["clientSecret"] = app["client_secret"]
                    # The webhook is inactive, but Backstage's config still expects a secret.
                    details["webhookSecret"] = app.get("webhook_secret") or secrets.token_hex(32)
                write_private(APP_FILE, json.dumps(details, indent=2))
                result.update(app)
                self.reply(f"<p>Created <b>{app['slug']}</b>. You can close this tab and return to the terminal.</p>")

    server = http.server.HTTPServer(("127.0.0.1", PORT), Handler)
    print(f"Opening http://localhost:{PORT} in your browser. Review the app and click Create.")
    webbrowser.open(f"http://localhost:{PORT}/")
    deadline = time.time() + 600
    server.timeout = 5
    while not result and time.time() < deadline:
        server.handle_request()
    if not result:
        sys.exit("Timed out after 10 minutes without a callback from GitHub.")
    print(f"Created GitHub App {result['slug']} (ID {result['id']}).")
    print(f"Private key saved to {KEY_FILE}")
    print(f"Next, {PROFILE['install_hint']}: https://github.com/apps/{result['slug']}/installations/new")
    print(f"Then run: scripts/github-app.py secret {sys.argv[2] if len(sys.argv) > 2 else 'argocd'}")


def jwt(app_id):
    def b64(data):
        return base64.urlsafe_b64encode(data).rstrip(b"=").decode()

    now = int(time.time())
    header = b64(json.dumps({"alg": "RS256", "typ": "JWT"}).encode())
    payload = b64(json.dumps({"iat": now - 60, "exp": now + 540, "iss": str(app_id)}).encode())
    signature = subprocess.run(
        ["openssl", "dgst", "-sha256", "-sign", str(KEY_FILE)],
        input=f"{header}.{payload}".encode(), capture_output=True, check=True,
    ).stdout
    return f"{header}.{payload}.{b64(signature)}"


def secret():
    if not APP_FILE.exists() or not KEY_FILE.exists():
        sys.exit("Run `scripts/github-app.py create` first.")
    app = json.loads(APP_FILE.read_text())
    installations = api("GET", "/app/installations", token=jwt(app["id"]))
    if not installations:
        sys.exit(f"The app isn't installed yet: https://github.com/apps/{app['slug']}/installations/new")
    if len(installations) > 1:
        print("More than one installation found; using the first:", ", ".join(i["account"]["login"] for i in installations))
    installation = installations[0]
    value = {
        "appId": str(app["id"]),
        "installationId": str(installation["id"]),
        "privateKey": KEY_FILE.read_text(),
    }
    if PROFILE.get("oauth"):
        value.update({k: app[k] for k in ("clientId", "clientSecret", "webhookSecret")})
    write_private(SECRET_FILE, json.dumps(value))
    print(f"Installed on {installation['account']['login']} ({installation['repository_selection']} repositories), installation ID {installation['id']}.")
    print(f"Secret value written to {SECRET_FILE}. Store it with:")
    print(f"  aws secretsmanager put-secret-value --secret-id {PROFILE['secret_id']} --secret-string file://{SECRET_FILE}")


if __name__ == "__main__":
    command = sys.argv[1] if len(sys.argv) > 1 else ""
    use_profile(sys.argv[2] if len(sys.argv) > 2 else "argocd")
    if command == "create":
        owner = os.environ.get("GITHUB_OWNER", "kushan94")
        create(owner, os.environ.get("REPO_URL", f"https://github.com/{owner}/eks-internal-developer-platform"))
    elif command == "secret":
        secret()
    else:
        sys.exit(__doc__)
