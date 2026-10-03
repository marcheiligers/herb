# frozen_string_literal: true
# typed: true

module Herb
  module Backend
    module PureRuby
      class Extractor # rubocop:disable Metrics/ClassLength
        #: (String, ?semicolons: bool, ?comments: bool, ?preserve_positions: bool, ?custom_tags: bool,
        #| ?erb_openers: Array[String]?) -> void
        def initialize( # rubocop:disable Metrics/ParameterLists
          source, semicolons: true, comments: false, preserve_positions: true, custom_tags: false, erb_openers: nil, **
        )
          unless source.is_a?(String)
            raise TypeError, "wrong argument type #{source.class} (expected String)"
          end

          @tokens = Lexer.new(source, erb_openers: erb_openers).tokens
          @semicolons = semicolons
          @comments = comments
          @preserve_positions = preserve_positions
          @custom_tags = custom_tags
        end

        #: () -> String
        def html
          @tokens.each_with_object(+"") do |token, output|
            output << (erb_token?(token) ? spaces(token) : token.value)
          end
        end

        #: () -> String
        def ruby # rubocop:disable Metrics/MethodLength, Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
          output = +""
          skip_content = false
          comment_tag = false
          erb_comment_tag = false
          need_newline = false

          @tokens.each_with_index do |token, index| # rubocop:disable Metrics/BlockLength
            case token.type
            when "TOKEN_NEWLINE"
              output << token.value
              need_newline = false
            when "TOKEN_ERB_START"
              erb_comment_tag = token.value == "<%#"

              if erb_comment_tag && @comments
                skip_content = false
                comment_tag = false
                output << comment_start(index, need_newline)
                need_newline = true unless @preserve_positions
              elsif erb_comment_tag
                skip_content = true
                comment_tag = true
                output << spaces(token) if @preserve_positions
              elsif escaped_or_hidden_custom_tag?(token)
                skip_content = true
                comment_tag = false
                output << spaces(token) if @preserve_positions
              else
                skip_content = false
                comment_tag = false
                output << spaces(token) if @preserve_positions
                output << "\n" if !@preserve_positions && need_newline
                need_newline = false
              end
            when "TOKEN_ERB_CONTENT"
              inline_comment = !@comments && !comment_tag && token.value.lstrip.start_with?("#") &&
                               token.location.start.line == token.location.end.line
              comment_tag = true if inline_comment

              if skip_content || inline_comment
                output << blank_content(token, erb_comment_tag) if @preserve_positions
              elsif erb_comment_tag
                output << erb_comment_content(token.value)
                need_newline = true unless @preserve_positions
              else
                output << token.value
                need_newline = true unless @preserve_positions
              end
            when "TOKEN_ERB_END"
              output << erb_end(token, comment_tag, erb_comment_tag) if @preserve_positions
              skip_content = false
              comment_tag = false
              erb_comment_tag = false
            else
              output << spaces(token) if @preserve_positions
            end
          end # rubocop:enable Metrics/BlockLength

          output
        end

        private

        def erb_token?(token)
          ["TOKEN_ERB_START", "TOKEN_ERB_CONTENT", "TOKEN_ERB_END"].include?(token.type)
        end

        def escaped_or_hidden_custom_tag?(token)
          token.value == "<%%" || token.value == "<%%=" ||
            (!DEFAULT_ERB_OPENINGS.include?(token.value) && !@custom_tags)
        end

        def comment_start(index, need_newline)
          return "\n#" if !@preserve_positions && need_newline
          return "#" unless @preserve_positions
          return "#  " if multiline_comment?(index)

          "  #"
        end

        def multiline_comment?(index)
          token = @tokens[index + 1]
          token&.type == "TOKEN_ERB_CONTENT" && token.value.include?("\n")
        end

        def blank_content(token, preserve_newlines)
          return spaces(token) unless preserve_newlines

          token.value.gsub(/[^\n]/, " ")
        end

        def erb_comment_content(value)
          value.gsub(/\n ?/, "\n#")
        end

        def erb_end(token, comment_tag, erb_comment_tag)
          return spaces(token) if comment_tag || (erb_comment_tag && @comments) || !@semicolons

          length = token.range.to - token.range.from
          return ";" if length == 1

          " ;#{" " * (length - 2)}"
        end

        def spaces(token)
          " " * (token.range.to - token.range.from)
        end
      end # rubocop:enable Metrics/ClassLength
    end
  end
end
