from pyinfra import host
from pyinfra.operations import apt, files, server, systemd

apt.packages(
    name="Install base packages",
    packages=["rsync", "vim", "curl", "git"],
)

server.user(
    name="Create user dungngo",
    user="dungngo",
    groups=["sudo"],
    shell="/bin/bash",
)

files.directory(
    name="Ensure .ssh dir",
    path="/home/dungngo/.ssh",
    user="dungngo", group="dungngo", mode="700",
)

files.put(
    name="Upload authorized_keys",
    src="../roles/base/files/authorized_keys",
    dest="/home/dungngo/.ssh/authorized_keys",
    user="dungngo", group="dungngo", mode="600",
)

sshd_cfg = files.template(
    name="Template sshd_config",
    src="../roles/base/templates/sshd_config.j2",
    dest="/etc/ssh/sshd_config",
    mode="644",
)

systemd.service(
    name="Restart sshd",
    service="ssh",
    restarted=True,
    _if=sshd_cfg.did_change,
)

files.put(
    name="Grant dungngo passwordless sudo",
    src_contents="dungngo ALL=(ALL) NOPASSWD: ALL\n",
    dest="/etc/sudoers.d/dungngo",
    user="root", group="root", mode="440",
)

files.directory(
    name="Ensure .local/bin",
    path="/home/dungngo/.local/bin",
    user="dungngo", group="dungngo",
)

files.line(
    name="Add .local/bin to PATH in .bashrc",
    path="/home/dungngo/.bashrc",
    line='export PATH="$HOME/.local/bin:$PATH"',
    present=True,
)
