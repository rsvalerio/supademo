# Supademo — task entrypoint.
#
# Every target is one line: run a bash script. The logic lives in scripts/,
# which is where it can be read, reused and tested. Nothing here is more than a
# name for a script, on purpose.
#
#   make            list the targets
#   make setup      first run, from a fresh clone
#   make verify     everything CI runs
#
# Anything not listed here is the Supabase CLI itself:  ./supa <command>

SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

# Every target is a task name, never a file, so they must all be phony.
.PHONY: help setup doctor verify start stop restart status clean \
        reset new test lint advisors query list dump \
        types serve fmt check deploy secrets cli

## help: list the targets
help:
	@echo "Supademo — Docker is the only prerequisite."
	@echo
	@grep -E '^## ' $(MAKEFILE_LIST) \
	  | sed -e 's/^## //' -e 's/:/\t/' \
	  | awk -F'\t' '{ printf "  \033[1mmake %-14s\033[0m %s\n", $$1, $$2 }'
	@echo
	@echo "  Raw CLI: ./supa <command>          Docs: docs/local-development.md"

# --- getting started --------------------------------------------------------

## setup: first run — start the stack, migrate, seed, generate types
setup:
	@bash scripts/setup.sh

## doctor: what is installed, what is missing, which ports are busy
doctor:
	@bash scripts/doctor.sh

## verify: everything CI runs
verify:
	@bash scripts/verify.sh

# --- the stack --------------------------------------------------------------

## start: boot the local Supabase stack
start:
	@bash scripts/stack.sh start

## stop: shut it down, keeping the data volume
stop:
	@bash scripts/stack.sh stop

## restart: stop then start
restart:
	@bash scripts/stack.sh restart

## status: local URLs and keys
status:
	@bash scripts/stack.sh status

## clean: stop and drop the data volume (the seed rebuilds it)
clean:
	@bash scripts/stack.sh clean

# --- database ---------------------------------------------------------------

## reset: replay every migration from empty, then seed
reset:
	@bash scripts/db.sh reset

## new: create a migration — make new name=add_widget_table
new:
	@bash scripts/db.sh new $(name)

## test: run the pgTAP suite
test:
	@bash scripts/db.sh test

## lint: typing errors in functions and views
lint:
	@bash scripts/db.sh lint

## advisors: the dashboard's security + performance checks
advisors:
	@bash scripts/db.sh advisors

## query: run SQL — make query sql="select 1"
query:
	@bash scripts/db.sh query "$(sql)"

## list: local vs remote migration history
list:
	@bash scripts/db.sh list

## dump: snapshot the schema to supabase/schema.sql
dump:
	@bash scripts/db.sh dump

## types: regenerate packages/db-types
types:
	@bash scripts/types.sh

# --- edge functions ---------------------------------------------------------

## serve: serve all edge functions, hot-reloading
serve:
	@bash scripts/functions.sh serve

## fmt: format edge functions
fmt:
	@bash scripts/functions.sh fmt

## check: lint and typecheck edge functions
check:
	@bash scripts/functions.sh check

## deploy: deploy edge functions to the linked project
deploy:
	@bash scripts/functions.sh deploy

# --- hosted -----------------------------------------------------------------

## secrets: seed the Vault entries scheduled jobs need
secrets:
	@bash scripts/secrets.sh
