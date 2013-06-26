PACKAGE = sqlite3

# TODO doesn't work. why??
# VERSION = $(shell sed -n -e 's/(define-package.*\"\([0-9.]*\)\"/\1/p' sqlite3-pkg.el)
VERSION = $(shell sed -n -e 's/^.define-package.*\"\([0-9.]*\)\"/\1/p' sqlite3-pkg.el)

ARCHIVE_DIR_PREFIX = ..

GOMI	= *.elc *~

RELEASE_FILES = \
	sqlite3-helm.el sqlite3-mode.el sqlite3-pkg.el \
	sqlite3.el

release: package
	rm -f $(ARCHIVE_DIR_PREFIX)/$(PACKAGE)-$(VERSION).tar
	mv /tmp/$(PACKAGE)-$(VERSION).tar $(ARCHIVE_DIR_PREFIX)

package: prepare
	cd /tmp ; \
	tar cf $(PACKAGE)-$(VERSION).tar $(PACKAGE)-$(VERSION)

prepare:
	rm -rf /tmp/$(PACKAGE)-$(VERSION)
	mkdir /tmp/$(PACKAGE)-$(VERSION)
	cp -pr $(RELEASE_FILES) /tmp/$(PACKAGE)-$(VERSION)

clean:
	rm -rf $(GOMI)



