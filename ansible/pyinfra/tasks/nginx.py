from pyinfra import host
from pyinfra.facts.files import File
from pyinfra.operations import apt, files, server, systemd

CERTBOT_EMAIL = "admin@dzungngo.com"
WEBROOT = "/var/www/html"

apt.packages(
    name="Install nginx and certbot",
    packages=["nginx", "certbot"],
)

files.directory(
    name="Create /var/www/html",
    path=WEBROOT,
    user="root",
)

files.directory(
    name="Create /var/www/files",
    path="/var/www/files",
    user="dungngo", group="www-data",
)

files.link(
    name="Symlink ~/public to /var/www/files",
    path="/home/dungngo/public",
    target="/var/www/files",
    symbolic=True,
)

nginx_sites = host.data.nginx_sites

# Pre-deploy cert state (snapshot — reflects what exists before this run).
cert_exists_for = {
    site["domain"]: bool(
        host.get_fact(File, path=f"/etc/letsencrypt/live/{site['domain']}/fullchain.pem")
    )
    for site in nginx_sites
}

# First-pass templates: HTTP-only if no cert yet, HTTPS if cert exists.
for site in nginx_sites:
    domain = site["domain"]
    enabled = site.get("enabled", True)

    files.template(
        name=f"nginx config {site['name']} (pass 1)",
        src=f"../roles/nginx/templates/{site['template']}",
        dest=f"/etc/nginx/sites-available/{site['name']}",
        item=site,
        cert_exists=cert_exists_for[domain],
    )

    if enabled:
        files.link(
            name=f"Enable {site['name']}",
            path=f"/etc/nginx/sites-enabled/{site['name']}",
            target=f"/etc/nginx/sites-available/{site['name']}",
            symbolic=True, force=True,
        )
    else:
        files.file(
            name=f"Disable {site['name']}",
            path=f"/etc/nginx/sites-enabled/{site['name']}",
            present=False,
        )

files.file(
    name="Remove default nginx site",
    path="/etc/nginx/sites-enabled/default",
    present=False,
)

# Reload nginx so /.well-known/acme-challenge is served before certbot runs.
systemd.service(
    name="Reload nginx (pre-certbot)",
    service="nginx",
    reloaded=True,
)

# Issue certs for sites that need them and don't have them yet.
needs_cert = [
    site for site in nginx_sites
    if site.get("certbot") and site.get("enabled", True) and not cert_exists_for[site["domain"]]
]

for site in needs_cert:
    domain = site["domain"]
    server.shell(
        name=f"Issue cert for {domain}",
        commands=[
            f"certbot certonly --webroot -w {WEBROOT} -d {domain}"
            f" --non-interactive --agree-tos --email {CERTBOT_EMAIL}"
        ],
    )

# Second-pass templates for newly-issued certs (no-op on subsequent runs).
for site in needs_cert:
    files.template(
        name=f"nginx config {site['name']} (pass 2, SSL)",
        src=f"../roles/nginx/templates/{site['template']}",
        dest=f"/etc/nginx/sites-available/{site['name']}",
        item=site,
        cert_exists=True,
    )

# Final reload to pick up any SSL configs.
systemd.service(
    name="Reload nginx (final)",
    service="nginx",
    reloaded=True,
)
