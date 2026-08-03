# ---------------------------------------------------------------------------
# Faust -> LV2 plugin bundles
#
#   make                     build every src/faust/*.dsp into build/<name>.lv2
#   make -j8                 parallel build (each .dsp is independent)
#   make build/reverb.lv2    build a single plugin
#   make install
#   make clean
# ---------------------------------------------------------------------------

FAUST2LV2 ?= faust2lv2

SRCDIR    ?= src/faust
BUILDDIR  ?= build
LV2DIR    ?= $(HOME)/.lv2          # use /usr/local/lib/lv2 for a system install

# faust2lv2's own switches: -gui -midi -osc -nvoices N -soundfile -double -keep
FAUST2LV2FLAGS ?= -double
# anything faust2lv2 doesn't recognise is forwarded to the faust compiler
FAUSTFLAGS     ?= -vec

# Source set: override on the command line, e.g.  make DSPS="src/faust/reverb.dsp"
DSPS  ?= $(wildcard $(SRCDIR)/*.dsp)
# Rebuild everything when a shared library changes (faust2lv2 emits no dep files)
LIBS  ?= $(wildcard $(SRCDIR)/*.lib) $(wildcard lib/*.lib)

NAMES   := $(notdir $(basename $(DSPS)))
BUNDLES := $(addprefix $(BUILDDIR)/,$(addsuffix .lv2,$(NAMES)))

.PHONY: all clean install uninstall list
.DELETE_ON_ERROR:

all: $(BUNDLES)

# faust2lv2 writes <name>.lv2 next to the .dsp, so build then relocate.
# The target is the bundle directory itself: directory mtimes are a coarse
# signal, so this may rebuild more often than strictly necessary.
$(BUILDDIR)/%.lv2: $(SRCDIR)/%.dsp $(LIBS)
	@echo "  FAUST2LV2  $<"
	@mkdir -p $(BUILDDIR)
	@rm -rf $(SRCDIR)/$*.lv2 $@
	$(FAUST2LV2) $(FAUST2LV2FLAGS) $(FAUSTFLAGS) $<
	@mv $(SRCDIR)/$*.lv2 $@

install: all
	@mkdir -p $(DESTDIR)$(LV2DIR)
	@for b in $(BUNDLES); do \
	    echo "  INSTALL    $$b -> $(DESTDIR)$(LV2DIR)"; \
	    rm -rf $(DESTDIR)$(LV2DIR)/$$(basename $$b); \
	    cp -a $$b $(DESTDIR)$(LV2DIR)/; \
	done

uninstall:
	@for b in $(BUNDLES); do \
	    echo "  RM         $(DESTDIR)$(LV2DIR)/$$(basename $$b)"; \
	    rm -rf $(DESTDIR)$(LV2DIR)/$$(basename $$b); \
	done

list:
	@echo $(NAMES) | tr ' ' '\n'

clean:
	rm -rf $(BUILDDIR) $(addprefix $(SRCDIR)/,$(addsuffix .lv2,$(NAMES)))
