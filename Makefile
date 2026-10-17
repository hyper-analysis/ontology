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

