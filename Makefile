include pgxntool/base.mk

#
# Test deps
#

test_core_files = $(wildcard $(TESTDIR)/core/*.sql)
testdeps: $(test_core_files)

