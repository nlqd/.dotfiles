from pathlib import Path

hetz = [
    ("dzungngo.com", {
        "ssh_user": "dungngo",
        "ssh_key": str(Path.home() / ".ssh/hetzner_ed25519"),
        "mail_domain": "dzungngo.com",
        "mail_hostname": "mail.dzungngo.com",
        "nginx_sites": [
            {
                "name": "root",
                "domain": "dzungngo.com",
                "template": "root.conf.j2",
                "certbot": True,
            },
            {
                "name": "manufeature",
                "domain": "wms.dzungngo.com",
                "template": "manufeature.conf.j2",
                "certbot": True,
            },
            {
                "name": "n8n",
                "domain": "n8n.dzungngo.com",
                "template": "n8n.conf.j2",
                "certbot": True,
                "enabled": False,
            },
        ],
    }),
]
