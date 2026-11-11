# Native optimized builds. Windows: GNU Make in Git Bash, PYTHON=python if needed.
PYTHON ?= python3
.DEFAULT_GOAL := help
.PHONY: help build release linux windows macos cli studio test package native-package
help:
	@$(PYTHON) tool/build.py --help
build release:
	$(PYTHON) tool/build.py
linux windows macos:
	$(PYTHON) tool/build.py --platform $@
cli:
	$(PYTHON) tool/build.py --component cli
studio:
	$(PYTHON) tool/build.py --component studio
test:
	$(PYTHON) tool/build.py --verify
package:
	$(PYTHON) tool/build.py --package
native-package:
	$(PYTHON) tool/build.py --package --native
