# ================================
# DeFi Security Research Makefile
# ================================

PROJECT=src
GRAPH_DIR=graphs

# Default target
all: build slither graphs

# ----------------
# Build Contracts
# ----------------
build:
	forge build

clean:
	forge clean

# ----------------
# Slither Analysis
# ----------------
slither:
	slither $(PROJECT)

# Focused detectors (high signal)
slither-detectors:
	slither $(PROJECT) --detect \
	reentrancy-eth,\
	reentrancy-no-eth,\
	unchecked-transfer,\
	unchecked-lowlevel,\
	uninitialized-storage,\
	unprotected-upgrade,\
	arbitrary-send-eth,\
	tx-origin,\
	weak-prng

# ----------------
# Graph Generation
# ----------------
graphs: callgraph inheritance

callgraph:
	mkdir -p $(GRAPH_DIR)
	slither $(PROJECT) --print call-graph
	mv $(PROJECT)/.*call-graph.dot $(GRAPH_DIR)/ || true

inheritance:
	mkdir -p $(GRAPH_DIR)
	slither $(PROJECT) --print inheritance-graph
	mv $(PROJECT)/.*inheritance-graph.dot $(GRAPH_DIR)/ || true

# ----------------
# Convert DOT → PNG
# ----------------
render:
	for file in $(GRAPH_DIR)/*.dot; do \
		dot -Tpng $$file -o $$file.png; \
	done

# ----------------
# Open Graph (Linux)
# ----------------
open:
	xdg-open $(GRAPH_DIR)/*.png

# ----------------
# Echidna Fuzzing
# ----------------
echidna:
	docker run -it --rm -v "$$(pwd):/src" trailofbits/echidna \
	echidna src/DSCEngine.sol --contract DSCEngine

# ----------------
# Full Audit Pipeline
# ----------------
audit: clean build slither-detectors graphs render