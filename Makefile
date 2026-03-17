PREFIX ?= /usr/local

install:
	install -m 755 bin/paranoid $(PREFIX)/bin/paranoid
	install -d $(PREFIX)/lib/paranoid
	install -m 755 lib/paranoid-controlplane $(PREFIX)/lib/paranoid/paranoid-controlplane
	install -m 755 lib/rescue-agent $(PREFIX)/lib/paranoid/rescue-agent
	@echo "Installed. Run: sudo paranoid setup --mullvad-account <your-16-digits>"

uninstall:
	rm -f $(PREFIX)/bin/paranoid
	rm -rf $(PREFIX)/lib/paranoid

test:
	sudo tests/test-networking.sh
	sudo tests/test-boot.sh

.PHONY: install uninstall test
