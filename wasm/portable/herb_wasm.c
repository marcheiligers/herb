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
  HERB_WASM_LEX_SCHEMA_VERSION = 1,
  HERB_WASM_DIFF_SCHEMA_VERSION = 1,
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

static bool herb_wasm_encode_diff_result(hb_buffer_T* buffer, const herb_diff_result_T* result) {
  size_t operation_count = herb_diff_operation_count(result);
  if (operation_count > UINT32_MAX) { return false; }

  if (!herb_wasm_buffer_append_uint32(buffer, HERB_WASM_DIFF_SCHEMA_VERSION)
      || !herb_wasm_buffer_append_uint32(buffer, herb_diff_trees_identical(result) ? 1 : 0)
      || !herb_wasm_buffer_append_uint32(buffer, (uint32_t) operation_count)) {
    return false;
  }

  for (size_t index = 0; index < operation_count; index++) {
    const herb_diff_operation_T* operation = herb_diff_operation_at(result, index);
    if (operation == NULL) { return false; }

    if (!herb_wasm_encode_string(buffer, hb_string(herb_diff_operation_type_to_string(operation->type)))
        || !herb_wasm_buffer_append_uint32(buffer, operation->path.depth)) {
      return false;
    }

    for (uint16_t path_index = 0; path_index < operation->path.depth; path_index++) {
      if (!herb_wasm_buffer_append_uint32(buffer, operation->path.indices[path_index])) { return false; }
    }

    if (!herb_wasm_encode_node(buffer, (AST_NODE_T*) operation->old_node)
        || !herb_wasm_encode_node(buffer, (AST_NODE_T*) operation->new_node)
        || !herb_wasm_buffer_append_uint32(buffer, operation->old_index)
        || !herb_wasm_buffer_append_uint32(buffer, operation->new_index)) {
      return false;
    }
  }

  return true;
}

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

