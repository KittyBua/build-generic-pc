PLUGIN_INSTALL_NAMES += webtv
PLUGIN_INSTALL_RULES += webtv:webtv-install
PLUGIN_INSTALL_ALIAS_PAIRS += webtv:webtv webtv-install:webtv
PLUGIN_CLEAN_DEFAULTS += webtv
# The generic clean looks for <name>.lua, <name>.cfg and <name>/ in the plugin
# directories. WebTV has none of those: it is a flat set of scripts and lists in
# a directory of its own, so it needs a hook.
PLUGIN_CLEAN_HOOKS += webtv:webtv-clean

.PHONY: webtv-clean
# Mirrors the flat install -- every file staged there came from the install.
# The directory itself stays: it is WEBTVDIR and Neutrino scans it. The var
# counterpart is left alone; that is where the user's own lists live, and
# Neutrino installs its webtv_usr.xml there.
webtv-clean:
	@for d in "$(NEUTRINO_INSTALL_DIR)$(NEUTRINO_PREFIX)/share/tuxbox/neutrino/webtv" \
	          "$(NEUTRINO_RUNTIME_PREFIX_ABS)/usr/share/tuxbox/neutrino/webtv"; do \
		if [ -d "$$d" ]; then \
			echo "[clean-plugin] Removing WebTV scripts from $$d"; \
			find "$$d" -maxdepth 1 -type f -delete || exit 1; \
		fi; \
	done
