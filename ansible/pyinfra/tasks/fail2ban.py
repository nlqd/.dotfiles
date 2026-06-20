from pyinfra.operations import apt, systemd

apt.packages(
    name="Install fail2ban",
    packages=["fail2ban"],
)

systemd.service(
    name="Enable fail2ban",
    service="fail2ban",
    running=True,
    enabled=True,
)
