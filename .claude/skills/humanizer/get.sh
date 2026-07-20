#!/usr/bin/env bash

curl -o SKILL.md https://raw.githubusercontent.com/blader/humanizer/refs/heads/main/SKILL.md

printf "\nStrongly recommend reading: @./tropes.md and @./mytropes.md\n" | tee -a SKILL.md

curl -o tropes.md https://gist.githubusercontent.com/ossa-ma/f3baa9d25154c33095e22272c631f5a1/raw/42ac5e508e7cafd78330df3b97213efdc7e6382a/tropes.md
