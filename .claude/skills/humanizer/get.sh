#!/usr/bin/env bash

wget https://raw.githubusercontent.com/blader/humanizer/refs/heads/main/SKILL.md

printf "\nStrongly recommend reading: [AI Writing Tropes to Avoid](./tropes.md), and [my curated set](./mytropes.md)\n" | tee -a SKILL.md

wget https://gist.githubusercontent.com/ossa-ma/f3baa9d25154c33095e22272c631f5a1/raw/42ac5e508e7cafd78330df3b97213efdc7e6382a/tropes.md
