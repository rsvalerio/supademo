# Convenience wrapper around ./x, for `make` muscle memory.
#
# This is sugar, not the interface: ./x needs nothing installed, while `make`
# on macOS requires the Xcode command line tools. If `make` is not available,
# use ./x directly — the two are the same thing.
#
#   make            list the tasks
#   make setup      first run
#   make verify     everything CI runs

.DEFAULT_GOAL := help
.PHONY: help setup doctor verify start stop status reset test lint advisors types serve fmt check deploy secrets

help:
	@./x help

setup doctor verify start stop status reset test lint advisors types serve fmt check deploy secrets:
	@./x $@

# `make new name=add_widgets` and `make query sql="select 1"`
.PHONY: new query
new:
	@./x new $(name)

query:
	@./x query "$(sql)"
