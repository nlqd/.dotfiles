from pyinfra.operations import apt, files, server

apt.packages(
    name="Install Docker prerequisites",
    packages=["ca-certificates", "curl"],
)

files.directory(
    name="Ensure keyrings directory",
    path="/etc/apt/keyrings",
)

server.shell(
    name="Add Docker GPG key",
    commands=[
        "test -f /etc/apt/keyrings/docker.asc ||"
        " curl --fail --silent --show-error --location"
        " https://download.docker.com/linux/ubuntu/gpg"
        " --output /etc/apt/keyrings/docker.asc"
    ],
)

server.shell(
    name="Add Docker apt repository",
    commands=[
        "test -f /etc/apt/sources.list.d/docker.list ||"
        " echo \"deb [arch=$(dpkg --print-architecture)"
        " signed-by=/etc/apt/keyrings/docker.asc]"
        " https://download.docker.com/linux/ubuntu"
        " $(. /etc/os-release && echo $VERSION_CODENAME) stable\""
        " > /etc/apt/sources.list.d/docker.list"
    ],
)

apt.packages(
    name="Install Docker",
    packages=[
        "docker-ce", "docker-ce-cli", "containerd.io",
        "docker-compose-plugin",
    ],
    update=True,
)

server.shell(
    name="Add dungngo to docker group",
    commands=["usermod -aG docker dungngo"],
)
