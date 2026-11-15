#!/bin/sh
# Builds tb/lance/vec/*.vec from the Go LANCE model.
# GOSIM: the Go reference simulator checkout (its sim/ is module c900);
# Z8000: the Z8000 Go model checkout (its sim/ is module z8000).
# The build and tests need neither.
set -e
here=$(cd "$(dirname "$0")" && pwd)
top=$(cd "$here/../../.." && pwd)
GOSIM=${GOSIM:?GOSIM: the Go reference simulator checkout}
Z8000=${Z8000:?Z8000: the Z8000 Go model checkout}
w=$(mktemp -d)
trap 'rm -rf "$w"' EXIT
mkdir "$w/gen"
cp "$here/main.go.txt" "$w/gen/main.go"
printf 'module lancegen\n\ngo 1.26.1\n' > "$w/gen/go.mod"
printf 'go 1.26.1\n\nuse (\n\t%s/sim\n\t%s/sim\n\t./gen\n)\n' "$Z8000" "$GOSIM" > "$w/go.work"
(cd "$w/gen" && go run . "$here/../vec")
