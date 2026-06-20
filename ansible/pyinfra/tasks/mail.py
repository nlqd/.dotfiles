import os
import sys

from pyinfra import host
from pyinfra.operations import apt, files, server, systemd

# Load DKIM key from secrets.py (gitignored) — same key as ansible/vault.yml.
sys.path.insert(0, os.path.dirname(__file__) + "/..")
try:
    from secrets import DKIM_PRIVATE_KEY
except ImportError:
    raise SystemExit("Copy secrets.py.example to secrets.py and fill in DKIM_PRIVATE_KEY")

CERTBOT_EMAIL = "admin@dzungngo.com"

mail_domain = host.data.mail_domain
mail_hostname = host.data.mail_hostname

apt.packages(
    name="Install mail stack",
    packages=[
        "postfix", "dovecot-imapd", "dovecot-pop3d",
        "dovecot-sieve", "dovecot-managesieved",
        "opendkim", "opendkim-tools",
        "spamd", "spamassassin",
    ],
)

server.shell(
    name="Set mailname",
    commands=[f"echo '{mail_domain}' > /etc/mailname"],
)

postfix_main = files.template(
    name="Template postfix main.cf",
    src="../roles/mail/templates/main.cf.j2",
    dest="/etc/postfix/main.cf",
    mail_domain=mail_domain, mail_hostname=mail_hostname,
)
postfix_master = files.template(
    name="Template postfix master.cf",
    src="../roles/mail/templates/master.cf.j2",
    dest="/etc/postfix/master.cf",
    mail_domain=mail_domain, mail_hostname=mail_hostname,
)
postfix_login = files.template(
    name="Template login_maps.pcre",
    src="../roles/mail/templates/login_maps.pcre.j2",
    dest="/etc/postfix/login_maps.pcre",
    mail_domain=mail_domain,
)
postfix_headers = files.template(
    name="Template header_checks",
    src="../roles/mail/templates/header_checks.j2",
    dest="/etc/postfix/header_checks",
    mail_domain=mail_domain,
)

systemd.service(
    name="Restart postfix",
    service="postfix",
    restarted=True,
    _if=lambda: any([
        postfix_main.did_change,
        postfix_master.did_change,
        postfix_login.did_change,
        postfix_headers.did_change,
    ]),
)

dovecot_cfg = files.template(
    name="Template dovecot.conf",
    src="../roles/mail/templates/dovecot.conf.j2",
    dest="/etc/dovecot/dovecot.conf",
    mail_domain=mail_domain, mail_hostname=mail_hostname,
)

systemd.service(
    name="Restart dovecot",
    service="dovecot",
    restarted=True,
    _if=dovecot_cfg.did_change,
)

opendkim_cfg = files.template(
    name="Template opendkim.conf",
    src="../roles/mail/templates/opendkim.conf.j2",
    dest="/etc/opendkim.conf",
    mail_domain=mail_domain,
)

dkim_dir = f"/etc/postfix/dkim/{mail_domain}"

files.directory(
    name="Create DKIM directory",
    path=dkim_dir,
    user="opendkim", group="opendkim",
)

files.put(
    name="Write DKIM private key",
    src_contents=DKIM_PRIVATE_KEY,
    dest=f"{dkim_dir}/mail.private",
    user="opendkim", group="opendkim", mode="600",
)

dkim_keytable = files.template(
    name="Template DKIM keytable",
    src="../roles/mail/templates/dkim/keytable.j2",
    dest="/etc/postfix/dkim/keytable",
    mail_domain=mail_domain,
)
dkim_signing = files.template(
    name="Template DKIM signingtable",
    src="../roles/mail/templates/dkim/signingtable.j2",
    dest="/etc/postfix/dkim/signingtable",
    mail_domain=mail_domain,
)
dkim_trusted = files.template(
    name="Template DKIM trustedhosts",
    src="../roles/mail/templates/dkim/trustedhosts.j2",
    dest="/etc/postfix/dkim/trustedhosts",
    mail_domain=mail_domain,
)

systemd.service(
    name="Restart opendkim",
    service="opendkim",
    restarted=True,
    _if=lambda: any([
        opendkim_cfg.did_change,
        dkim_keytable.did_change,
        dkim_signing.did_change,
        dkim_trusted.did_change,
    ]),
)

server.group(
    name="Add postfix to opendkim group",
    group="opendkim",
    present=True,
)
server.shell(
    name="Add postfix user to opendkim group",
    commands=["usermod -aG opendkim postfix"],
)

files.directory(
    name="Ensure dovecot sieve directory",
    path="/var/lib/dovecot/sieve",
    user="dovecot", group="dovecot",
)

# Issue mail TLS cert (skips if cert already exists).
server.shell(
    name="Issue cert for mail",
    commands=[
        f"test -f /etc/letsencrypt/live/{mail_hostname}/fullchain.pem ||"
        f" certbot certonly --standalone -d {mail_hostname}"
        f" --non-interactive --agree-tos --email {CERTBOT_EMAIL}"
    ],
)

for service in ["postfix", "dovecot", "opendkim", "spamd"]:
    systemd.service(
        name=f"Enable {service}",
        service=service,
        running=True,
        enabled=True,
    )
