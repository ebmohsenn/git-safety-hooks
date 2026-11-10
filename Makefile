SHELL_FILES := install.sh hooks/pre-commit hooks/commit-msg hooks/pre-push hooks/lib/*.sh test/*.sh
NODE_FILES  := hooks/lib/*.mjs

.PHONY: test lint check
test:
	@./test/run.sh

lint:
	shellcheck -x -S warning $(SHELL_FILES)
	@for f in $(NODE_FILES); do node --check $$f || exit 1; done
	@echo "lint ok"

check: lint test
