GHC ?= ghc
PREFIX ?= $(HOME)/.local

.PHONY: all build test sql-test install clean
all: build

build:
	mkdir -p build/obj
	$(GHC) -O2 -Wall -Werror -isrc -package megaparsec -package scientific -package mtl -package containers -package time -outputdir build/obj app/OntologyMain.hs -o build/ontology

test: build
	GHC="$(GHC)" bash scripts/check.sh unit

sql-test: build
	GHC="$(GHC)" bash scripts/check.sh postgres

install: build
	install -Dm755 build/ontology "$(DESTDIR)$(PREFIX)/bin/ontology"

clean:
	rm -rf build dist-newstyle


.PHONY: app app-test
app:
	mkdir -p build/app-obj
	$(GHC) -O0 -Wall -Werror -isrc -outputdir build/app-obj app/ApplicationMain.hs -o build/ontology-app

app-test: app
	bash scripts/app-smoke.sh
