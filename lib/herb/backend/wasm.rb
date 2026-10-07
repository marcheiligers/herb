# frozen_string_literal: true
# typed: true

raise LoadError, "Herb's WebAssembly backend requires JRuby" unless RUBY_ENGINE == "jruby"

require_relative "wasm/endive"

module Herb
  module Backend
    module Wasm
      module_function

      def install!
        implementation = self

        Backend.define_singleton_method(:parse) { |source, **options| implementation.parse(source, **options) }
        Backend.define_singleton_method(:extract_html) { |source| implementation.extract_html(source) }
        Backend.define_singleton_method(:version) { implementation.version }
        nil
      end

      class PayloadReader
        def initialize(payload)
          @payload = payload
          @offset = 0
        end

        def uint32
          bytes = read(4)
          bytes.unpack1("L<").to_i
        end

        def string(length)
          read(length).force_encoding(Encoding::UTF_8)
        end

        def finish!
          raise "Herb WebAssembly result has trailing bytes" unless @offset == @payload.bytesize
        end

        private

        def read(length)
          value = @payload.byteslice(@offset, length)
          raise "Herb WebAssembly returned a truncated result" unless value&.bytesize == length

          @offset += length
          value
        end
      end

      #: (String?, **untyped) -> Herb::ParseResult
      def parse(source, **)
        validate_source!(source)
        parser_options = ParserOptions.new(**)
        expected_options = ParserOptions.new(html: false)

        unless parser_options.to_h == expected_options.to_h
          raise NotImplementedError, "the Herb WebAssembly experiment currently parses only with html: false"
        end

        decode_literal_parse(Endive.parse_literal(source), source, parser_options)
      end

      #: (String) -> String
      def extract_html(source)
        validate_source!(source)

        Endive.extract_html(source)
      end

      #: () -> String
      def version
        "herb gem v#{Herb::VERSION}, libprism v#{Endive.prism_version}, " \
          "libherb v#{Endive.libherb_version} (WebAssembly through Endive)"
      end

      def validate_source!(source)
        return if source.is_a?(String)

        raise TypeError, "wrong argument type #{source.class} (expected String)"
      end
      private_class_method :validate_source!

      def decode_literal_parse(payload, source, parser_options)
        reader = PayloadReader.new(payload)
        schema_version = reader.uint32
        raise "unsupported Herb WebAssembly result version #{schema_version}" unless schema_version == 1

        document_location = decode_location(reader)
        error_count = reader.uint32
        children = Array.new(reader.uint32) { decode_literal_node(reader) }

        reader.finish!

        document = AST::DocumentNode.build(children: children, location: document_location)
        ParseResult.new(document, source, [], [], parser_options, error_count)
      end
      private_class_method :decode_literal_parse

      def decode_literal_node(reader)
        node_type = reader.uint32
        raise "unsupported Herb WebAssembly node type #{node_type}" unless node_type == 1

        location = decode_location(reader)
        AST::LiteralNode.build(content: reader.string(reader.uint32), location: location)
      end
      private_class_method :decode_literal_node

      def decode_location(reader)
        Location.from(reader.uint32, reader.uint32, reader.uint32, reader.uint32)
      end
      private_class_method :decode_location
    end
  end
end
