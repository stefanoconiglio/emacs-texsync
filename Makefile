EMACS ?= /usr/bin/emacs
BATCH = $(EMACS) --batch -Q --eval '(package-initialize)' -L .

.PHONY: test gui-test compile clean

compile:
	$(BATCH) --eval '(setq byte-compile-error-on-warn t)' -f batch-byte-compile dyad.el

test:
	$(BATCH) -l test/dyad-test.el -f ert-run-tests-batch-and-exit

clean:
	rm -f *.elc test/*.elc

# Needs a graphical display: takes over the screen (fullscreen Emacs) for about a minute.
gui-test:
	@log=$$(mktemp); DYAD_GUI_LOG=$$log $(EMACS) -Q -l test/gui-test.el; s=$$?; cat $$log; rm -f $$log; exit $$s
