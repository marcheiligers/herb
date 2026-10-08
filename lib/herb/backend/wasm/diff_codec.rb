# frozen_string_literal: true
# typed: true

module Herb
  module Backend
    module Wasm
      module DiffCodec
        SCHEMA_VERSION = 1

        module_function

        def decode(payload)
          reader = PayloadReader.new(payload)
          schema_version = reader.uint32
          raise "unsupported Herb WebAssembly diff result version #{schema_version}" unless schema_version == SCHEMA_VERSION

          identical = ASTCodec.decode_boolean(reader)
          operations = Array.new(reader.uint32) { decode_operation(reader) }
          reader.finish!

          Herb::Diff::Result.new(identical, operations)
        end

        def decode_operation(reader)
          type = ASTCodec.decode_string(reader)
          raise "Herb WebAssembly returned a diff operation without a type" unless type

          path = Array.new(reader.uint32) { reader.uint32 }
          old_node = ASTCodec.decode_node(reader)
          new_node = ASTCodec.decode_node(reader)
          Herb::Diff::Operation.new(type.to_sym, path, old_node, new_node, reader.uint32, reader.uint32)
        end
      end
    end
  end
end
