#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "ast/ast_node.h"
#include "ast/ast_nodes.h"
#include "extract.h"
#include "herb.h"
#include "lexer/token.h"
#include "lib/hb_allocator.h"
#include "lib/hb_array.h"
#include "lib/hb_buffer.h"

enum {
  HERB_WASM_RESULT_OK = 0,
  HERB_WASM_RESULT_ERROR = 1,
  HERB_WASM_RESULT_HEADER_SIZE = 8,
  HERB_WASM_AST_SCHEMA_VERSION = 2,
};

static void herb_wasm_write_uint32(uint8_t* target, uint32_t value) {
  target[0] = (uint8_t) value;
  target[1] = (uint8_t) (value >> 8);
  target[2] = (uint8_t) (value >> 16);
  target[3] = (uint8_t) (value >> 24);
}

static uint8_t* herb_wasm_result_new(uint32_t status, const char* value, size_t length) {
  if (length > UINT32_MAX - HERB_WASM_RESULT_HEADER_SIZE) { return NULL; }

  uint8_t* result = malloc(HERB_WASM_RESULT_HEADER_SIZE + length);
  if (result == NULL) { return NULL; }

  herb_wasm_write_uint32(result, status);
  herb_wasm_write_uint32(result + 4, (uint32_t) length);

  if (length > 0) { memcpy(result + HERB_WASM_RESULT_HEADER_SIZE, value, length); }

  return result;
}

static uint32_t herb_wasm_result_from_string(const char* value) {
  if (value == NULL) { return 0; }

  return (uint32_t) (uintptr_t) herb_wasm_result_new(HERB_WASM_RESULT_OK, value, strlen(value));
}

static uint32_t herb_wasm_error(const char* message) {
  return (uint32_t) (uintptr_t) herb_wasm_result_new(HERB_WASM_RESULT_ERROR, message, strlen(message));
}

static bool herb_wasm_buffer_append_uint32(hb_buffer_T* buffer, uint32_t value) {
  uint8_t bytes[4];
  herb_wasm_write_uint32(bytes, value);
  hb_buffer_append_with_length(buffer, (const char*) bytes, sizeof(bytes));

  return true;
}

static bool herb_wasm_buffer_append_location(hb_buffer_T* buffer, location_T location) {
  return herb_wasm_buffer_append_uint32(buffer, location.start.line)
      && herb_wasm_buffer_append_uint32(buffer, location.start.column)
      && herb_wasm_buffer_append_uint32(buffer, location.end.line)
      && herb_wasm_buffer_append_uint32(buffer, location.end.column);
}

#include "ast_codec.inc"
#include "parser_options_codec.inc"

__attribute__((visibility("default"))) uint32_t herb_wasm_allocate(uint32_t size) {
  size_t allocation_size = size == 0 ? 1 : size;

  return (uint32_t) (uintptr_t) malloc(allocation_size);
}

__attribute__((visibility("default"))) void herb_wasm_deallocate(uint32_t pointer) {
  free((void*) (uintptr_t) pointer);
}

__attribute__((visibility("default"))) void herb_wasm_result_free(uint32_t pointer) {
  free((void*) (uintptr_t) pointer);
}

__attribute__((visibility("default"))) uint32_t herb_wasm_libherb_version(void) {
  return herb_wasm_result_from_string(herb_version());
}

__attribute__((visibility("default"))) uint32_t herb_wasm_prism_version(void) {
  return herb_wasm_result_from_string(herb_prism_version());
}

__attribute__((visibility("default"))) uint32_t
herb_wasm_extract_html(uint32_t source_pointer, uint32_t source_length) {
  if (source_length == UINT32_MAX) { return herb_wasm_error("source is too large"); }

  const char* source_bytes = (const char*) (uintptr_t) source_pointer;
  char* source = malloc((size_t) source_length + 1);

  if (source == NULL) { return herb_wasm_error("failed to allocate the source buffer"); }

  if (source_length > 0) { memcpy(source, source_bytes, source_length); }
  source[source_length] = '\0';

  hb_allocator_T allocator;
  if (!hb_allocator_init(&allocator, HB_ALLOCATOR_ARENA)) {
    free(source);
    return herb_wasm_error("failed to initialize the Herb allocator");
  }

  hb_buffer_T output;
  if (!hb_buffer_init(&output, source_length, &allocator)) {
    hb_allocator_destroy(&allocator);
    free(source);
    return herb_wasm_error("failed to initialize the result buffer");
  }

  herb_extract_html_to_buffer(source, &output, &allocator);

  uint8_t* result = herb_wasm_result_new(HERB_WASM_RESULT_OK, hb_buffer_value(&output), hb_buffer_length(&output));

  hb_allocator_destroy(&allocator);
  free(source);

  return (uint32_t) (uintptr_t) result;
}

__attribute__((visibility("default"))) uint32_t herb_wasm_parse(
  uint32_t source_pointer,
  uint32_t source_length,
  uint32_t options_pointer,
  uint32_t options_length
) {
  if (source_length == UINT32_MAX) { return herb_wasm_error("source is too large"); }

  parser_options_T options = HERB_DEFAULT_PARSER_OPTIONS;
  hb_string_T opener_buffer[HERB_WASM_MAX_ERB_OPENERS];
  const uint8_t* options_bytes = (const uint8_t*) (uintptr_t) options_pointer;

  if (!herb_wasm_decode_parser_options(options_bytes, options_length, &options, opener_buffer)) {
    return herb_wasm_error("invalid Herb WebAssembly parser options");
  }

  const char* source_bytes = (const char*) (uintptr_t) source_pointer;
  char* source = malloc((size_t) source_length + 1);

  if (source == NULL) { return herb_wasm_error("failed to allocate the source buffer"); }

  if (source_length > 0) { memcpy(source, source_bytes, source_length); }
  source[source_length] = '\0';

  hb_allocator_T allocator;
  if (!hb_allocator_init(&allocator, HB_ALLOCATOR_ARENA)) {
    free(source);
    return herb_wasm_error("failed to initialize the Herb allocator");
  }

  uint32_t error_count = 0;
  options.error_count = &error_count;

  AST_DOCUMENT_NODE_T* document = herb_parse(source, &options, &allocator);

  if (document == NULL) {
    hb_allocator_destroy(&allocator);
    free(source);
    return herb_wasm_error("Herb returned no document");
  }

  hb_buffer_T output;
  if (!hb_buffer_init(&output, (size_t) source_length + 64, &allocator)) {
    ast_node_free((AST_NODE_T*) document, &allocator);
    hb_allocator_destroy(&allocator);
    free(source);
    return herb_wasm_error("failed to initialize the result buffer");
  }

  herb_wasm_buffer_append_uint32(&output, HERB_WASM_AST_SCHEMA_VERSION);
  herb_wasm_buffer_append_uint32(&output, error_count);

  if (!herb_wasm_encode_node(&output, (AST_NODE_T*) document)) {
    ast_node_free((AST_NODE_T*) document, &allocator);
    hb_allocator_destroy(&allocator);
    free(source);
    return herb_wasm_error("the Herb WebAssembly AST codec received unsupported parser data");
  }

  uint8_t* result = herb_wasm_result_new(HERB_WASM_RESULT_OK, hb_buffer_value(&output), hb_buffer_length(&output));

  ast_node_free((AST_NODE_T*) document, &allocator);
  hb_allocator_destroy(&allocator);
  free(source);

  return (uint32_t) (uintptr_t) result;
}
