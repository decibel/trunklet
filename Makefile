include pgxntool/base.mk

#
# Docs
#
ifeq (,$(ASCIIDOC))
ASCIIDOC = $(shell which asciidoc)
endif # ASCIIDOC
ifneq (,$(ASCIIDOC))
DOCS_built := $(DOCS:.asc=.html) $(DOCS:.adoc=.html)
DOCS += $(DOCS_built)

install: $(DOCS_built)
%.html: %.asc
	asciidoc $<
endif # ASCIIDOC

#
# Test deps
#

test_core_files = $(wildcard $(TESTDIR)/core/*.sql)
testdeps: $(test_core_files)

