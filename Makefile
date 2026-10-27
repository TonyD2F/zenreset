SHELL := /bin/bash
SCRIPT := zenreset.sh

.PHONY: check test test-doctor

check:
	bash -n $(SCRIPT)
	shellcheck $(SCRIPT)

# Fast and offline: safe to run in CI on every push.
test:
	./test/run-tests.sh

# Slow and networked: boots real engines and needs a working egress path.
test-doctor:
	@test "$$(./$(SCRIPT) version)" = "1.6.0"
	@./$(SCRIPT) help | grep -q 'clear OpenCode Zen rate limits'
	@./$(SCRIPT) doctor --no-fetch >/dev/null
	@echo "test-doctor: PASS"
