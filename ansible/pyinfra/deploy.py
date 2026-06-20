from pyinfra import local

# Run all roles in order. Equivalent of site.yml.
# To run a single role: pyinfra inventory.py tasks/nginx.py

local.include("tasks/base.py")
local.include("tasks/fail2ban.py")
local.include("tasks/nginx.py")
local.include("tasks/mail.py")
local.include("tasks/docker.py")
