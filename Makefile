SHELL := /bin/bash
SCRIPT := zenreset.sh

.PHONY: check test

check:
	bash -n $(SCRIPT)
	shellcheck $(SCRIPT)

test:
	@test "$$(./$(SCRIPT) version)" = "1.5.0"
	@./$(SCRIPT) help | grep -q 'clear OpenCode Zen rate limits'
	@./$(SCRIPT) doctor --no-fetch >/dev/null
	@echo "test: PASS"
