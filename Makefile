EXTENSION = $(shell grep -m 1 '"name":' META.json | \
sed -e 's/[[:space:]]*"name":[[:space:]]*"\([^"]*\)",/\1/')
EXTVERSION = $(shell grep -m 1 '"version":' META.json | \
sed -e 's/[[:space:]]*"version":[[:space:]]*"\([^"]*\)",\{0,1\}/\1/')

DATA         = $(filter-out $(wildcard sql/*--*.sql),$(wildcard sql/*.sql))
DOCS         = $(wildcard doc/*.asc)
TESTS        = $(wildcard test/sql/*.sql)
REGRESS      = $(patsubst test/sql/%.sql,%,$(TESTS))
REGRESS_OPTS = --inputdir=test --load-language=plpgsql
#
# Uncoment the MODULES line if you are adding C files
# to your extention.
#
#MODULES      = $(patsubst %.c,%,$(wildcard src/*.c))
PG_CONFIG    = pg_config

EXTRA_CLEAN  = $(wildcard $(EXTENSION)-*.zip)
VERSION 	 = $(shell $(PG_CONFIG) --version | awk '{print $$2}' | sed -e 's/devel$$//')
MAJORVER 	 = $(shell echo $(VERSION) | cut -d . -f1,2 | tr -d .)

test		 = $(shell test $(1) $(2) $(3) && echo yes || echo no)

GE91		 = $(call test, $(MAJORVER), -ge, 91)

ifeq ($(GE91),yes)
all: sql/$(EXTENSION)--$(EXTVERSION).sql

sql/$(EXTENSION)--$(EXTVERSION).sql: sql/$(EXTENSION).sql
	cp $< $@

DATA = $(wildcard sql/*--*.sql)
EXTRA_CLEAN += sql/$(EXTENSION)--$(EXTVERSION).sql
endif

PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)

# Don't have installcheck bomb on error
.IGNORE: installcheck

.PHONY: test
test: clean install installcheck
	@if [ -r regression.diffs ]; then cat regression.diffs; fi

.PHONY: results
results: test
	rsync -rlpgovP results/ test/expected

rmtag:
	@test -z "$$(git branch --list $(EXTVERSION))" || git branch -d $(EXTVERSION)

tag:
	@test -z "$$(git status --porcelain)" || (echo 'Untracked changes!'; echo; git status; exit 1)
	git branch $(EXTVERSION)
	git push --set-upstream origin $(EXTVERSION)

.PHONY: forcetag
forcetag: rmtag tag

dist: tag
	git archive --prefix=$(EXTENSION)-$(EXTVERSION)/ -o ../$(EXTENSION)-$(EXTVERSION).zip $(EXTVERSION)

.PHONY: forcedist
forcedist: forcetag dist

# To use this, do make print-VARIABLE_NAME
print-%  : ; @echo $* = $($*)
