# BatteryToolkit Makefile
# macOS Sequoia & macOS 27

.PHONY: all build cli helper app test status clean run

all: build

build:
	@./scripts/build_app.sh

cli:
	@./scripts/build_app.sh

test: build
	@./build/batterytoolkit-cli test-sailing

status: build
	@./build/batterytoolkit-cli status

run: build
	@open build/BatteryToolkit.app

clean:
	@rm -rf build
	@echo "Cleaned build directory."
