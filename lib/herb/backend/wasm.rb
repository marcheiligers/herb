# frozen_string_literal: true
# typed: true

raise LoadError, "Herb's WebAssembly backend requires JRuby" unless RUBY_ENGINE == "jruby"

require_relative "wasm/endive"
require_relative "wasm/ast_codec"
require_relative "wasm/parser_options_codec"

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

        def bytes(length)
          read(length).force_encoding(Encoding::BINARY)
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
        validate_parser_options!(parser_options)

        encoded_options = ParserOptionsCodec.encode(parser_options)
        decode_parse(Endive.parse(source, encoded_options), source, parser_options)
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

      def validate_parser_options!(options)
        return unless options.arena_stats

        raise NotImplementedError, "the Herb WebAssembly backend does not expose arena allocation statistics"
      end
      private_class_method :validate_parser_options!

      def decode_parse(payload, source, parser_options)
        reader = PayloadReader.new(payload)
        schema_version = reader.uint32
        raise "unsupported Herb WebAssembly result version #{schema_version}" unless schema_version == 2

        error_count = reader.uint32
        document = ASTCodec.decode_node(reader, track_locations: parser_options.track_locations)
        raise "Herb WebAssembly returned no document" unless document.is_a?(AST::DocumentNode)

        reader.finish!

        ParseResult.new(document, source, [], [], parser_options, error_count)
      end
      private_class_method :decode_parse
    end
  end
end
