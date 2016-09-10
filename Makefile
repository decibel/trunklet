include pgxntool/base.mk

#
# OTHER DEPS
#
.PHONY: deps
deps: variant

.PHONY: variant
variant: $(DESTDIR)$(datadir)/extension/variant.control

$(DESTDIR)$(datadir)/extension/variant.control:
	pgxn install variant --unstable
