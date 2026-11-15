#!/bin/bash
# asm.sh name : name.s -> name.patch
# AS: an as-z8001 assembler.
cd "$(dirname "$0")"
"${AS:?AS: an as-z8001 assembler}" -o $1.o $1.s && python3 o2patch.py $1.o $1.patch
