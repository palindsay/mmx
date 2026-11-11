# Forward the same release targets when invoked from the Studio workspace.
.DEFAULT_GOAL := help
.PHONY: help build release linux windows macos cli studio test package native-package
help build release linux windows macos cli studio test package native-package:
	$(MAKE) -C ../.. $@
