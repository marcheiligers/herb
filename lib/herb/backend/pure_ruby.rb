# frozen_string_literal: true
# typed: true

require_relative "pure_ruby/extractor"
require_relative "pure_ruby/diff"
require_relative "pure_ruby/prism_adapter"
require_relative "pure_ruby/parser"

module Herb
  module Backend
    module PureRuby
      module_function

      DEFAULT_ERB_OPENINGS = ["<%", "<%=", "<%==", "<%#", "<%-", "<%%", "<%%="].freeze

      def install! # rubocop:disable Metrics/AbcSize
        implementation = self

        Backend.define_singleton_method(:parse) { |source, **options| implementation.parse(source, **options) }
        Backend.define_singleton_method(:lex) { |source, **options| implementation.lex(source, **options) }
        Backend.define_singleton_method(:extract_ruby) { |source, **options| implementation.extract_ruby(source, **options) }
        Backend.define_singleton_method(:extract_html) { |source| implementation.extract_html(source) }
        Backend.define_singleton_method(:diff) { |old_source, new_source, **options| implementation.diff(old_source, new_source, **options) }
        Backend.define_singleton_method(:default_erb_openings) { implementation.default_erb_openings }
        Backend.define_singleton_method(:version) { implementation.version }
      end

      #: (String?, **untyped) -> Herb::LexResult
      def lex(source, **options)
        unless source.nil? || source.is_a?(String)
          raise TypeError, "wrong argument type #{source.class} (expected String)"
        end

        tokens = Lexer.new(source.to_s.dup, erb_openers: options[:erb_openers]).tokens

        LexResult.new(tokens, source, [], [])
      end

      #: (String?, **untyped) -> Herb::ParseResult
      def parse(source, **)
        Parser.new(source, **).parse
      end

      #: (String, **untyped) -> String
      def extract_ruby(source, **)
        Extractor.new(source, **).ruby
      end

      #: (String) -> String
      def extract_html(source)
        Extractor.new(source).html
      end

      #: (String, String, **untyped) -> Herb::Diff::Result
      def diff(old_source, new_source, **)
        TreeDiff.new(old_source, new_source, **).result
      end

      #: () -> Array[String]
      def default_erb_openings
        DEFAULT_ERB_OPENINGS.dup
      end

      #: () -> String
      def version
        "herb gem v#{Herb::VERSION} (pure Ruby experiment)"
      end

      class Lexer # rubocop:disable Metrics/ClassLength
        ERB_END_CANDIDATE_LIMIT = 16
        ERB_SPACED_DELIMITER_LIMIT = 8
        ERB_CLOSINGS = ["%%>", "=%>", "-%>", "%>"].freeze
        CLOSE_TAG_WHITESPACE_BYTES = [9, 10, 13, 32].freeze
        NEWLINES = ["\r\n", "\r", "\n"].freeze

        SIMPLE_TOKENS = {
          "!" => "TOKEN_EXCLAMATION",
          "&" => "TOKEN_AMPERSAND",
          "@" => "TOKEN_AT",
          "/" => "TOKEN_SLASH",
          "-" => "TOKEN_DASH",
          "_" => "TOKEN_UNDERSCORE",
          "%" => "TOKEN_PERCENT",
          ":" => "TOKEN_COLON",
          "=" => "TOKEN_EQUALS",
          "\"" => "TOKEN_QUOTE",
          "'" => "TOKEN_QUOTE",
          ";" => "TOKEN_SEMICOLON",
          ">" => "TOKEN_HTML_TAG_END",
        }.freeze

        IDENTIFIER_BYTE = /[A-Za-z0-9]/
        IDENTIFIER_CONTINUATION_BYTE = /[A-Za-z0-9_:-]/

        #: (String, ?erb_openers: Array[String]?) -> void
        def initialize(source, erb_openers: nil)
          @source = source
          @custom_erb_openings = Array(erb_openers).map { |opener| "<%#{opener}" } - DEFAULT_ERB_OPENINGS
          @erb_openings = (DEFAULT_ERB_OPENINGS + @custom_erb_openings)
                          .uniq
                          .sort_by { |opener| -opener.bytesize }
          @tokens = [] #: Array[Herb::Token]
          @offset = 0
          @line = 1
          @column = 0
        end

        #: () -> Array[Herb::Token]
        def tokens
          scan until eof?
          emit("", "TOKEN_EOF")
          @tokens
        end

        private

        def scan
          scan_spacing || scan_markup || scan_text
        end

        def scan_spacing
          return scan_newline if starts_with?("\r\n") || starts_with?("\r") || starts_with?("\n")
          return scan_whitespace if current_char&.match?(/[\t\f\v ]/)
          return emit("\u00A0", "TOKEN_NBSP") if starts_with?("\u00A0")

          false
        end

        def scan_markup
          return true if scan_comment_delimiter
          return true if scan_declaration
          return scan_erb if erb_opening
          return emit("</", "TOKEN_HTML_TAG_START_CLOSE") if close_tag_start?
          return emit("/>", "TOKEN_HTML_TAG_SELF_CLOSE") if starts_with?("/>")

          if starts_with?("<")
            type = ascii_letter?(byte_at(1)) ? "TOKEN_HTML_TAG_START" : "TOKEN_LT"
            return emit("<", type)
          end

          false
        end

        def scan_declaration
          return emit(@source.byteslice(@offset, 9), "TOKEN_HTML_DOCTYPE") if starts_with_case_insensitive?("<!DOCTYPE")
          return emit("<![CDATA[", "TOKEN_CDATA_START") if starts_with?("<![CDATA[")
          return emit("]]>", "TOKEN_CDATA_END") if starts_with?("]]>")
          return emit(@source.byteslice(@offset, 5), "TOKEN_XML_DECLARATION") if xml_declaration?
          return emit("<?", "TOKEN_XML_PROCESSING_INSTRUCTION_START") if xml_processing_instruction?
          return emit("?>", "TOKEN_XML_DECLARATION_END") if starts_with?("?>")

          false
        end

        def scan_comment_delimiter
          return emit("<!--", "TOKEN_HTML_COMMENT_START") if starts_with?("<!--")
          return emit("--!>", "TOKEN_HTML_COMMENT_INVALID_END") if starts_with?("--!>")
          return emit("-->", "TOKEN_HTML_COMMENT_END") if starts_with?("-->")

          false
        end

        def scan_text
          char = current_char
          return emit(char, SIMPLE_TOKENS.fetch(char)) if SIMPLE_TOKENS.key?(char)
          return scan_identifier if char&.match?(IDENTIFIER_BYTE)

          emit(char, "TOKEN_CHARACTER")
        end

        def scan_newline
          value = starts_with?("\r\n") ? "\r\n" : current_char
          emit(value, "TOKEN_NEWLINE")
        end

        def scan_whitespace
          length = 0
          length += 1 while byte_at(length)&.chr&.match?(/[\t\f\v ]/)
          emit(@source.byteslice(@offset, length), "TOKEN_WHITESPACE")
        end

        def scan_identifier
          length = 0
          length += 1 while byte_at(length)&.chr&.match?(IDENTIFIER_CONTINUATION_BYTE) && !comment_end_at?(length)
          emit(@source.byteslice(@offset, length), "TOKEN_IDENTIFIER")
        end

        def comment_end_at?(relative_offset)
          starts_with?("-->", relative_offset) || starts_with?("--!>", relative_offset)
        end

        def scan_erb # rubocop:disable Naming/PredicateMethod
          opening = erb_opening
          emit(opening, "TOKEN_ERB_START")

          closing_offset, closing = erb_closing(comment: opening == "<%#")
          if closing_offset
            emit(@source.byteslice(@offset, closing_offset), "TOKEN_ERB_CONTENT")
            emit(closing, "TOKEN_ERB_END") if closing
          else
            emit(@source.byteslice(@offset..), "TOKEN_ERB_CONTENT")
          end

          true
        end

        def erb_opening
          return "<%" if starts_with?("<%%>")

          @erb_openings.find do |opening|
            starts_with?(opening) && (!@custom_erb_openings.include?(opening) || custom_opening_boundary?(opening))
          end
        end

        def custom_opening_boundary?(opening)
          return true unless word_byte?(opening.getbyte(-1))

          !word_byte?(byte_at(opening.bytesize))
        end

        def word_byte?(byte)
          byte && (ascii_letter?(byte) || byte.between?(48, 57) || byte == 95)
        end

        def erb_closing(comment:) # rubocop:disable Metrics/AbcSize, Metrics/PerceivedComplexity
          relative_offset = 0
          candidates = []

          while @offset + relative_offset < @source.bytesize
            ERB_CLOSINGS.each do |closing|
              return [relative_offset, closing] if starts_with?(closing, relative_offset)
            end

            nested = !comment && erb_opening_at?(relative_offset)
            if nested
              recovered = recovered_erb_closing(candidates)
              return recovered if recovered

              if erb_content_spans_nested_start?(relative_offset)
                relative_offset += 2
                next
              end

              return [relative_offset, nil]
            end

            record_erb_end_candidate(candidates, relative_offset) if candidates.length < ERB_END_CANDIDATE_LIMIT
            relative_offset += current_char_at(relative_offset).bytesize
          end

          recovered_erb_closing(candidates) || [nil, nil]
        end

        def record_erb_end_candidate(candidates, relative_offset)
          delimiter_length = erb_percent_delimiter_length(relative_offset)
          if delimiter_length.positive?
            leading = erb_percent_delimiter_leading_length(relative_offset)
            candidates << [:percent, relative_offset - leading, leading + delimiter_length]
          elsif html_tag_start_at?(relative_offset)
            candidates << [:html_tag, relative_offset, 0]
          elsif starts_with?(">", relative_offset)
            candidates << [:angle_bracket, relative_offset, 1]
          end
        end

        def erb_percent_delimiter_length(relative_offset)
          return 0 unless starts_with?("%", relative_offset)

          following = byte_at(relative_offset + 1)
          return 1 if following.nil? || [10, 13, 34, 39, 60].include?(following)

          1.upto(ERB_SPACED_DELIMITER_LIMIT) do |offset|
            byte = byte_at(relative_offset + offset)
            return offset + 1 if byte == 62
            break unless [9, 32].include?(byte)
          end

          0
        end

        def erb_percent_delimiter_leading_length(relative_offset)
          return 0 if relative_offset.zero?

          [37, 45, 61].include?(byte_at(relative_offset - 1)) ? 1 : 0
        end

        def html_tag_start_at?(relative_offset)
          return false unless starts_with?("<", relative_offset)

          following = byte_at(relative_offset + 1)
          ascii_letter?(following) || following == 33 || (following == 47 && ascii_letter?(byte_at(relative_offset + 2)))
        end

        def recovered_erb_closing(candidates)
          [:percent, :html_tag, :angle_bracket].each do |kind|
            matching = candidates.select { |candidate| candidate.first == kind }
            matching.reverse! if kind == :angle_bracket
            matching.each do |_candidate_kind, relative_offset, delimiter_length|
              content = @source.byteslice(@offset, relative_offset)
              next unless PrismAdapter.valid_fragment?(content)

              closing = @source.byteslice(@offset + relative_offset, delimiter_length) if delimiter_length.positive?
              return [relative_offset, closing]
            end
          end

          nil
        end

        def erb_content_spans_nested_start?(relative_offset)
          closing_offset = @source.index("%>", @offset + relative_offset)
          return false unless closing_offset

          content_length = closing_offset - @offset
          PrismAdapter.valid_fragment?(@source.byteslice(@offset, content_length))
        end

        def erb_opening_at?(relative_offset)
          @erb_openings.any? do |opening|
            starts_with?(opening, relative_offset) &&
              (!@custom_erb_openings.include?(opening) || custom_opening_boundary_at?(opening, relative_offset))
          end
        end

        def custom_opening_boundary_at?(opening, relative_offset)
          return true unless word_byte?(opening.getbyte(-1))

          !word_byte?(byte_at(relative_offset + opening.bytesize))
        end

        def emit(value, type)
          start_offset = @offset
          start_line = @line
          start_column = @column

          advance(value)

          @tokens << Token.new(
            value.dup,
            Range.new(start_offset, @offset),
            Location.from(start_line, start_column, @line, @column),
            type
          )
        end

        def advance(value)
          unless value.include?("\r") || value.include?("\n")
            @column += value.length
            @offset += value.bytesize
            return
          end

          value.scan(/\r\n|\r|\n|[^\r\n]/).each do |character|
            if NEWLINES.include?(character)
              @line += 1
              @column = 0
            else
              @column += 1
            end
          end

          @offset += value.bytesize
        end

        def eof?
          @offset >= @source.bytesize
        end

        def starts_with?(value, relative_offset = 0)
          @source.byteslice(@offset + relative_offset, value.bytesize) == value
        end

        def starts_with_case_insensitive?(value, relative_offset = 0)
          value.bytes.each_with_index.all? do |expected, index|
            actual = byte_at(relative_offset + index)
            actual == expected || ascii_case_pair?(actual, expected)
          end
        end

        def ascii_case_pair?(left, right)
          (left&.between?(65, 90) && left + 32 == right) ||
            (right.between?(65, 90) && right + 32 == left)
        end

        def xml_declaration?
          return false unless starts_with_case_insensitive?("<?xml")

          following = byte_at(5)
          !following || !(ascii_letter?(following) || following.between?(48, 57) || [45, 46, 58, 95].include?(following))
        end

        def xml_processing_instruction?
          starts_with?("<?") && ascii_letter?(byte_at(2))
        end

        def close_tag_start?
          return false unless starts_with?("</")

          offset = 2
          offset += 1 while CLOSE_TAG_WHITESPACE_BYTES.include?(byte_at(offset))
          ascii_letter?(byte_at(offset)) || byte_at(offset) == 95
        end

        def current_char
          current_char_at(0)
        end

        def current_char_at(relative_offset)
          offset = @offset + relative_offset
          byte = @source.getbyte(offset)
          return unless byte
          return @source.byteslice(offset, 1) if byte < 128

          @source.byteslice(offset..)&.slice(/\A./m)
        end

        def byte_at(relative_offset)
          @source.getbyte(@offset + relative_offset)
        end

        def ascii_letter?(byte)
          byte && (byte.between?(65, 90) || byte.between?(97, 122))
        end
      end # rubocop:enable Metrics/ClassLength
    end
  end
end