__attribute__((visibility("default"))) uint32_t herb_wasm_extract_ruby(
  uint32_t source_pointer,
  uint32_t source_length,
  uint32_t options_pointer,
  uint32_t options_length
) {
  if (source_length == UINT32_MAX) { return herb_wasm_error("source is too large"); }

  herb_extract_ruby_options_T options = HERB_EXTRACT_RUBY_DEFAULT_OPTIONS;
  hb_string_T opener_buffer[HERB_WASM_MAX_ERB_OPENERS];
  const uint8_t* options_bytes = (const uint8_t*) (uintptr_t) options_pointer;

  if (!herb_wasm_decode_extract_ruby_options(options_bytes, options_length, &options, opener_buffer)) {
    return herb_wasm_error("invalid Herb WebAssembly extract_ruby options");
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

  hb_buffer_T output;
  if (!hb_buffer_init(&output, source_length, &allocator)) {
    hb_allocator_destroy(&allocator);
    free(source);
    return herb_wasm_error("failed to initialize the result buffer");
  }

  herb_extract_ruby_to_buffer_with_options(source, &output, &options, &allocator);

  uint8_t* result = herb_wasm_result_new(HERB_WASM_RESULT_OK, hb_buffer_value(&output), hb_buffer_length(&output));

  hb_allocator_destroy(&allocator);
  free(source);

  return (uint32_t) (uintptr_t) result;
}

__attribute__((visibility("default"))) uint32_t herb_wasm_lex(
  uint32_t source_pointer,
  uint32_t source_length,
  uint32_t options_pointer,
  uint32_t options_length
) {
  if (source_length == UINT32_MAX) { return herb_wasm_error("source is too large"); }

  parser_options_T options = HERB_DEFAULT_PARSER_OPTIONS;
  hb_string_T opener_buffer[HERB_WASM_MAX_ERB_OPENERS];
  const uint8_t* options_bytes = (const uint8_t*) (uintptr_t) options_pointer;

  if (!herb_wasm_decode_lex_options(options_bytes, options_length, &options, opener_buffer)) {
    return herb_wasm_error("invalid Herb WebAssembly lex options");
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

  hb_array_T* tokens = herb_lex_with_options(source, &options, &allocator);
  hb_buffer_T output;

  if (!hb_buffer_init(&output, (size_t) source_length + 64, &allocator)) {
    herb_free_tokens(&tokens, &allocator);
    hb_allocator_destroy(&allocator);
    free(source);
    return herb_wasm_error("failed to initialize the result buffer");
  }

  herb_wasm_buffer_append_uint32(&output, HERB_WASM_LEX_SCHEMA_VERSION);

  if (!herb_wasm_encode_tokens(&output, tokens)) {
    herb_free_tokens(&tokens, &allocator);
    hb_allocator_destroy(&allocator);
    free(source);
    return herb_wasm_error("the Herb WebAssembly token codec received unsupported lexer data");
  }

  uint8_t* result = herb_wasm_result_new(HERB_WASM_RESULT_OK, hb_buffer_value(&output), hb_buffer_length(&output));

  herb_free_tokens(&tokens, &allocator);
  hb_allocator_destroy(&allocator);
  free(source);

  return (uint32_t) (uintptr_t) result;
}

__attribute__((visibility("default"))) uint32_t herb_wasm_diff(
  uint32_t old_source_pointer,
  uint32_t old_source_length,
  uint32_t new_source_pointer,
  uint32_t new_source_length,
  uint32_t options_pointer,
  uint32_t options_length
) {
  if (old_source_length == UINT32_MAX || new_source_length == UINT32_MAX) {
    return herb_wasm_error("source is too large");
  }

  herb_diff_options_T options = HERB_DEFAULT_DIFF_OPTIONS;
  const uint8_t* options_bytes = (const uint8_t*) (uintptr_t) options_pointer;

  if (!herb_wasm_decode_diff_options(options_bytes, options_length, &options)) {
    return herb_wasm_error("invalid Herb WebAssembly diff options");
  }

  char* old_source = malloc((size_t) old_source_length + 1);
  if (old_source == NULL) { return herb_wasm_error("failed to allocate the old source buffer"); }

  char* new_source = malloc((size_t) new_source_length + 1);
  if (new_source == NULL) {
    free(old_source);
    return herb_wasm_error("failed to allocate the new source buffer");
  }

  if (old_source_length > 0) {
    memcpy(old_source, (const char*) (uintptr_t) old_source_pointer, old_source_length);
  }
  old_source[old_source_length] = '\0';

  if (new_source_length > 0) {
    memcpy(new_source, (const char*) (uintptr_t) new_source_pointer, new_source_length);
  }
  new_source[new_source_length] = '\0';

  hb_allocator_T old_allocator;
  if (!hb_allocator_init(&old_allocator, HB_ALLOCATOR_ARENA)) {
    free(new_source);
    free(old_source);
    return herb_wasm_error("failed to initialize the old Herb allocator");
  }

  hb_allocator_T new_allocator;
  if (!hb_allocator_init(&new_allocator, HB_ALLOCATOR_ARENA)) {
    hb_allocator_destroy(&old_allocator);
    free(new_source);
    free(old_source);
    return herb_wasm_error("failed to initialize the new Herb allocator");
  }

  hb_allocator_T diff_allocator;
  if (!hb_allocator_init(&diff_allocator, HB_ALLOCATOR_ARENA)) {
    hb_allocator_destroy(&new_allocator);
    hb_allocator_destroy(&old_allocator);
    free(new_source);
    free(old_source);
    return herb_wasm_error("failed to initialize the diff allocator");
  }

  parser_options_T parser_options = HERB_DEFAULT_PARSER_OPTIONS;
  AST_DOCUMENT_NODE_T* old_root = herb_parse(old_source, &parser_options, &old_allocator);
  AST_DOCUMENT_NODE_T* new_root = herb_parse(new_source, &parser_options, &new_allocator);

  if (old_root == NULL || new_root == NULL) {
    if (old_root != NULL) { ast_node_free((AST_NODE_T*) old_root, &old_allocator); }
    if (new_root != NULL) { ast_node_free((AST_NODE_T*) new_root, &new_allocator); }
    hb_allocator_destroy(&diff_allocator);
    hb_allocator_destroy(&new_allocator);
    hb_allocator_destroy(&old_allocator);
    free(new_source);
    free(old_source);
    return herb_wasm_error("Herb returned no document while diffing");
  }

  herb_diff_result_T* diff_result = herb_diff(old_root, new_root, &options, &diff_allocator);
  hb_buffer_T output;

  if (diff_result == NULL || !hb_buffer_init(&output, 256, &diff_allocator)) {
    ast_node_free((AST_NODE_T*) new_root, &new_allocator);
    ast_node_free((AST_NODE_T*) old_root, &old_allocator);
    hb_allocator_destroy(&diff_allocator);
    hb_allocator_destroy(&new_allocator);
    hb_allocator_destroy(&old_allocator);
    free(new_source);
    free(old_source);
    return herb_wasm_error("failed to initialize the diff result buffer");
  }

  if (!herb_wasm_encode_diff_result(&output, diff_result)) {
    ast_node_free((AST_NODE_T*) new_root, &new_allocator);
    ast_node_free((AST_NODE_T*) old_root, &old_allocator);
    hb_allocator_destroy(&diff_allocator);
    hb_allocator_destroy(&new_allocator);
    hb_allocator_destroy(&old_allocator);
    free(new_source);
    free(old_source);
    return herb_wasm_error("the Herb WebAssembly diff codec received unsupported data");
  }

  uint8_t* result = herb_wasm_result_new(HERB_WASM_RESULT_OK, hb_buffer_value(&output), hb_buffer_length(&output));

  ast_node_free((AST_NODE_T*) new_root, &new_allocator);
  ast_node_free((AST_NODE_T*) old_root, &old_allocator);
  hb_allocator_destroy(&diff_allocator);
  hb_allocator_destroy(&new_allocator);
  hb_allocator_destroy(&old_allocator);
  free(new_source);
  free(old_source);

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
