ROOT := ../..
BUILD_DIR := build
OUTPUT := $(BUILD_DIR)/herb.wasm
AST_CODEC := ast_codec.inc
PARSER_OPTIONS_CODEC := parser_options_codec.inc

WASI_SDK_PATH ?= /opt/wasi-sdk
CC := $(WASI_SDK_PATH)/bin/clang

HERB_SOURCES := $(filter-out $(ROOT)/src/main.c,$(shell find $(ROOT)/src -name '*.c'))
PRISM_SOURCES := $(shell find $(ROOT)/vendor/prism/src -name '*.c')
SOURCES := herb_wasm.c $(HERB_SOURCES) $(PRISM_SOURCES)

INCLUDES := \
	-I$(ROOT)/src/include \
	-I$(ROOT)/vendor/prism/include \
	-I$(ROOT)/vendor/prism/src \
	-I$(ROOT)/vendor/prism/src/util

DEFINES := \
	-DHERB_EXCLUDE_PRETTYPRINT \
	-DPRISM_EXCLUDE_JSON \
	-DPRISM_EXCLUDE_PACK \
	-DPRISM_EXCLUDE_PRETTYPRINT \
	-DPRISM_EXPORT_SYMBOLS \
	-D_WASI_EMULATED_MMAN

CFLAGS := \
	--target=wasm32-wasip1 \
	-mexec-model=reactor \
	-std=gnu99 \
	-O2 \
	-flto \
	-fvisibility=hidden \
	-ffunction-sections \
	-fdata-sections \
	$(DEFINES) \
	$(INCLUDES)

LDFLAGS := \
	-lwasi-emulated-mman \
	-Wl,--gc-sections \
	-Wl,--export-memory \
	-Wl,--export=herb_wasm_allocate \
	-Wl,--export=herb_wasm_deallocate \
	-Wl,--export=herb_wasm_result_free \
	-Wl,--export=herb_wasm_libherb_version \
	-Wl,--export=herb_wasm_prism_version \
	-Wl,--export=herb_wasm_extract_html \
	-Wl,--export=herb_wasm_parse

.PHONY: all clean check

all: check $(OUTPUT)

check:
	@test -x "$(CC)" || { echo "WASI SDK clang not found at $(CC)" >&2; exit 1; }
	@test -f "$(ROOT)/vendor/prism/include/prism.h" || { echo "Vendored Prism is missing; run the Herb bootstrap first" >&2; exit 1; }

$(OUTPUT): herb_wasm.c $(AST_CODEC) $(PARSER_OPTIONS_CODEC) $(HERB_SOURCES) $(PRISM_SOURCES) | $(BUILD_DIR)
	$(CC) $(CFLAGS) $(SOURCES) $(LDFLAGS) -o $@

$(BUILD_DIR):
	mkdir -p $@

clean:
	rm -rf $(BUILD_DIR)
