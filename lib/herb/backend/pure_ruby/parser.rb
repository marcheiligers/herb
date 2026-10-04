# frozen_string_literal: true
# typed: true

module Herb
  module Backend
    module PureRuby
      class Parser # rubocop:disable Metrics/ClassLength
        VOID_ELEMENTS = ["area", "base", "br", "col", "embed", "frame", "hr", "img", "input", "link", "meta",
                         "param", "source", "track", "wbr"].freeze
        RAW_TEXT_ELEMENTS = ["script", "style", "iframe", "xmp", "noembed", "noframes"].freeze
        RAW_TEXT_REQUIRING_CLOSE = ["iframe", "xmp", "noembed", "noframes"].freeze
        ESCAPABLE_TEXT_ELEMENTS = ["textarea", "title"].freeze
        OPTIONAL_END_ELEMENTS = ["li", "dt", "dd", "p", "rt", "rp", "optgroup", "option", "thead", "tbody", "tfoot", "tr", "td", "th", "colgroup"].freeze
        OPTIONAL_END_TAG_OPEN_BOUNDARIES = {
          "li" => ["li"],
          "dt" => ["dt", "dd"],
          "dd" => ["dd", "dt"],
          "p" => ["address", "article", "aside", "blockquote", "details", "div", "dl", "fieldset", "figcaption", "figure", "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hgroup", "hr", "main", "menu", "nav", "ol", "p", "pre", "section", "table", "ul"],
          "rt" => ["rt", "rp"],
          "rp" => ["rp", "rt"],
          "optgroup" => ["optgroup"],
          "option" => ["option", "optgroup"],
          "thead" => ["tbody", "tfoot"],
          "tbody" => ["tbody", "tfoot"],
          "tr" => ["tr"],
          "td" => ["td", "th"],
          "th" => ["th", "td"],
        }.freeze
        OPTIONAL_END_TAG_PARENT_BOUNDARIES = {
          "li" => ["ul", "ol", "menu"],
          "dt" => ["dl"],
          "dd" => ["dl"],
          "p" => ["article", "aside", "blockquote", "body", "details", "div", "fieldset", "figcaption", "figure", "footer", "form", "header", "main", "nav", "section", "td", "th", "li", "dd", "template"],
          "rt" => ["ruby"],
          "rp" => ["ruby"],
          "optgroup" => ["select", "datalist"],
          "option" => ["select", "datalist"],
          "thead" => ["table"],
          "tbody" => ["table"],
          "tfoot" => ["table"],
          "tr" => ["thead", "tbody", "tfoot", "table"],
          "td" => ["tr"],
          "th" => ["tr"],
          "colgroup" => ["table"],
        }.freeze
        WHITESPACE_TOKEN_TYPES = ["TOKEN_WHITESPACE", "TOKEN_NEWLINE"].freeze
        HTML_TAG_START_TYPES = ["TOKEN_HTML_TAG_START", "TOKEN_HTML_TAG_START_CLOSE"].freeze
        DOCUMENT_CHILD_START_TYPES = [
          "TOKEN_HTML_TAG_START", "TOKEN_HTML_TAG_START_CLOSE", "TOKEN_HTML_COMMENT_START", "TOKEN_HTML_DOCTYPE",
          "TOKEN_XML_DECLARATION", "TOKEN_XML_PROCESSING_INSTRUCTION_START", "TOKEN_CDATA_START", "TOKEN_ERB_START"
        ].freeze
        DOCUMENT_DECLARATION_TYPES = [
          "TOKEN_HTML_DOCTYPE", "TOKEN_XML_DECLARATION", "TOKEN_XML_PROCESSING_INSTRUCTION_START", "TOKEN_CDATA_START"
        ].freeze
        ATTRIBUTE_NAME_LOOKAHEAD_TYPES = [
          "TOKEN_WHITESPACE", "TOKEN_NEWLINE", "TOKEN_IDENTIFIER", "TOKEN_CHARACTER", "TOKEN_DASH", "TOKEN_ERB_START"
        ].freeze
        INVALID_UNQUOTED_ATTRIBUTE_TOKEN_TYPES = ["TOKEN_QUOTE", "TOKEN_EQUALS"].freeze
        INVALID_UNQUOTED_ATTRIBUTE_VALUES = ["`", "<"].freeze
        NEWLINE_CHARACTERS = ["\r\n", "\r", "\n"].freeze
        QUOTE_BYTES = [34, 39].freeze
        NO_SPACE_BEFORE_BYTES = [41, 44].freeze
        ACTION_VIEW_BOOLEAN_ATTRIBUTES = [
          "allowfullscreen", "async", "autofocus", "autoplay", "checked", "compact", "controls", "declare",
          "default", "defer", "disabled", "formnovalidate", "hidden", "inert", "ismap", "itemscope", "loop",
          "multiple", "muted", "nomodule", "nohref", "noresize", "noshade", "novalidate", "nowrap", "open",
          "playsinline", "readonly", "required", "reversed", "scoped", "seamless", "selected", "sortable",
          "truespeed", "typemustmatch"
        ].freeze
        JAVASCRIPT_INCLUDE_TAG_PATH_OPTIONS = ["extname", "host", "protocol", "skip-pipeline"].freeze
        IMAGE_TAG_PATH_OPTIONS = ["skip-pipeline"].freeze
        LINK_TO_ATTRIBUTE_MAPPINGS = { "method" => "data-method", "remote" => "data-remote" }.freeze
        CONDITIONAL_BOUNDARIES = ["elsif", "else", "end"].freeze
        CASE_BOUNDARIES = ["when", "in", "else", "end"].freeze
        BEGIN_BOUNDARIES = ["rescue", "else", "ensure", "end"].freeze
        BLOCK_OPENERS = ["if", "unless", "case", "begin", "while", "until", "for"].freeze
        ITERATION_METHODS = [
          "each", "each_with_index", "each_with_object", "each_slice", "each_cons", "each_pair", "each_entry",
          "times", "upto", "downto", "step", "map", "flat_map", "select", "filter", "reject", "filter_map", "cycle"
        ].freeze
        TAG_END_TYPES = ["TOKEN_HTML_TAG_END", "TOKEN_HTML_TAG_SELF_CLOSE", "TOKEN_EOF"].freeze
        RENDER_KEYWORDS = {
          "partial" => :partial, "template" => :template_path, "layout" => :layout, "file" => :file,
          "inline" => :inline_template, "body" => :body, "plain" => :plain, "html" => :html,
          "renderable" => :renderable, "collection" => :collection, "object" => :object, "as" => :as_name,
          "spacer_template" => :spacer_template, "formats" => :formats, "variants" => :variants,
          "handlers" => :handlers, "content_type" => :content_type,
        }.freeze

        #: (String?, **untyped) -> void
        def initialize(source, **options) # rubocop:disable Metrics/AbcSize
          unless source.nil? || source.is_a?(String)
            raise TypeError, "wrong argument type #{source.class} (expected String)"
          end

          @original_source = source
          @source = source.to_s.dup
          @options = ParserOptions.new(timeout: 1.0, **options)
          @tokens = Lexer.new(@source, erb_openers: @options.erb_openers).tokens
          @case_condition_tags = {}
          prepare_multiple_control_tags
          @element_tag_balance_cache = {}
          @index = 0
          @loop_depth = 0
          @rescue_depth = 0
          @element_names = []
          @document_errors = []
          @found_strict_locals = false
          prepare_ruby_document if @options.analyze || @options.action_view_helpers || prism_output_requested?
          start_deadline(options)
        end

        #: () -> Herb::ParseResult
        def parse # rubocop:disable Metrics/AbcSize, Metrics/PerceivedComplexity
          children = parse_children
          document = AST::DocumentNode.build(
            children: children,
            prism_node: @options.prism_program ? @ruby_document&.serialized : nil,
            location: document_location,
            errors: @document_errors
          )
          transform_output_conditionals(document) if @options.transform_conditionals || @options.action_view_helpers
          transform_herb_directives(document) if @options.herb_directives
          transform_action_view_helpers(document) if @options.action_view_helpers
          annotate_prism_nodes(document) if @options.prism_nodes
          apply_error_limit(document)
          add_ruby_parse_errors(document) if @options.analyze
          add_timeout_error(document) if past_deadline?
          strip_node_positions(document) unless @options.track_locations
          ParseResult.new(document, @original_source, [], [], @options, document.recursive_errors.size)
        end

        private

        def transform_output_conditionals(node)
          case node
          when AST::DocumentNode
            transform_conditional_array(node.children, :html_text)
          when AST::HTMLElementNode, AST::ERBBlockNode
            transform_conditional_array(node.body, :html_text)
          when AST::HTMLOpenTagNode
            transform_conditional_array(node.children, :none)
          when AST::HTMLAttributeValueNode
            transform_conditional_array(node.children, :literal)
          end

          node.compact_child_nodes.each { |child| transform_output_conditionals(child) }
        end

        def transform_conditional_array(nodes, static_node_type)
          nodes.map! do |node|
            if transformable_output_node?(node) &&
               (conditional = PrismAdapter.inline_conditional(node.content.value))
              build_inline_conditional(node, conditional, static_node_type)
            else
              node
            end
          end
        end

        def transformable_output_node?(node)
          node.is_a?(AST::ERBContentNode) && node.parsed && node.valid && node.tag_opening.value.start_with?("<%=")
        end

        def build_inline_conditional(erb_node, conditional, static_node_type) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
          start_position = erb_node.location&.start
          end_position = erb_node.location&.end
          statements = build_conditional_branch(erb_node, conditional.true_branch, static_node_type)
          subsequent = if conditional.false_branch
                         build_synthetic_else(
                           erb_node,
                           build_conditional_branch(erb_node, conditional.false_branch, static_node_type)
                         )
                       end
          node_class = conditional.kind == :unless ? AST::ERBUnlessNode : AST::ERBIfNode
          attributes = {
            tag_opening: synthetic_token("<%", "TOKEN_ERB_START", start_position, start_position),
            content: synthetic_token(
              " #{conditional.kind} #{conditional.condition} ", "TOKEN_ERB_CONTENT", start_position, end_position
            ),
            tag_closing: synthetic_token("%>", "TOKEN_ERB_END", end_position, end_position),
            statements: statements,
            end_node: build_synthetic_end(end_position),
            location: erb_node.location,
          }
          if node_class == AST::ERBUnlessNode
            attributes[:else_clause] = subsequent
          else
            attributes[:subsequent] = subsequent
          end
          node_class.build(**attributes)
        end

        def build_conditional_branch(erb_node, branch, static_node_type) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
          if branch.nested_conditional
            return [build_inline_conditional(erb_node, branch.nested_conditional, static_node_type)]
          end

          if branch.static && static_node_type != :none
            return [] if branch.static_output.empty?

            node_class = static_node_type == :literal ? AST::LiteralNode : AST::HTMLTextNode
            return [node_class.build(
              content: branch.static_output.dup,
              location: conditional_branch_location(
                erb_node.content, branch.static_start_offset, branch.static_end_offset
              )
            )]
          end

          [AST::ERBContentNode.build(
            tag_opening: erb_node.tag_opening,
            content: synthetic_token(
              branch.source, "TOKEN_ERB_CONTENT",
              conditional_branch_position(erb_node.content, branch.start_offset),
              conditional_branch_position(erb_node.content, branch.end_offset),
              range: Range.from(
                erb_node.content.range.from + branch.start_offset,
                erb_node.content.range.from + branch.end_offset
              )
            ),
            tag_closing: erb_node.tag_closing,
            parsed: false,
            valid: true,
            location: erb_node.location
          )]
        end

        def build_synthetic_else(erb_node, statements)
          position = erb_node.location&.end
          AST::ERBElseNode.build(
            tag_opening: synthetic_token("<%", "TOKEN_ERB_START", position, position),
            content: synthetic_token(" else ", "TOKEN_ERB_CONTENT", position, position),
            tag_closing: synthetic_token("%>", "TOKEN_ERB_END", position, position),
            statements: statements,
            location: position && Location.new(position, position)
          )
        end

        def build_synthetic_end(position)
          AST::ERBEndNode.build(
            tag_opening: synthetic_token("<%", "TOKEN_ERB_START", position, position),
            content: synthetic_token(" end ", "TOKEN_ERB_CONTENT", position, position),
            tag_closing: synthetic_token("%>", "TOKEN_ERB_END", position, position),
            location: position && Location.new(position, position)
          )
        end

        def synthetic_token(value, type, start_position, end_position, range: Range.zero)
          location = start_position && Location.new(start_position, end_position)
          Token.new(value.dup, range, location, type)
        end

        def conditional_branch_location(content, start_offset, end_offset)
          start_position = conditional_branch_position(content, start_offset)
          end_position = conditional_branch_position(content, end_offset)
          start_position && Location.new(start_position, end_position)
        end

        def conditional_branch_position(content, offset)
          Position.new(content.location.start.line, content.location.start.column + offset)
        end

        def transform_herb_directives(node)
          node.instance_variables.each do |variable|
            value = node.instance_variable_get(variable)
            transform_herb_directive_array(value) if value.is_a?(Array) && value.any?(AST::Node)
          end
          node.compact_child_nodes.each { |child| transform_herb_directives(child) }
        end

        def transform_herb_directive_array(nodes)
          found_state = false

          nodes.map! do |node|
            replacement = build_herb_directive(node)
            next node unless replacement

            if replacement.is_a?(AST::HerbStateDirectiveNode)
              add_duplicate_herb_state_error(replacement) if found_state
              found_state = true
            end
            replacement
          end
        end

        def build_herb_directive(node)
          return unless node.is_a?(AST::ERBCommentNode) && node.content

          key_start, key_end = herb_directive_key_offsets(node.content.value)
          return unless key_start

          if node.content.value.byteslice(key_start...key_end) == "state"
            build_herb_state_directive(node, key_start, key_end)
          else
            build_generic_herb_directive(node, key_start, key_end)
          end
        end

        def herb_directive_key_offsets(source)
          offset = directive_skip_whitespace(source, 0)
          offset = directive_skip_whitespace(source, offset + 1) if source.getbyte(offset) == 45
          return unless source.byteslice(offset, 5) == "herb:"

          start_offset = offset + 5
          end_offset = start_offset
          end_offset += 1 while end_offset < source.bytesize && directive_key_byte?(source.getbyte(end_offset))
          [start_offset, end_offset] unless start_offset == end_offset
        end

        def directive_key_byte?(byte)
          byte&.between?(48, 57) || byte&.between?(65, 90) || byte&.between?(97, 122) || byte == 95
        end

        def directive_whitespace_byte?(byte)
          [9, 10, 11, 12, 13, 32].include?(byte)
        end

        def directive_skip_whitespace(source, offset)
          offset += 1 while offset < source.bytesize && directive_whitespace_byte?(source.getbyte(offset))
          offset
        end

        def directive_trim_end(source, start_offset, end_offset)
          end_offset -= 1 while end_offset > start_offset && directive_whitespace_byte?(source.getbyte(end_offset - 1))
          end_offset
        end

        def build_generic_herb_directive(node, key_start, key_end)
          source = node.content.value
          arguments_start = directive_skip_whitespace(source, key_end)
          arguments_end = directive_trim_end(source, arguments_start, source.bytesize)
          arguments = if arguments_end > arguments_start
                        token_slice(
                          node.content, source.byteslice(arguments_start...arguments_end), arguments_start,
                          type: "TOKEN_ERB_CONTENT"
                        )
                      end

          AST::HerbDirectiveNode.build(
            tag_opening: node.tag_opening,
            content: node.content,
            tag_closing: node.tag_closing,
            key: token_slice(node.content, source.byteslice(key_start...key_end), key_start),
            arguments: arguments,
            location: node.location
          )
        end

        def build_herb_state_directive(node, key_start, key_end) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
          source = node.content.value
          signature_start = directive_skip_whitespace(source, key_end)
          unless source.getbyte(signature_start) == 40
            return build_herb_state_without_signature(node, key_start, key_end, signature_start)
          end

          signature_end = herb_state_signature_end(source, signature_start)
          signature = source.byteslice(signature_start...signature_end)
          errors = []
          canonical_error = herb_state_canonical_error(node, key_start, key_end, signature_start, signature_end)
          errors << canonical_error if canonical_error
          parse_errors = herb_state_signature_errors(node.content, signature, signature_start)
          errors.concat(parse_errors)
          states = parse_errors.empty? ? build_herb_states(node.content, signature, signature_start, errors) : []

          AST::HerbStateDirectiveNode.build(
            tag_opening: node.tag_opening,
            content: node.content,
            tag_closing: node.tag_closing,
            key: token_slice(node.content, source.byteslice(key_start...key_end), key_start),
            signature: token_slice(node.content, signature, signature_start, type: "TOKEN_ERB_CONTENT"),
            states: states,
            location: node.location,
            errors: errors
          )
        end

        def herb_state_signature_end(source, opening)
          closing = strict_locals_params_close(source, opening)
          closing ? closing + 1 : source.bytesize
        end

        def build_herb_state_without_signature(node, key_start, key_end, rest_start)
          source = node.content.value
          rest_end = directive_trim_end(source, rest_start, source.bytesize)
          rest = source.byteslice(rest_start...rest_end)
          location = directive_content_location(node.content, rest_start, rest_end)
          error = Errors::HerbStateMissingParenthesisError.new(
            "HERB_STATE_MISSING_PARENTHESIS_ERROR",
            location,
            "The `herb:state` directive requires parentheses. Expected `herb:state (...)` but got " \
            "`herb:state #{rest}`.",
            rest
          )

          AST::HerbStateDirectiveNode.build(
            tag_opening: node.tag_opening,
            content: node.content,
            tag_closing: node.tag_closing,
            key: token_slice(node.content, source.byteslice(key_start...key_end), key_start),
            states: [],
            location: node.location,
            errors: [error]
          )
        end

        def herb_state_signature_errors(content, signature, signature_start)
          PrismAdapter.parameter_signature_errors(signature).map do |error|
            start_offset = strict_locals_error_offset(content, signature_start, error.location.start_offset)
            end_offset = strict_locals_error_offset(content, signature_start, error.location.end_offset)
            prism_parse_error(error, location: unbounded_location_from_offsets(start_offset, end_offset))
          end
        end

        def build_herb_states(content, signature, signature_start, errors)
          parameters = signature.byteslice(1...-1)
          build_parameter_list(content, parameters, signature_start + 1, destructured: false).filter_map do |parameter|
            if parameter.kind == "keyword"
              build_herb_state(content, parameter, errors)
            else
              errors << herb_state_invalid_parameter_error(content, parameter)
              nil
            end
          end
        end

        def build_herb_state(content, parameter, errors) # rubocop:disable Metrics/AbcSize
          errors << herb_state_invalid_parameter_error(content, parameter) unless parameter.default_value
          name_location = parameter.name.location
          name_end = Position.new(name_location.end.line, name_location.end.column - 1)
          name = Token.new(
            parameter.name.value.dup, Range.zero, Location.new(name_location.start, name_end), "TOKEN_IDENTIFIER"
          )

          AST::HerbStateDeclarationNode.build(
            name: name,
            default_value: parameter.default_value,
            kind: parameter.default_value ? PrismAdapter.expression_kind(parameter.default_value.content) : +"missing",
            location: parameter.location
          )
        end

        def herb_state_invalid_parameter_error(content, parameter)
          start_offset = location_byte_offset(parameter.location.start) - content.range.from
          end_offset = location_byte_offset(parameter.location.end) - content.range.from
          value = content.value.byteslice(start_offset...end_offset)
          Errors::HerbStateInvalidParameterError.new(
            "HERB_STATE_INVALID_PARAMETER_ERROR",
            parameter.location,
            "The `herb:state` directive only declares keyword arguments with defaults. `#{value}` is not one. " \
            "Declare each state with a default, like `(pending: false)`.",
            value
          )
        end

        def location_byte_offset(position)
          line = 1
          offset = 0
          @source.scan(/\r\n|\r|\n|[^\r\n]/).each do |character|
            return offset + position.column if line == position.line

            offset += character.bytesize
            line += 1 if NEWLINE_CHARACTERS.include?(character)
          end
          offset + position.column
        end

        def directive_content_location(content, start_offset, end_offset)
          unbounded_location_from_offsets(content.range.from + start_offset, content.range.from + end_offset)
        end

        def herb_state_canonical_error(node, key_start, key_end, signature_start, signature_end)
          range = herb_state_noncanonical_range(node, key_start, key_end, signature_start, signature_end)
          return unless range

          found = "#{node.tag_opening.value}#{node.content.value}#{node.tag_closing.value}"
          expected = "<%# herb:state #{normalize_herb_state_signature(node.content.value, signature_start, signature_end)} %>"
          Errors::HerbStateNonCanonicalDirectiveError.new(
            "HERB_STATE_NON_CANONICAL_DIRECTIVE_ERROR",
            directive_content_location(node.content, *range),
            "The `herb:state` directive has to be spelled `<%# herb:state (...) %>`. Found `#{found}` where " \
            "`#{expected}` was expected.",
            found,
            expected
          )
        end

        def herb_state_noncanonical_range(node, key_start, key_end, signature_start, signature_end)
          source = node.content.value
          prefix_start = key_start - 5
          return [0, prefix_start] unless source.byteslice(0...prefix_start) == " "
          return [key_end, signature_start] unless source.byteslice(key_end...signature_start) == " "
          return [signature_start, signature_end] if source.byteslice(signature_start...signature_end).include?("\n")
          return [signature_end, source.bytesize] unless source.byteslice(signature_end...) == " "
          return [source.bytesize, source.bytesize] unless node.tag_closing.value == "%>"

          nil
        end

        def normalize_herb_state_signature(source, start_offset, end_offset) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength, Metrics/PerceivedComplexity
          output = +""
          offset = start_offset
          pending_space = false

          while offset < end_offset
            byte = source.getbyte(offset)
            if QUOTE_BYTES.include?(byte)
              closing = herb_state_quoted_end(source, offset, end_offset)
              output << " " if pending_space
              output << source.byteslice(offset...closing)
              pending_space = false
              offset = closing
            elsif directive_whitespace_byte?(byte)
              pending_space = true
              offset += 1
            else
              output << " " if pending_space && !NO_SPACE_BEFORE_BYTES.include?(byte)
              pending_space = false
              output << source.byteslice(offset, 1)
              offset += 1
              offset = directive_skip_whitespace(source, offset) if byte == 40
            end
          end
          output
        end

        def herb_state_quoted_end(source, start_offset, end_offset)
          quote = source.getbyte(start_offset)
          offset = start_offset + 1
          while offset < end_offset
            if source.getbyte(offset) == 92
              offset += 2
            else
              return offset + 1 if source.getbyte(offset) == quote

              offset += 1
            end
          end
          end_offset
        end

        def add_duplicate_herb_state_error(node)
          node.errors << Errors::HerbStateDuplicateDeclarationError.new(
            "HERB_STATE_DUPLICATE_DECLARATION_ERROR",
            node.location,
            "This scope already declares its states. Merge these states into the first " \
            "`<%# herb:state (...) %>` directive of the scope, so every state of the scope reads from one declaration."
          )
        end

        def transform_action_view_helpers(node)
          node.instance_variables.each do |variable|
            value = node.instance_variable_get(variable)
            transform_action_view_helper_array(value) if value.is_a?(Array) && value.any?(AST::Node)
          end
          node.compact_child_nodes.each { |child| transform_action_view_helpers(child) }
        end

        def transform_action_view_helper_array(nodes) # rubocop:disable Metrics/PerceivedComplexity
          nodes.replace(nodes.flat_map do |node|
            normalize_silent_javascript_tag(node)
            build_tag_attributes_helper(node) || build_turbo_frame_helper(node) ||
              build_image_tag_helper(node) || build_javascript_include_tag_helper(node) ||
              build_stylesheet_link_tag_helper(node) || build_javascript_tag_helper(node) || build_link_to_helper(node) ||
              build_content_tag_helper(node) || build_tag_builder_helper(node) || node
          end)
        end

        def normalize_silent_javascript_tag(node)
          return unless node.is_a?(AST::ERBBlockNode) && node.tag_opening&.value == "<%"
          return unless PrismAdapter.tag_helper_call(node.content.value, "javascript_tag", block: true)

          node.body.each { |child| remove_silent_javascript_missing_close_error(child) }
        end

        def remove_silent_javascript_missing_close_error(node)
          if node.is_a?(AST::HTMLOpenTagNode)
            node.errors.reject! { |error| error.is_a?(Errors::MissingClosingTagError) }
          end
          node.compact_child_nodes.each { |child| remove_silent_javascript_missing_close_error(child) }
        end

        def build_tag_attributes_helper(node) # rubocop:disable Metrics/AbcSize, Metrics/PerceivedComplexity
          erb = if node.is_a?(AST::ERBContentNode)
                  node
                elsif node.is_a?(AST::HTMLAttributeNode) && !node.equals && !node.value &&
                      node.name&.children&.one? && node.name.children.first.is_a?(AST::ERBContentNode)
                  node.name.children.first
                end
          return unless erb&.tag_opening&.value == "<%="

          call = PrismAdapter.tag_builder_call(erb.content.value)
          return unless call&.name == "attributes"

          call.attributes.filter_map { |attribute| build_tag_helper_attribute(erb.content, attribute) }
        end

        def build_content_tag_helper(node)
          return unless action_view_helper_node?(node)

          block = node.is_a?(AST::ERBBlockNode)
          call = PrismAdapter.tag_helper_call(node.content.value, "content_tag", block: block)
          tag_argument = call&.arguments&.first
          return unless tag_argument

          tag_name = tag_argument.value if [:string, :symbol].include?(tag_argument.kind)

          build_element_helper(
            node, call, tag_name, call.arguments[1],
            source: "ActionView::Helpers::TagHelper#content_tag",
            helper_name: tag_name ? "content_tag :#{tag_name}" : "content_tag"
          )
        end

        def build_javascript_tag_helper(node)
          return unless action_view_helper_node?(node)

          block = node.is_a?(AST::ERBBlockNode)
          call = PrismAdapter.tag_helper_call(node.content.value, "javascript_tag", block: block)
          return unless call

          result = build_element_helper(
            node, call, "script", call.arguments.first,
            source: "ActionView::Helpers::JavaScriptHelper#javascript_tag",
            helper_name: "javascript_tag"
          )
          element = result.is_a?(Array) ? result.first : result
          resolve_javascript_nonce(element.open_tag.children)
          wrap_javascript_body(element, node)
          result
        end

        def build_link_to_helper(node) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength, Metrics/PerceivedComplexity
          return unless action_view_helper_node?(node)

          structural_block = node.is_a?(AST::ERBBlockNode)
          call = PrismAdapter.tag_helper_call(node.content.value, "link_to", block: structural_block)
          return unless call

          result = build_element_helper(
            node, call, "a", nil,
            source: "ActionView::Helpers::UrlHelper#link_to",
            helper_name: "link_to"
          )
          element = result.is_a?(Array) ? result.first : result
          attributes = link_to_attributes(node.content, call)
          attributes << build_link_to_options_splat(node.content, call) if link_to_options_splat?(call)
          if attributes.any? { |attribute| helper_attribute_name_content(attribute) == "data-method" }
            position = node.location&.start
            location = position && Location.new(position, position)
            attributes << build_synthetic_helper_attribute("rel", "nofollow", location, literal: true)
          end
          href, literal, href_argument = link_to_href(call)
          if href
            location = slice_location(
              node.content, href_argument.start_offset, href_argument.end_offset - href_argument.start_offset
            )
            attributes << build_synthetic_helper_attribute("href", href, location, literal: literal)
          end
          element.open_tag.children.replace(attributes)
          build_link_to_body(element, call, href, literal) unless structural_block
          result
        end

        def link_to_attributes(content, call) # rubocop:disable Metrics/AbcSize, Metrics/PerceivedComplexity
          return [] if link_to_keyword_hash_url?(call)

          call.attributes.filter_map do |attribute|
            node = build_tag_helper_attribute(content, attribute)
            next unless node

            mapped_name = LINK_TO_ATTRIBUTE_MAPPINGS[attribute.name]
            name = node.name&.children&.first if node.is_a?(AST::HTMLAttributeNode)
            if mapped_name && !attribute.prefix && name.is_a?(AST::LiteralNode)
              node.name.children.replace([AST::LiteralNode.build(content: mapped_name.dup, location: name.location)])
            end
            node
          end
        end

        def link_to_keyword_hash_url?(call)
          !call.block && call.arguments.one? && call.attribute_hash
        end

        def link_to_options_splat?(call)
          return false unless call.block && call.arguments.length >= 2

          ![:hash, :string, :symbol].include?(call.arguments[1].kind)
        end

        def build_link_to_options_splat(content, call)
          options = call.arguments[1]
          position = helper_position(content, options.start_offset)
          AST::RubyHTMLAttributesSplatNode.build(
            content: "tag.attributes(**#{options.source})",
            prefix: +"",
            location: position && Location.new(position, position)
          )
        end

        def link_to_href(call) # rubocop:disable Metrics/AbcSize, Metrics/PerceivedComplexity
          argument = if call.block
                       call.arguments.first || call.attribute_hash
                     elsif call.arguments.length >= 2
                       call.arguments[1]
                     elsif call.attribute_hash
                       call.attribute_hash
                     elsif call.arguments.one? && ![:string, :nil].include?(call.arguments.first.kind)
                       call.arguments.first
                     end
          return [nil, nil, nil] unless argument
          return [argument.value, true, argument] if argument.kind == :string
          return [argument.source, false, argument] if PrismAdapter.route_helper?(argument.source)

          ["url_for(#{argument.source})", false, argument]
        end

        def build_link_to_body(element, call, href, href_literal) # rubocop:disable Metrics/AbcSize, Metrics/PerceivedComplexity
          content = if call.block
                      call.block_value
                    else
                      call.arguments.first || (call.arguments.empty? && call.attribute_hash)
                    end
          single = !call.block && link_to_argument_count(call) == 1
          body_node = link_to_content_node(content, element.location, single: single)
          if !body_node && href
            type = href_literal ? AST::HTMLTextNode : AST::RubyLiteralNode
            body_node = type.build(content: href.dup, location: element.location)
          end
          element.body.replace(body_node ? [body_node] : [])
        end

        def link_to_content_node(content, location, single:)
          return unless content
          return if content.kind == :nil
          return AST::HTMLTextNode.build(content: content.value.dup, location: location) if content.kind == :string

          source = content.source
          source = "#{source}.to_s" if single
          AST::RubyLiteralNode.build(content: source.dup, location: location)
        end

        def link_to_argument_count(call)
          call.arguments.length + (call.attribute_hash ? 1 : 0)
        end

        def helper_attribute_name_content(attribute)
          return unless attribute.is_a?(AST::HTMLAttributeNode)

          name = attribute.name&.children&.first
          name&.content
        end

        def build_javascript_include_tag_helper(node) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength, Metrics/PerceivedComplexity
          return unless action_view_helper_node?(node)

          call = PrismAdapter.tag_helper_call(node.content.value, "javascript_include_tag")
          return unless call&.arguments&.any?

          multiple = call.arguments.length > 1
          elements = call.arguments.map do |source|
            element = build_element_helper(
              node, call, "script", nil,
              source: "ActionView::Helpers::AssetTagHelper#javascript_include_tag",
              helper_name: "javascript_include_tag"
            )
            attributes = element.open_tag.children
            JAVASCRIPT_INCLUDE_TAG_PATH_OPTIONS.each { |name| remove_helper_attribute(attributes, name) }
            resolve_javascript_nonce(attributes)
            source_attribute = build_javascript_include_tag_source(node.content, call, source)
            multiple ? attributes.unshift(source_attribute) : attributes << source_attribute
            element
          end
          return elements.first unless multiple

          elements.flat_map.with_index do |element, index|
            index.zero? ? element : [asset_tag_separator(node), element]
          end
        end

        def build_image_tag_helper(node)
          return unless action_view_helper_node?(node)

          call = PrismAdapter.tag_helper_call(node.content.value, "image_tag")
          source = call&.arguments&.first
          return unless source

          element = build_element_helper(
            node, call, "img", nil,
            source: "ActionView::Helpers::AssetTagHelper#image_tag",
            helper_name: "image_tag"
          )
          attributes = element.open_tag.children
          remove_helper_attribute(attributes, "skip-pipeline")
          expand_image_tag_size(attributes)
          attributes << build_image_tag_source(node.content, call, source)
          element
        end

        def expand_image_tag_size(attributes) # rubocop:disable Metrics/AbcSize, Metrics/PerceivedComplexity
          size = remove_helper_attribute(attributes, "size")
          value = size.value.children.first if size&.value
          return unless value

          position = size.location&.start
          location = position && Location.new(position, position)
          if value.is_a?(AST::LiteralNode)
            width, height = value.content.split("x", 2)
            height ||= width
            attributes << build_synthetic_helper_attribute("width", width, location, literal: true)
            attributes << build_synthetic_helper_attribute("height", height, location, literal: true)
          elsif value.is_a?(AST::RubyLiteralNode)
            expression = value.content
            attributes << build_synthetic_helper_attribute(
              "width", "#{expression}.to_s.split(\"x\", 2)[0]", location, literal: false
            )
            attributes << build_synthetic_helper_attribute(
              "height", "#{expression}.to_s.split(\"x\", 2)[-1]", location, literal: false
            )
          end
        end

        def build_image_tag_source(content, call, source) # rubocop:disable Metrics/AbcSize, Metrics/PerceivedComplexity
          location = slice_location(content, source.start_offset, source.end_offset - source.start_offset)
          raw_source = source.kind == :string ? source.value : source.source
          is_url = raw_source.start_with?("//") || raw_source.include?("://")
          return build_synthetic_helper_attribute("src", raw_source, location, literal: true) if is_url

          path_options = helper_path_options(content, call, IMAGE_TAG_PATH_OPTIONS)
          wrapped_source = source.kind == :string ? "\"#{source.value}\"" : source.source
          value = if source.kind == :string || !PrismAdapter.route_helper?(source.source)
                    "image_path(#{wrapped_source}#{", #{path_options.join(", ")}" unless path_options.empty?})"
                  else
                    source.source
                  end
          build_synthetic_helper_attribute("src", value, location, literal: false)
        end

        def build_javascript_include_tag_source(content, call, source) # rubocop:disable Metrics/AbcSize
          location = slice_location(content, source.start_offset, source.end_offset - source.start_offset)
          is_url = source.kind == :string &&
                   (source.value.start_with?("//") || source.value.include?("://"))
          return build_synthetic_helper_attribute("src", source.value, location, literal: true) if is_url

          value = source.source
          if source.kind == :string
            path_options = helper_path_options(content, call, JAVASCRIPT_INCLUDE_TAG_PATH_OPTIONS)
            value = "javascript_path(\"#{source.value}\"#{", #{path_options.join(", ")}" unless path_options.empty?})"
          end
          build_synthetic_helper_attribute("src", value, location, literal: false)
        end

        def build_stylesheet_link_tag_helper(node) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength, Metrics/PerceivedComplexity
          return unless action_view_helper_node?(node)

          call = PrismAdapter.tag_helper_call(node.content.value, "stylesheet_link_tag")
          return unless call&.arguments&.any?

          multiple = call.arguments.length > 1
          elements = call.arguments.map do |source|
            element = build_element_helper(
              node, call, "link", nil,
              source: "ActionView::Helpers::AssetTagHelper#stylesheet_link_tag",
              helper_name: "stylesheet_link_tag"
            )
            attributes = element.open_tag.children
            JAVASCRIPT_INCLUDE_TAG_PATH_OPTIONS.each { |name| remove_helper_attribute(attributes, name) }
            resolve_javascript_nonce(attributes)
            href = build_stylesheet_link_tag_source(node.content, call, source)
            rel = remove_helper_attribute(attributes, "rel") ||
                  build_synthetic_helper_attribute("rel", "stylesheet", href.location, literal: true)
            attributes.unshift(href)
            attributes.unshift(rel)
            element
          end
          return elements.first unless multiple

          elements.flat_map.with_index do |element, index|
            index.zero? ? element : [asset_tag_separator(node), element]
          end
        end

        def build_stylesheet_link_tag_source(content, call, source) # rubocop:disable Metrics/AbcSize, Metrics/PerceivedComplexity
          location = slice_location(content, source.start_offset, source.end_offset - source.start_offset)
          raw_source = source.kind == :string ? source.value : source.source
          is_url = raw_source.start_with?("//") || raw_source.include?("://")
          return build_synthetic_helper_attribute("href", raw_source, location, literal: true) if is_url

          path_options = helper_path_options(content, call, JAVASCRIPT_INCLUDE_TAG_PATH_OPTIONS)
          wrapped_source = source.kind == :string ? "\"#{source.value}\"" : source.source
          value = if source.kind == :string || !PrismAdapter.route_helper?(source.source)
                    "stylesheet_path(#{wrapped_source}#{", #{path_options.join(", ")}" unless path_options.empty?})"
                  else
                    source.source
                  end
          build_synthetic_helper_attribute("href", value, location, literal: false)
        end

        def helper_path_options(content, call, names)
          call.attributes.filter_map do |attribute|
            next unless names.include?(attribute.name)

            key = content.value.byteslice(attribute.name_start_offset...attribute.separator_end_offset).rstrip
            "#{key} #{attribute.value.source}"
          end
        end

        def asset_tag_separator(node)
          position = node.location&.start
          AST::HTMLTextNode.build(
            content: +"\n",
            location: position && Location.new(position, position)
          )
        end

        def resolve_javascript_nonce(attributes) # rubocop:disable Metrics/AbcSize, Metrics/PerceivedComplexity
          nonce = attributes.find do |attribute|
            next false unless attribute.is_a?(AST::HTMLAttributeNode)

            name = attribute.name&.children&.first
            name&.content == "nonce"
          end
          return unless nonce&.value

          value_node = nonce.value.children.first
          return unless value_node.is_a?(AST::LiteralNode)

          value = value_node.content
          if value == "true"
            resolved = AST::RubyLiteralNode.build(
              content: +"content_security_policy_nonce", location: nonce.value.location
            )
            nonce.value.children.replace([resolved])
          elsif value == "false"
            attributes.delete(nonce)
          end
        end

        def wrap_javascript_body(element, source_node)
          children = source_node.is_a?(AST::ERBBlockNode) ? javascript_block_body(source_node) : element.body.dup
          return if children.empty?

          location = element.location
          cdata = AST::CDATANode.build(
            tag_opening: helper_token("\n//<![CDATA[\n", "TOKEN_CDATA_START", location&.start, location&.end),
            children: children,
            tag_closing: helper_token("\n//]]>\n", "TOKEN_CDATA_END", location&.start, location&.end),
            location: location
          )
          element.body.replace([cdata])
        end

        def javascript_block_body(node)
          from = node.tag_closing.range.to
          to = helper_end_node(node).tag_opening.range.from
          javascript_literal_children(from, to)
        end

        def javascript_literal_children(from, to) # rubocop:disable Metrics/AbcSize, Metrics/PerceivedComplexity
          children = []
          cursor = from
          @tokens.each_with_index do |opening, index|
            next unless opening.type == "TOKEN_ERB_START" && opening.range.from >= from && opening.range.from < to

            content, closing = @tokens[index + 1, 2]
            next unless content&.type == "TOKEN_ERB_CONTENT" && closing&.type == "TOKEN_ERB_END"
            next if closing.range.to > to

            children << javascript_literal(cursor, opening.range.from) if cursor < opening.range.from
            children << AST::ERBContentNode.build(
              tag_opening: node_token(opening),
              content: node_token(content),
              tag_closing: node_token(closing),
              parsed: false,
              valid: false,
              location: location_from(opening, closing)
            )
            cursor = closing.range.to
          end
          children << javascript_literal(cursor, to) if cursor < to
          children
        end

        def javascript_literal(from, to)
          AST::LiteralNode.build(
            content: @source.byteslice(from...to),
            location: slice_location_from_offsets(from, to)
          )
        end

        def build_tag_builder_helper(node)
          return unless action_view_helper_node?(node)

          block = node.is_a?(AST::ERBBlockNode)
          call = PrismAdapter.tag_builder_call(node.content.value, block: block)
          return unless call
          return if tag_receiver_is_local?(node.content, call)

          dynamic = ["send", "public_send", "try", "class", "method", "frozen?", "attributes"].include?(call.name)
          tag_name = call.name.tr("_", "-") unless dynamic
          build_element_helper(
            node, call, tag_name, dynamic ? nil : call.arguments.first,
            source: "ActionView::Helpers::TagHelper#tag",
            helper_name: "tag.#{call.name}"
          )
        end

        def tag_receiver_is_local?(content, call)
          offset = content.range.from + call.receiver_start_offset
          PrismAdapter.local_variable_read_at?(@ruby_document.result, "tag", offset)
        end

        def action_view_helper_node?(node)
          (node.is_a?(AST::ERBContentNode) || node.is_a?(AST::ERBBlockNode)) && node.tag_opening&.value == "<%="
        end

        def build_element_helper(node, call, tag_name_value, argument_content, source:, helper_name:) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength, Metrics/ParameterLists
          attributes = call.attributes.filter_map { |attribute| build_tag_helper_attribute(node.content, attribute) }
          tag_name = if tag_name_value
                       token_slice(
                         node.content, tag_name_value, call.name_start_offset,
                         span: call.name_end_offset - call.name_start_offset
                       )
                     end
          open_tag = AST::ERBOpenTagNode.build(
            tag_opening: node.tag_opening,
            content: node.content,
            tag_closing: node.tag_closing,
            tag_name: tag_name,
            children: attributes,
            location: helper_open_tag_location(node)
          )
          is_void = tag_name_value ? VOID_ELEMENTS.include?(tag_name_value.downcase) : false
          body, content_value, content_kind = helper_body(node, call, argument_content, tag_name_value)
          close_tag = helper_close_tag(node, tag_name, is_void)
          errors = []
          if is_void && content_value
            errors << void_helper_content_error(
              node, tag_name, helper_name, content_kind, argument_content
            )
          end
          element = AST::HTMLElementNode.build(
            open_tag: open_tag,
            tag_name: tag_name,
            body: body,
            close_tag: close_tag,
            is_void: is_void,
            element_source: source,
            location: helper_element_location(node),
            errors: errors
          )
          append_recovered_helper_remainder(node, element)
        end

        def append_recovered_helper_remainder(node, element) # rubocop:disable Metrics/AbcSize, Metrics/PerceivedComplexity
          return element unless node.is_a?(AST::ERBBlockNode) && !node.end_node

          ending = helper_end_node(node)
          from = ending.tag_closing.range.to if ending&.tag_closing&.range
          to = location_byte_offset(node.location&.end)
          return element unless from && to && from < to

          remainder = @source.byteslice(from...to)
          return element if remainder.empty?

          [
            element,
            AST::HTMLTextNode.build(content: remainder, location: slice_location_from_offsets(from, to))
          ]
        end

        def helper_body(node, call, argument_content, tag_name) # rubocop:disable Metrics/AbcSize
          if node.is_a?(AST::ERBBlockNode)
            body = tag_name == "script" ? raw_helper_block_body(node) : node.body
            return [body, true, "a block"]
          end

          content = call.block_value || argument_content
          return [[], nil, nil] unless content

          kind = call.block_value ? "a block" : "a positional argument"
          body_node = if [:string, :symbol].include?(content.kind)
                        AST::HTMLTextNode.build(content: content.value.dup, location: node.location)
                      else
                        AST::RubyLiteralNode.build(content: content.source.dup, location: node.location)
                      end
          [[body_node], content, kind]
        end

        def raw_helper_block_body(node)
          from = node.tag_closing.range.to
          to = helper_end_node(node).tag_opening.range.from
          [AST::LiteralNode.build(
            content: @source.byteslice(from...to),
            location: slice_location_from_offsets(from, to)
          )]
        end

        def helper_close_tag(node, tag_name, is_void)
          return if is_void
          return helper_end_node(node) if node.is_a?(AST::ERBBlockNode)

          position = node.location&.end
          AST::HTMLVirtualCloseTagNode.build(
            tag_name: tag_name,
            location: position && Location.new(position, position)
          )
        end

        def helper_element_location(node)
          return node.location unless node.is_a?(AST::ERBBlockNode)

          ending = helper_end_node(node)
          return node.location unless ending

          Location.new(node.tag_opening.location.start, ending.location.end)
        end

        def helper_end_node(node)
          node.end_node || find_helper_end_node(node.body)
        end

        def find_helper_end_node(nodes)
          nodes.each do |node|
            if node.is_a?(AST::ERBContentNode) && node.content.value.strip == "end"
              return AST::ERBEndNode.build(
                tag_opening: node.tag_opening,
                content: node.content,
                tag_closing: node.tag_closing,
                location: node.location
              )
            end
            found = find_helper_end_node(node.compact_child_nodes)
            return found if found
          end
          nil
        end

        def void_helper_content_error(node, tag_name, helper_name, content_kind, argument_content)
          location = if content_kind == "a block" || !argument_content
                       node.location
                     else
                       helper_location(node.content, argument_content.start_offset, argument_content.end_offset)
                     end
          Errors::VoidElementContentError.new(
            "VOID_ELEMENT_CONTENT_ERROR",
            location,
            "Void element `#{tag_name.value}` cannot have content. `#{helper_name}` does not accept " \
            "#{content_kind} for content.",
            tag_name,
            helper_name,
            content_kind
          )
        end

        def build_turbo_frame_helper(node) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength, Metrics/PerceivedComplexity
          return unless node.is_a?(AST::ERBContentNode) || node.is_a?(AST::ERBBlockNode)
          return unless node.tag_opening&.value == "<%="

          block = node.is_a?(AST::ERBBlockNode)
          call = PrismAdapter.tag_helper_call(node.content.value, "turbo_frame_tag", block: block)
          id = call&.arguments&.first
          return unless id

          attributes = call.attributes.map { |attribute| build_tag_helper_attribute(node.content, attribute) }
          attributes.compact!
          src = remove_helper_attribute(attributes, "src")
          target = remove_helper_attribute(attributes, "target")
          attributes << build_turbo_frame_id_attribute(node.content, id)
          attributes << src if src
          attributes << target if target
          tag_name = token_slice(
            node.content, "turbo-frame", call.name_start_offset,
            span: call.name_end_offset - call.name_start_offset
          )
          open_location = helper_open_tag_location(node)
          open_tag = AST::ERBOpenTagNode.build(
            tag_opening: node.tag_opening,
            content: node.content,
            tag_closing: node.tag_closing,
            tag_name: tag_name,
            children: attributes,
            location: open_location
          )
          close_tag = if block
                        node.end_node
                      else
                        position = node.location&.end
                        AST::HTMLVirtualCloseTagNode.build(
                          tag_name: tag_name,
                          location: position && Location.new(position, position)
                        )
                      end
          AST::HTMLElementNode.build(
            open_tag: open_tag,
            tag_name: tag_name,
            body: block ? node.body : [],
            close_tag: close_tag,
            is_void: false,
            element_source: "Turbo::FramesHelper#turbo_frame_tag",
            location: node.location,
            errors: node.errors
          )
        end

        def helper_open_tag_location(node)
          Location.new(node.tag_opening.location.start, node.tag_closing.location.end)
        end

        def remove_helper_attribute(attributes, name)
          index = attributes.index do |attribute|
            child = attribute.name&.children&.first if attribute.is_a?(AST::HTMLAttributeNode)
            child&.content == name
          end
          attributes.delete_at(index) if index
        end

        def build_turbo_frame_id_attribute(content, id)
          location = slice_location(content, id.start_offset, id.end_offset - id.start_offset)
          literal = [:string, :symbol].include?(id.kind)
          value_content = if literal || id.source.start_with?("dom_id")
                            id.value || id.source
                          else
                            "dom_id(#{id.source})"
                          end
          build_synthetic_helper_attribute("id", value_content, location, literal: literal)
        end

        def build_synthetic_helper_attribute(name, value_content, location, literal:) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
          name_node = helper_attribute_name(name, location)
          value_child = if literal
                          AST::LiteralNode.build(content: value_content.dup, location: location)
                        else
                          AST::RubyLiteralNode.build(content: value_content.dup, location: location)
                        end
          quote = literal ? helper_token('"', "TOKEN_QUOTE", location&.start, location&.start) : nil
          close_quote = literal ? helper_token('"', "TOKEN_QUOTE", location&.end, location&.end) : nil
          value = AST::HTMLAttributeValueNode.build(
            open_quote: quote,
            children: [value_child],
            close_quote: close_quote,
            quoted: true,
            location: location
          )
          AST::HTMLAttributeNode.build(
            name: name_node,
            equals: helper_token(literal ? "=" : ":", literal ? "TOKEN_EQUALS" : "TOKEN_COLON",
                                 location&.start, location&.end),
            value: value,
            location: location
          )
        end

        def build_tag_helper_attribute(content, attribute) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
          return build_tag_helper_splat(content, attribute) if attribute.splat_source
          return if attribute.name == "escape"

          return build_interpolated_helper_attribute(content, attribute) if attribute.value.kind == :interpolated_string

          name_location = slice_location(
            content, attribute.name_start_offset, attribute.name_end_offset - attribute.name_start_offset
          )
          if action_view_boolean_attribute?(attribute)
            return if attribute.value.kind == :boolean_false
            return build_boolean_helper_attribute(attribute.name, name_location) if attribute.value.kind == :boolean_true

            return build_conditional_helper_attribute(content, attribute, name_location)
          end
          return build_implicit_tag_helper_attribute(content, attribute) if attribute.value.kind == :implicit

          value = build_tag_helper_attribute_value(content, attribute)
          AST::HTMLAttributeNode.build(
            name: helper_attribute_name(attribute.name, name_location),
            equals: helper_token(
              attribute.separator,
              attribute.separator_type,
              helper_position(content, attribute.separator_start_offset),
              helper_position(content, attribute.separator_end_offset)
            ),
            value: value,
            location: helper_location(content, attribute.name_start_offset, attribute.value.end_offset)
          )
        end

        def action_view_boolean_attribute?(attribute)
          static = [:string, :symbol, :integer, :static_array]
          !attribute.prefix && !static.include?(attribute.value.kind) &&
            ACTION_VIEW_BOOLEAN_ATTRIBUTES.include?(attribute.name.downcase)
        end

        def build_interpolated_helper_attribute(content, attribute) # rubocop:disable Metrics/AbcSize
          location = helper_location(content, attribute.name_start_offset, attribute.value.end_offset)
          children = PrismAdapter.interpolated_string_parts(attribute.value.source).map do |kind, value|
            node = kind == :literal ? AST::LiteralNode : AST::RubyLiteralNode
            node.build(content: value.dup, location: location)
          end
          value = AST::HTMLAttributeValueNode.build(
            children: children,
            quoted: false,
            location: location
          )
          AST::HTMLAttributeNode.build(
            name: helper_attribute_name(attribute.name, location),
            equals: helper_token("=", "TOKEN_EQUALS", location&.start, location&.end),
            value: value,
            location: location
          )
        end

        def build_boolean_helper_attribute(name, location)
          AST::HTMLAttributeNode.build(
            name: helper_attribute_name(name, location),
            location: location
          )
        end

        def build_conditional_helper_attribute(content, attribute, name_location) # rubocop:disable Metrics/AbcSize
          condition = attribute.value.kind == :implicit ? attribute.value.value : attribute.value.source
          value_end = attribute.value.end_offset
          end_position = helper_position(content, value_end)
          location = helper_location(content, attribute.name_start_offset, value_end)
          statement = build_boolean_helper_attribute(attribute.name, name_location)
          AST::ERBIfNode.build(
            tag_opening: helper_token("<%", "TOKEN_ERB_START", name_location&.start, name_location&.start),
            content: helper_token(" if (#{condition}) ", "TOKEN_ERB_CONTENT", name_location&.start, end_position),
            tag_closing: helper_token("%>", "TOKEN_ERB_END", end_position, end_position),
            statements: [statement],
            end_node: build_synthetic_end(end_position),
            location: location
          )
        end

        def build_implicit_tag_helper_attribute(content, attribute)
          position = helper_position(content, attribute.name_start_offset)
          location = position && Location.new(position, position)
          AST::HTMLAttributeNode.build(
            name: helper_attribute_name(attribute.name, location),
            equals: helper_token(":", "TOKEN_COLON", position, position),
            value: build_implicit_tag_helper_attribute_value(content, attribute),
            location: location
          )
        end

        def build_tag_helper_splat(content, attribute)
          position = helper_position(content, attribute.splat_offset)
          prefix = attribute.prefix.to_s
          source = if prefix.empty?
                     "tag.attributes(**#{attribute.splat_source})"
                   else
                     "tag.attributes(#{prefix}: #{attribute.splat_source})"
                   end
          AST::RubyHTMLAttributesSplatNode.build(
            content: source,
            prefix: prefix.dup,
            location: position && Location.new(position, position)
          )
        end

        def build_tag_helper_attribute_value(content, attribute) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength, Metrics/PerceivedComplexity
          value = attribute.value
          quoted = value.opening_start_offset && value.closing_start_offset
          value_start = quoted ? value.opening_start_offset : value.content_start_offset
          value_end = quoted ? value.closing_end_offset : value.content_end_offset
          location = helper_location(content, value_start, value_end)
          child_location = helper_location(content, value.content_start_offset, value.content_end_offset)
          if value.kind == :implicit
            return build_implicit_tag_helper_attribute_value(content, attribute)
          end

          literal_kinds = [:string, :symbol, :boolean_true, :boolean_false, :integer]
          literal_kinds << :static_array unless attribute.prefix
          child = if literal_kinds.include?(value.kind)
                    literal = value.value || value.source
                    AST::LiteralNode.build(content: literal.dup, location: child_location)
                  else
                    ruby = value.source
                    ruby = "token_list(#{ruby})" if !attribute.prefix && attribute.name == "class" &&
                                                    [:array, :hash].include?(value.kind)
                    ruby = "::Herb::Engine.nested_attribute_value(#{ruby})" if attribute.prefix
                    AST::RubyLiteralNode.build(content: ruby.dup, location: child_location)
                  end
          AST::HTMLAttributeValueNode.build(
            open_quote: quoted && helper_token(
              '"', "TOKEN_QUOTE",
              helper_position(content, value.opening_start_offset), helper_position(content, value.opening_end_offset)
            ),
            children: [child],
            close_quote: quoted && helper_token(
              '"', "TOKEN_QUOTE",
              helper_position(content, value.closing_start_offset), helper_position(content, value.closing_end_offset)
            ),
            quoted: true,
            location: location
          )
        end

        def build_implicit_tag_helper_attribute_value(content, attribute)
          position = helper_position(content, attribute.name_start_offset)
          location = position && Location.new(position, position)
          AST::HTMLAttributeValueNode.build(
            children: [AST::RubyLiteralNode.build(content: attribute.value.value.dup, location: location)],
            quoted: true,
            location: location
          )
        end

        def helper_attribute_name(name, location)
          AST::HTMLAttributeNameNode.build(
            children: [AST::LiteralNode.build(content: name.dup, location: location)],
            location: location
          )
        end

        def helper_token(value, type, start_position, end_position)
          synthetic_token(value, type, start_position, end_position)
        end

        def helper_location(content, start_offset, end_offset)
          slice_location(content, start_offset, end_offset - start_offset)
        end

        def helper_position(content, offset)
          helper_location(content, offset, offset)&.start
        end

        def prism_output_requested?
          @options.prism_program || @options.prism_nodes || @options.prism_nodes_deep
        end

        def split_multiple_control_tags # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
          index = 0

          while index < @tokens.length - 2
            opening, content, closing = @tokens[index, 3]
            if (case_split = escaped_erb_case_condition(opening, content, closing))
              _offset, keyword, inline = case_split
              @case_condition_tags[content.range.from] = {
                escaped: true,
                inline: inline,
                keyword: keyword,
                location: location_from(opening, closing),
              }
              index += 3
              next
            end
            unless splittable_erb_tag?(opening, content, closing)
              index += 1
              next
            end

            split = control_tag_split(opening, content, closing)
            unless split
              index += 3
              next
            end

            offset, metadata = split
            split_erb_tag(index, opening, content, closing, offset)
            @case_condition_tags[content.range.from] = metadata if metadata
            index += 6
          end
        end

        def prepare_multiple_control_tags
          split_multiple_control_tags if @options.analyze
        end

        def splittable_erb_tag?(opening, content, closing)
          opening.type == "TOKEN_ERB_START" && content.type == "TOKEN_ERB_CONTENT" &&
            closing.type == "TOKEN_ERB_END" && !opening.value.start_with?("<%%") &&
            !custom_erb_opening?(opening)
        end

        def escaped_erb_case_condition(opening, content, closing)
          return unless opening.type == "TOKEN_ERB_START" && opening.value.start_with?("<%%")
          return unless content.type == "TOKEN_ERB_CONTENT" && closing.type == "TOKEN_ERB_END"

          PrismAdapter.case_condition_split(content.value)
        end

        def control_tag_split(opening, content, closing)
          source = content.value
          keyword = leading_ruby_word(source)

          if !PrismAdapter.multiple_unclosed_blocks?(source) &&
             (case_split = PrismAdapter.case_condition_split(source))
            offset, _condition, inline = case_split
            location = location_from(opening, closing)
            return [offset, { inline: inline, location: location }]
          end

          offset = PrismAdapter.continuation_end_offset(source, keyword)
          [offset, nil] if offset
        end

        def split_erb_tag(index, opening, content, closing, relative_offset)
          offset = content.range.from + relative_offset
          first_content = source_token(content.range.from, relative_offset, "TOKEN_ERB_CONTENT")
          second_content = source_token(offset, content.range.to - offset, "TOKEN_ERB_CONTENT")
          omitted_closing = source_token(offset, 0, "TOKEN_ERB_END")
          omitted_opening = source_token(offset, 0, "TOKEN_ERB_START")

          @tokens[index, 3] = [opening, first_content, omitted_closing, omitted_opening, second_content, closing]
        end

        def location_from_offsets(start_offset, end_offset)
          Location.new(position_at(start_offset), position_at(end_offset))
        end

        def prepare_ruby_document
          @ruby_source = Extractor.new(@source, erb_openers: @options.erb_openers).ruby
          @ruby_document = PrismAdapter.parse_document(@ruby_source, serialize: prism_output_requested?)
        end

        def annotate_prism_nodes(document)
          nodes = prism_annotatable_nodes(document)
          full_serializer = @ruby_document.node_serializer
          structural_serializer = if @options.prism_nodes_deep
                                    full_serializer
                                  else
                                    PrismAdapter::NodeSerializer.new(structural_ruby_source(nodes))
                                  end

          nodes.each do |node|
            serializer = prism_content_node?(node) ? full_serializer : structural_serializer
            content = node.content
            serialized = serializer.serialize_for(content.range.from, content.range.to)
            node.instance_variable_set(:@prism_node, serialized) if serialized
          end
        end

        def prism_annotatable_nodes(document)
          nodes = []
          queue = [document]

          until queue.empty?
            node = queue.shift
            nodes << node if prism_content_node?(node) || prism_structural_node?(node)
            queue.concat(node.compact_child_nodes)
          end

          nodes
        end

        def prism_content_node?(node)
          node.is_a?(AST::ERBContentNode) || node.is_a?(AST::ERBRenderNode)
        end

        def prism_structural_node?(node)
          case node
          when AST::ERBIfNode, AST::ERBUnlessNode, AST::ERBCaseNode, AST::ERBCaseMatchNode,
               AST::ERBWhileNode, AST::ERBUntilNode, AST::ERBForNode, AST::ERBBeginNode,
               AST::ERBBlockNode, AST::ERBIterationBlockNode
            true
          else
            false
          end
        end

        def structural_ruby_source(nodes)
          source = @ruby_source.dup

          nodes.each do |node|
            next unless prism_content_node?(node)

            (node.content.range.from...node.content.range.to).each { |offset| source.setbyte(offset, 32) }
          end

          source
        end

        def add_ruby_parse_errors(document)
          @ruby_document.result.errors.each do |error|
            next if skip_forwarding_error?(document, error)

            if artificial_semicolon_error?(error)
              add_erb_content_parse_error(document, error.location.start_offset)
            else
              document.errors << prism_parse_error(error)
            end
          end
        end

        def skip_forwarding_error?(document, error)
          return true if recovered_raw_text_closing_error?(document, error.location.start_offset)
          return false unless error.type == :argument_no_forwarding_star_star
          return true unless @options.strict_locals

          document.children.any? do |child|
            child.is_a?(AST::ERBStrictLocalsNode) &&
              child.locals.any? { |local| local.kind == "keyword_rest" && local.name.nil? }
          end
        end

        def recovered_raw_text_closing_error?(document, offset) # rubocop:disable Metrics/AbcSize, Metrics/PerceivedComplexity
          queue = document.compact_child_nodes.dup

          until queue.empty?
            node = queue.shift
            if node.is_a?(AST::HTMLElementNode) && RAW_TEXT_ELEMENTS.include?(node.tag_name&.value&.downcase) &&
               node.close_tag
              erb = node.body.last
              if erb.is_a?(AST::ERBContentNode) && erb.valid &&
                 erb.errors.any?(Errors::UnclosedERBTagError) &&
                 offset >= erb.content.range.to && offset < node.close_tag.tag_closing.range.to
                return true
              end
            end
            queue.concat(node.compact_child_nodes)
          end

          false
        end

        def artificial_semicolon_error?(error)
          offset = error.location.start_offset
          error.message.include?("unexpected ';'") && @ruby_source.getbyte(offset) == 59 && @source.getbyte(offset) != 59
        end

        def add_erb_content_parse_error(document, offset)
          node = find_erb_content_at_offset(document, offset)
          return unless node

          error = PrismAdapter.parse_document(node.content.value).result.errors.first
          node.errors << prism_parse_error(error, location: node.location) if error
        end

        def find_erb_content_at_offset(document, offset)
          queue = document.compact_child_nodes.dup

          until queue.empty?
            node = queue.shift
            if node.is_a?(AST::ERBContentNode) && node.tag_opening.range.from <= offset &&
               offset <= node.tag_closing.range.to
              return node
            end

            queue.concat(node.compact_child_nodes)
          end

          nil
        end

        def prism_parse_error(error, location: nil)
          diagnostic_id = error.type.to_s
          ruby_parse_error(
            location || slice_location_from_offsets(error.location.start_offset, error.location.end_offset),
            diagnostic_id,
            error.message,
            level: error.level.to_s
          )
        end

        def slice_location_from_offsets(start_offset, end_offset)
          Location.new(position_at(start_offset), position_at(end_offset))
        end

        def parse_children(closing_name = nil, boundaries: []) # rubocop:disable Metrics/AbcSize
          children = []

          until eof? || boundaries.include?(erb_keyword) || past_deadline?
            break if element_boundary?(closing_name, children)

            child = parse_child(boundaries)
            child.is_a?(Array) ? children.concat(child) : children << child
          end

          if conditional_open_tag_close_in_scope?(children)
            children << parse_orphan_close_tag
            return finish_children(children) + parse_children(closing_name, boundaries: boundaries)
          end

          finish_children(children)
        end

        def parse_child(boundaries)
          return parse_non_html_child unless @options.html
          return parse_document_declaration if DOCUMENT_DECLARATION_TYPES.include?(current.type)

          case current.type
          when "TOKEN_HTML_TAG_START" then parse_element(boundaries: boundaries)
          when "TOKEN_HTML_TAG_START_CLOSE" then parse_orphan_close_tag
          when "TOKEN_HTML_COMMENT_START" then parse_html_comment
          when "TOKEN_ERB_START" then parse_erb_child
          else parse_text
          end
        end

        def parse_non_html_child
          current.type == "TOKEN_ERB_START" ? parse_erb_child : parse_literal_text
        end

        def parse_document_declaration
          return parse_doctype if current.type == "TOKEN_HTML_DOCTYPE"
          return parse_xml_declaration if current.type == "TOKEN_XML_DECLARATION"
          return parse_xml_processing_instruction if current.type == "TOKEN_XML_PROCESSING_INSTRUCTION_START"

          parse_cdata
        end

        def parse_doctype
          opening = advance
          children = parse_delimited_literal_children(["TOKEN_HTML_TAG_END"])
          closing = take("TOKEN_HTML_TAG_END")

          AST::HTMLDoctypeNode.build(
            tag_opening: node_token(opening),
            children: children,
            tag_closing: closing && node_token(closing),
            location: location_from(opening, closing || children.last || opening)
          )
        end

        def parse_xml_declaration
          opening = advance
          @xml_document = true
          children = parse_delimited_literal_children(["TOKEN_XML_DECLARATION_END"])
          closing = take("TOKEN_XML_DECLARATION_END")

          AST::XMLDeclarationNode.build(
            tag_opening: node_token(opening),
            children: children,
            tag_closing: closing && node_token(closing),
            location: location_from(opening, closing || children.last || opening)
          )
        end

        def parse_xml_processing_instruction
          opening = advance
          target = take("TOKEN_IDENTIFIER")
          children = parse_xml_processing_instruction_children
          closing = take("TOKEN_HTML_TAG_END") || take("TOKEN_XML_DECLARATION_END")
          errors = []
          unless closing
            closing = current
            errors << unexpected_xml_processing_instruction_end_error(closing)
          end

          AST::XMLProcessingInstructionNode.build(
            tag_opening: node_token(opening),
            target: node_token(target),
            children: children,
            tag_closing: node_token(closing),
            location: location_from(opening, closing),
            errors: errors
          )
        end

        def parse_xml_processing_instruction_children(boundaries: [])
          parse_delimited_literal_children(
            ["TOKEN_XML_DECLARATION_END", "TOKEN_HTML_TAG_END"],
            boundaries: boundaries,
            control_context: :xml_processing_instruction
          )
        end

        def unexpected_xml_processing_instruction_end_error(found)
          position = found.location.start
          Errors::UnexpectedTokenError.new(
            "UNEXPECTED_TOKEN_ERROR",
            found.location,
            "Found end of file when expecting `?>` at #{position.tree_inspect}.",
            "TOKEN_XML_DECLARATION_END",
            node_token(found)
          )
        end

        def parse_cdata
          opening = advance
          children = parse_cdata_children
          closing = take("TOKEN_CDATA_END")

          AST::CDATANode.build(
            tag_opening: node_token(opening),
            children: children,
            tag_closing: closing && node_token(closing),
            location: location_from(opening, closing || children.last || opening)
          )
        end

        def parse_cdata_children(boundaries: [])
          parse_delimited_literal_children(["TOKEN_CDATA_END"], boundaries: boundaries, control_context: :cdata)
        end

        def parse_delimited_literal_children(end_types, boundaries: [], control_context: nil)
          children = []
          literal_tokens = []

          until eof? || end_types.include?(current.type) || boundaries.include?(erb_keyword)
            if current.type == "TOKEN_ERB_START"
              append_literal(children, literal_tokens)
              children << parse_delimited_erb(control_context)
            else
              literal_tokens << advance
            end
          end

          append_literal(children, literal_tokens)
          children
        end

        def append_literal(children, tokens)
          return if tokens.empty?

          children << literal_from(tokens)
          tokens.clear
        end

        def parse_delimited_erb(control_context)
          return parse_erb unless control_context && body_control_erb?

          parse_attribute_control(context: control_context)
        end

        def conditional_open_tag_close_in_scope?(children)
          return false unless @options.analyze && current.type == "TOKEN_HTML_TAG_START_CLOSE"

          closing_name = @tokens[@index + 1]&.value
          return false unless closing_name

          children.any? do |child|
            candidate = conditional_open_tag_candidate(child)
            candidate && candidate[:tag_name].casecmp?(closing_name)
          end
        end

        def finish_children(children)
          return children unless @options.analyze

          transform_conditional_elements(children)
          transform_conditional_open_tags(children)
        end

        def transform_conditional_open_tags(children)
          children.each_with_index do |node, index|
            candidate = conditional_open_tag_candidate(node)
            next unless candidate

            close_index = matching_conditional_open_tag_close_index(children, index, candidate[:tag_name])
            next unless close_index

            if candidate[:tags].any? { |tags| tags.length > 1 }
              add_conditional_open_tag_multiple_tags_error(node, candidate[:tags])
              next
            end

            replace_conditional_open_tag(children, index, close_index, candidate)
            break transform_conditional_open_tags(children)
          end

          children
        end

        def conditional_open_tag_candidate(node) # rubocop:disable Metrics/AbcSize, Metrics/PerceivedComplexity
          branches = conditional_open_tag_branches(node)
          return unless branches

          tags = branches.map { |statements| conditional_open_tag_branch_tags(statements) }
          return if tags.any?(&:nil?)

          tag_name = tags.first.first.tag_name.value
          return unless tags.all? { |branch_tags| branch_tags.first.tag_name.value.casecmp?(tag_name) }
          return if tags.flatten.any? { |tag| tag.is_void || VOID_ELEMENTS.include?(tag.tag_name.value.downcase) }

          { tags: tags, tag_name: tag_name }
        end

        def conditional_open_tag_branches(node)
          case node
          when AST::ERBIfNode
            conditional_if_open_tag_branches(node)
          when AST::ERBUnlessNode
            [node.statements, node.else_clause.statements] if node.end_node && node.else_clause
          end
        end

        def conditional_if_open_tag_branches(node)
          return unless node.end_node

          branches = []
          current_branch = node
          while current_branch.is_a?(AST::ERBIfNode)
            branches << current_branch.statements
            current_branch = current_branch.subsequent
          end
          return unless current_branch.is_a?(AST::ERBElseNode)

          branches << current_branch.statements
        end

        def conditional_open_tag_branch_tags(statements)
          first = statements.find do |statement|
            !statement.is_a?(AST::HTMLTextNode) || !statement.content.strip.empty?
          end
          return unless first.is_a?(AST::HTMLOpenTagNode)

          statements.grep(AST::HTMLOpenTagNode)
        end

        def matching_conditional_open_tag_close_index(children, opening_index, tag_name)
          children.each_index.find do |index|
            index > opening_index && children[index].is_a?(AST::HTMLCloseTagNode) &&
              children[index].tag_name.value.casecmp?(tag_name)
          end
        end

        def replace_conditional_open_tag(children, opening_index, closing_index, candidate) # rubocop:disable Metrics/AbcSize
          conditional = children[opening_index]
          close_tag = children[closing_index]
          tags = candidate[:tags].flatten
          tags.each { |tag| tag.errors.reject! { |error| error.is_a?(Errors::MissingClosingTagError) } }
          close_tag.errors.reject! { |error| error.is_a?(Errors::MissingOpeningTagError) }
          flatten_conditional_open_tag_elements(conditional)
          tag_name = tags.first.tag_name
          open_tag = conditional_open_tag_node(conditional, tag_name)
          element = AST::HTMLElementNode.build(
            open_tag: open_tag,
            tag_name: tag_name,
            body: children[(opening_index + 1)...closing_index],
            close_tag: close_tag,
            is_void: false,
            element_source: "HTML",
            location: location_from(conditional, close_tag)
          )
          children[opening_index..closing_index] = [element]
        end

        def conditional_open_tag_node(conditional, tag_name)
          AST::HTMLConditionalOpenTagNode.build(
            conditional: conditional,
            tag_name: tag_name,
            is_void: false,
            location: conditional.location
          )
        end

        def flatten_conditional_open_tag_elements(conditional)
          conditional_open_tag_branches(conditional).each do |statements|
            statements.replace(statements.flat_map { |statement| flatten_html_element(statement) })
          end
        end

        def flatten_html_element(node)
          return [node] unless node.is_a?(AST::HTMLElementNode)

          [node.open_tag, *node.body.flat_map { |child| flatten_html_element(child) }, node.close_tag].compact
        end

        def add_conditional_open_tag_multiple_tags_error(node, branch_tags)
          extra_tag = branch_tags.find { |tags| tags.length > 1 }[1]
          position = position_at(extra_tag.tag_opening.range.from)
          message = "Conditional element pattern detected at #{position.tree_inspect} but the conditional block " \
                    "contains multiple HTML tags. Each conditional element must wrap exactly one opening and one " \
                    "closing tag. Consider nesting the conditionals individually."
          node.errors << Errors::ConditionalElementMultipleTagsError.new(
            "CONDITIONAL_ELEMENT_MULTIPLE_TAGS_ERROR", node.location, message, position.line, position.column
          )
        end

        def transform_conditional_elements(children)
          while (pair = transformable_conditional_element_pair(children))
            opening, closing = pair
            replace_conditional_element(children, opening, closing)
          end
          add_conditional_element_errors(children)
          children
        end

        def transformable_conditional_element_pair(children)
          conditional_element_pairs(children).find do |opening, closing|
            matching_conditional_element_parts?(opening, closing) && opening[:tags].one? &&
              opening[:condition] == closing[:condition]
          end
        end

        def conditional_element_pairs(children)
          openings = []
          pairs = []

          children.each_with_index do |node, index|
            if (part = conditional_element_part(node, AST::HTMLOpenTagNode, index))
              openings << part
            elsif (part = conditional_element_part(node, AST::HTMLCloseTagNode, index)) && openings.any?
              pairs << [openings.pop, part]
            end
          end

          pairs
        end

        def conditional_element_part(node, tag_class, index)
          return unless simple_conditional_node?(node)
          return unless node.statements.all? { |statement| conditional_element_statement?(statement, tag_class) }

          tags = node.statements.grep(tag_class)
          return if tags.empty?

          { node: node, tags: tags, condition: conditional_element_condition(node), index: index }
        end

        def conditional_element_statement?(statement, tag_class)
          statement.is_a?(tag_class) ||
            (statement.is_a?(AST::HTMLTextNode) && statement.content.strip.empty?)
        end

        def simple_conditional_node?(node)
          return false unless node.is_a?(AST::ERBIfNode) || node.is_a?(AST::ERBUnlessNode)
          return false unless node.end_node

          node.is_a?(AST::ERBIfNode) ? node.subsequent.nil? : node.else_clause.nil?
        end

        def conditional_element_condition(node)
          keyword = node.is_a?(AST::ERBIfNode) ? "if" : "unless"
          node.content.value.sub(/\A\s*#{keyword}\s+/, "").strip
        end

        def matching_conditional_element_parts?(opening, closing)
          return false unless closing[:node].instance_of?(opening[:node].class)

          open_names = conditional_element_tag_names(opening)
          close_names = conditional_element_tag_names(closing).reverse
          open_names.length == close_names.length && open_names.zip(close_names).all? { |left, right| left.casecmp?(right) }
        end

        def conditional_element_tag_names(part)
          part[:tags].map { |tag| tag.tag_name.value }
        end

        def replace_conditional_element(children, opening, closing) # rubocop:disable Metrics/AbcSize
          open_tag = opening[:tags].first
          close_tag = closing[:tags].first
          remove_conditional_tag_errors(open_tag, close_tag)
          body = children[(opening[:index] + 1)...closing[:index]]
          node = AST::HTMLConditionalElementNode.build(
            condition: opening[:condition].dup,
            open_conditional: opening[:node],
            open_tag: open_tag,
            body: body,
            close_tag: close_tag,
            close_conditional: closing[:node],
            tag_name: open_tag.tag_name,
            element_source: "HTML",
            location: location_from(opening[:node], closing[:node])
          )
          children[opening[:index]..closing[:index]] = [node]
        end

        def remove_conditional_tag_errors(open_tag, close_tag)
          open_tag.errors.reject! { |error| error.is_a?(Errors::MissingClosingTagError) }
          close_tag.errors.reject! { |error| error.is_a?(Errors::MissingOpeningTagError) }
        end

        def add_conditional_element_errors(children)
          conditional_element_pairs(children).each do |opening, closing|
            error = conditional_element_error(opening, closing)
            @document_errors << error if error
          end
        end

        def conditional_element_error(opening, closing)
          return unless matching_conditional_element_parts?(opening, closing)
          return conditional_element_multiple_tags_error(opening) if multiple_conditional_element_tags?(opening, closing)
          return unless opening[:tags].one? && opening[:condition] != closing[:condition]

          conditional_element_condition_mismatch_error(opening, closing)
        end

        def multiple_conditional_element_tags?(opening, closing)
          opening[:tags].length > 1 && opening[:condition] == closing[:condition]
        end

        def conditional_element_multiple_tags_error(opening)
          node = opening[:node]
          position = position_at(node.tag_opening.range.from)
          message = "Conditional element pattern detected at #{position.tree_inspect} but the conditional block " \
                    "contains multiple HTML tags. Each conditional element must wrap exactly one opening and one " \
                    "closing tag. Consider nesting the conditionals individually."
          Errors::ConditionalElementMultipleTagsError.new(
            "CONDITIONAL_ELEMENT_MULTIPLE_TAGS_ERROR", error_location(node), message, position.line, position.column
          )
        end

        def conditional_element_condition_mismatch_error(opening, closing) # rubocop:disable Metrics/AbcSize
          open_node = opening[:node]
          close_node = closing[:node]
          open_position = position_at(open_node.tag_opening.range.from)
          close_position = position_at(close_node.tag_opening.range.from)
          tag_name = opening[:tags].first.tag_name.value
          message = "Conditional element `<#{tag_name}>` has mismatched conditions: opening uses " \
                    "`#{opening[:condition]}` at #{open_position.tree_inspect} but closing uses " \
                    "`#{closing[:condition]}` at #{close_position.tree_inspect}. Both conditions must be identical."
          Errors::ConditionalElementConditionMismatchError.new(
            "CONDITIONAL_ELEMENT_CONDITION_MISMATCH_ERROR",
            error_location(open_node, close_node),
            message,
            tag_name,
            opening[:condition],
            open_position.line,
            open_position.column,
            closing[:condition],
            close_position.line,
            close_position.column
          )
        end

        def error_location(first, last = first)
          start_offset = first.tag_opening.range.from
          end_offset = last.end_node.tag_closing.range.to
          slice_location_from_offsets(start_offset, end_offset)
        end

        def parse_erb_child
          body_control_erb? ? parse_attribute_control(context: :body) : parse_erb
        end

        def parse_element(boundaries: []) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
          @boolean_attribute_location_quirk = false
          opening_index = @index
          opening_token = current
          name_token = @tokens[@index + 1]
          open_tag = parse_open_tag
          opening_location = Location.new(opening_token.location.start, @tokens[@index - 1].location.end)
          name = open_tag.tag_name

          return open_tag if open_tag.tag_closing.nil? && VOID_ELEMENTS.include?(name.value.downcase)

          void = open_tag.is_void || html_void_element?(name.value)
          raw_text = raw_text_element?(name.value)
          escapable_text = escapable_text_element?(name.value)
          if open_tag.tag_closing && flatten_unclosed_element?(name, void, raw_text, escapable_text, opening_index)
            open_tag.errors << missing_closing_tag_error(opening_location, name_token)
            return open_tag
          end

          @boolean_attribute_location_quirk = boolean_attribute_location_quirk?(open_tag)

          body = if void
                   []
                 else
                   @element_names << name.value
                   begin
                     if raw_text
                       parse_raw_text_children(raw_text_closing_name(name.value))
                     elsif escapable_text
                       parse_escapable_text_element_children(name.value)
                     else
                       parse_children(name.value, boundaries: boundaries)
                     end
                   ensure
                     @element_names.pop
                   end
                 end
          @boolean_attribute_location_quirk = false unless void
          close_tag = !void && matching_close_tag?(name.value) ? parse_close_tag : nil
          unless void || close_tag
            return [open_tag, *body] unless open_tag.tag_closing

            if optional_end_boundary?(name.value, body, boundaries)
              return build_element_with_omitted_close_tag(open_tag, name, body)
            end

            error = missing_closing_tag_error(raw_text ? name_token.location : opening_location, name_token)
            if raw_text
              return AST::HTMLElementNode.build(
                open_tag: open_tag,
                tag_name: name,
                body: body,
                is_void: false,
                element_source: "HTML",
                location: location_from(open_tag, open_tag),
                errors: [error]
              )
            end

            open_tag.errors << error
            return [open_tag, *body]
          end
          finish = close_tag || open_tag

          AST::HTMLElementNode.build(
            open_tag: open_tag,
            tag_name: name,
            body: body,
            close_tag: close_tag,
            is_void: void,
            element_source: "HTML",
            location: location_from(open_tag, finish)
          )
        end

        def flatten_unclosed_element?(name, void, raw_text, escapable_text, opening_index)
          !void && !raw_text && !escapable_text &&
            !OPTIONAL_END_ELEMENTS.include?(name.value.downcase) &&
            !matched_opening_tag_indices.include?(opening_index)
        end

        def build_element_with_omitted_close_tag(open_tag, name, body)
          insertion_point = current.location.start
          point = Location.new(insertion_point, insertion_point)
          close_tag = AST::HTMLOmittedCloseTagNode.build(tag_name: name, location: point)
          errors = @options.strict ? [omitted_closing_tag_error(open_tag, name, insertion_point)] : []

          AST::HTMLElementNode.build(
            open_tag: open_tag,
            tag_name: name,
            body: body,
            close_tag: close_tag,
            is_void: false,
            element_source: "HTML",
            location: Location.new(open_tag.location.start, insertion_point),
            errors: errors
          )
        end

        def omitted_closing_tag_error(open_tag, name, insertion_point)
          Errors::OmittedClosingTagError.new(
            "OMITTED_CLOSING_TAG_ERROR",
            open_tag.location,
            "Element `<#{name.value}>` at #{name.location.start.tree_inspect} has its closing tag omitted. " \
            "While valid HTML, consider adding an explicit `</#{name.value}>` closing tag at " \
            "#{insertion_point.tree_inspect} for clarity, or set `strict: false` to allow this.",
            name,
            insertion_point
          )
        end

        def parse_raw_text_children(closing_name)
          children = []
          literal_tokens = []

          until eof? || raw_text_end?(closing_name)
            if current.type == "TOKEN_ERB_START"
              children << literal_from(literal_tokens) if literal_tokens.any?
              literal_tokens = []
              prepare_raw_text_erb(closing_name)
              children << parse_erb
            else
              literal_tokens << advance
            end
          end

          children << literal_from(literal_tokens) if literal_tokens.any?
          children
        end

        def raw_text_end?(closing_name)
          closing_name && matching_close_tag?(closing_name)
        end

        def parse_escapable_text_element_children(closing_name)
          previous_closing_name = @escapable_text_closing_name
          @escapable_text_closing_name = closing_name
          parse_escapable_text_children(closing_name)
        ensure
          @escapable_text_closing_name = previous_closing_name
        end

        def parse_escapable_text_children(closing_name, boundaries: [])
          children = []
          text_tokens = []

          until eof? || raw_text_end?(closing_name) || boundaries.include?(erb_keyword)
            if current.type == "TOKEN_ERB_START"
              append_html_text(children, text_tokens)
              prepare_raw_text_erb(closing_name)
              children << parse_delimited_erb(:escapable_text)
            else
              text_tokens << advance
            end
          end

          append_html_text(children, text_tokens)
          children
        end

        def append_html_text(children, tokens)
          return if tokens.empty?

          children << AST::HTMLTextNode.build(
            content: tokens.map(&:value).join,
            location: location_from(tokens.first, tokens.last)
          )
          tokens.clear
        end

        def prepare_raw_text_erb(closing_name)
          split_unclosed_erb_at_raw_close(closing_name) if closing_name
        end

        def raw_text_element?(name)
          normalized = name.downcase
          return !@xml_document if normalized == "plaintext"
          return false unless RAW_TEXT_ELEMENTS.include?(normalized)
          return true unless RAW_TEXT_REQUIRING_CLOSE.include?(normalized)

          matching_close_tag_ahead?(name)
        end

        def escapable_text_element?(name)
          return false if @xml_document || svg_context?
          return false unless ESCAPABLE_TEXT_ELEMENTS.include?(name.downcase)

          matching_close_tag_ahead?(name)
        end

        def html_void_element?(name)
          VOID_ELEMENTS.include?(name.downcase) && !svg_context?
        end

        def svg_context?
          @element_names.any? { |ancestor| ancestor.casecmp?("svg") }
        end

        def raw_text_closing_name(name)
          name unless name.casecmp?("plaintext")
        end

        def matching_close_tag_ahead?(name)
          index = @index

          until @tokens[index]&.type == "TOKEN_EOF"
            return true if @tokens[index].type == "TOKEN_HTML_TAG_START_CLOSE" &&
                           tag_name_at(index + 1)&.casecmp?(name)

            index += 1
          end

          false
        end

        def boolean_attribute_location_quirk?(open_tag)
          return false unless @options.track_whitespace

          attribute = open_tag.children.reverse.find { |child| child.is_a?(AST::HTMLAttributeNode) }
          attribute && attribute.value.nil?
        end

        def split_unclosed_erb_at_raw_close(closing_name) # rubocop:disable Metrics/AbcSize, Metrics/PerceivedComplexity
          content = @tokens[@index + 1]
          return unless content&.type == "TOKEN_ERB_CONTENT"
          return if @tokens[@index + 2]&.type == "TOKEN_ERB_END"

          match = content.value.match(%r{</#{Regexp.escape(closing_name)}(?=[\s>])}i)
          return unless match

          prefix = match.pre_match
          return unless current.value == "<%#" || PrismAdapter.valid?(prefix)

          closing_offset = content.range.from + prefix.bytesize
          remaining_tokens = Lexer.new(@source.byteslice(closing_offset..), erb_openers: @options.erb_openers).tokens
          remaining_tokens.map! do |token|
            start_offset = closing_offset + token.range.from
            source_token(start_offset, token.value.bytesize, token.type)
          end
          @tokens[(@index + 1)..] = [source_token(content.range.from, prefix.bytesize, content.type), *remaining_tokens]
        end

        def parse_open_tag # rubocop:disable Metrics/AbcSize
          opening = take("TOKEN_HTML_TAG_START")
          name = parse_tag_name
          unsupported!("an HTML tag without a name") unless name

          attributes, tag_closing, open_tag_errors = parse_open_tag_children
          finish = tag_closing || @tokens[@index - 1]
          casing_error = dot_notation_casing_error(name)
          open_tag_errors << casing_error if casing_error
          open_tag_errors << unclosed_open_tag_error(name, finish) unless tag_closing
          self_closing = tag_closing&.type == "TOKEN_HTML_TAG_SELF_CLOSE"
          AST::HTMLOpenTagNode.build(
            tag_opening: node_token(opening),
            tag_name: node_token(name),
            tag_closing: tag_closing && node_token(tag_closing),
            children: attributes,
            is_void: self_closing,
            location: location_from(opening, finish),
            errors: open_tag_errors
          )
        end

        def parse_tag_name # rubocop:disable Metrics/AbcSize
          first = take("TOKEN_IDENTIFIER")
          return first unless first && @options.dot_notation_tags

          tokens = [first]
          tokens << advance << advance while current.value == "." && @tokens[@index + 1]&.type == "TOKEN_IDENTIFIER"
          return first if tokens.one?

          source_token(first.range.from, tokens.last.range.to - first.range.from, "TOKEN_IDENTIFIER")
        end

        def tag_name_at(index) # rubocop:disable Metrics/AbcSize, Metrics/PerceivedComplexity
          index += 1 while WHITESPACE_TOKEN_TYPES.include?(@tokens[index]&.type)
          first = @tokens[index]
          return unless first&.type == "TOKEN_IDENTIFIER"
          return first.value unless @options.dot_notation_tags

          value = first.value.dup
          while @tokens[index + 1]&.value == "." && @tokens[index + 2]&.type == "TOKEN_IDENTIFIER"
            value << "." << @tokens[index + 2].value
            index += 2
          end
          value
        end

        def source_tag_name_at(index)
          index += 1 while WHITESPACE_TOKEN_TYPES.include?(@tokens[index]&.type)
          first = @tokens[index]
          return first unless first&.type == "TOKEN_IDENTIFIER" && @options.dot_notation_tags

          value = tag_name_at(index)
          return first if value == first.value

          source_token(first.range.from, value.bytesize, "TOKEN_IDENTIFIER")
        end

        def dot_notation_casing_error(name)
          return unless @options.dot_notation_tags && name.value.include?(".")

          first_segment = name.value.split(".", 2).first
          return if first_segment.match?(/\A[A-Z]/)

          segment = source_token(name.range.from, first_segment.bytesize, "TOKEN_IDENTIFIER")
          Errors::DotNotationCasingError.new(
            "DOT_NOTATION_CASING_ERROR",
            segment.location,
            "Dot-notation component tags require the first segment to start with an uppercase letter. " \
            "`#{first_segment}` does not start with an uppercase letter.",
            node_token(segment)
          )
        end

        def parse_html_comment
          opening = advance
          nested_starts = comment_nested_starts
          children = parse_comment_children
          closing = take_comment_end
          errors = comment_errors(opening, nested_starts, closing)

          AST::HTMLCommentNode.build(
            comment_start: node_token(opening),
            children: children,
            comment_end: node_token(closing),
            location: location_from(opening, closing),
            errors: errors
          )
        end

        def parse_comment_children(boundaries: []) # rubocop:disable Metrics/AbcSize, Metrics/PerceivedComplexity
          children = []
          literal_tokens = []

          until eof? || comment_end? || boundaries.include?(erb_keyword)
            if abrupt_comment_end?
              literal_tokens << abrupt_comment_content_token
              break
            elsif current.type == "TOKEN_ERB_START"
              children << literal_from(literal_tokens) if literal_tokens.any?
              literal_tokens = []
              children << (body_control_erb? ? parse_attribute_control(context: :comment) : parse_erb)
            else
              literal_tokens << comment_content_token
            end
          end

          children << literal_from(literal_tokens) if literal_tokens.any?
          children
        end

        def comment_content_token
          return abrupt_comment_content_token if abrupt_comment_end?

          advance
        end

        def comment_end?
          ["TOKEN_HTML_COMMENT_END", "TOKEN_HTML_COMMENT_INVALID_END"].include?(current.type)
        end

        def abrupt_comment_end?(index = @index)
          @tokens[index]&.type == "TOKEN_HTML_COMMENT_START" &&
            @tokens[index + 1]&.type == "TOKEN_HTML_TAG_END"
        end

        def abrupt_comment_content_token
          token = current
          source_token(token.range.from, 2, "TOKEN_CHARACTER")
        end

        def take_comment_end
          return advance if ["TOKEN_HTML_COMMENT_END", "TOKEN_HTML_COMMENT_INVALID_END"].include?(current.type)
          return current unless abrupt_comment_end?

          offset = current.range.from + 2
          advance
          advance
          source_token(offset, 3, "TOKEN_HTML_COMMENT_END")
        end

        def comment_nested_starts
          nested_starts = []
          index = @index

          until @tokens[index].type == "TOKEN_EOF" || comment_end_at?(index)
            if @tokens[index].type == "TOKEN_HTML_COMMENT_START" && @tokens[index + 1].type != "TOKEN_EOF"
              nested_starts << @tokens[index]
            end
            index += 1
          end

          nested_starts
        end

        def comment_end_at?(index)
          ["TOKEN_HTML_COMMENT_END", "TOKEN_HTML_COMMENT_INVALID_END"].include?(@tokens[index].type) ||
            abrupt_comment_end?(index)
        end

        def comment_errors(opening, nested_starts, closing)
          errors = @options.strict ? nested_starts.map { |nested| nested_comment_error(opening, nested) } : []
          errors << invalid_comment_closing_error(closing) if closing.type == "TOKEN_HTML_COMMENT_INVALID_END"
          errors << unclosed_comment_error(opening, closing) if closing.type == "TOKEN_EOF"
          errors
        end

        def nested_comment_error(opening, nested)
          Errors::NestedCommentError.new(
            "NESTED_COMMENT_ERROR",
            nested.location,
            "Comment opened at #{opening.location.start.tree_inspect} contains another `<!--` at " \
            "#{nested.location.start.tree_inspect}.",
            node_token(opening),
            node_token(nested)
          )
        end

        def invalid_comment_closing_error(closing)
          Errors::InvalidCommentClosingTagError.new(
            "INVALID_COMMENT_CLOSING_TAG_ERROR",
            closing.location,
            "Invalid comment closing tag `--!>` at #{closing.location.start.tree_inspect}. " \
            "Use `-->` instead of `--!>`.",
            node_token(closing)
          )
        end

        def unclosed_comment_error(opening, finish)
          Errors::UnclosedCommentError.new(
            "UNCLOSED_COMMENT_ERROR",
            location_from(opening, finish),
            "Comment opened at #{opening.location.start.tree_inspect} is missing its closing `-->`.",
            node_token(opening)
          )
        end

        def parse_open_tag_children # rubocop:disable Metrics/AbcSize, Metrics/MethodLength, Metrics/PerceivedComplexity
          children = []
          errors = []
          separated = true

          until tag_closing? || eof? || HTML_TAG_START_TYPES.include?(current.type)
            if whitespace?
              whitespace = advance
              children << whitespace_node(whitespace) if @options.track_whitespace
              separated = true
            elsif stray_erb_closing?
              opening = advance
              closing = advance
              errors << stray_erb_closing_error(opening, closing)
              children << AST::LiteralNode.build(content: +"%>", location: location_from(opening, closing))
              separated = true
            elsif current.type == "TOKEN_SLASH"
              errors << unexpected_solidus_in_tag_error(advance)
              separated = true
            elsif current.type == "TOKEN_ERB_START" && !erb_attribute_name?
              children << parse_open_tag_erb_child
              separated = true
            else
              errors << missing_attribute_whitespace_error(current) unless separated
              errors << unexpected_equals_before_attribute_name_error(current) if current.type == "TOKEN_EQUALS"
              children << parse_attribute
              separated = @recovered_attribute_separator
              @recovered_attribute_separator = false
            end
          end

          [children, tag_closing? ? advance : nil, errors]
        end

        def parse_open_tag_erb_child
          attribute_control_erb? ? parse_attribute_control(context: :attribute) : parse_erb
        end

        def erb_attribute_name?
          return false unless current.value.start_with?("<%=")

          index = @index + 3
          loop do
            token = @tokens[index]
            return false unless token
            return true if token.type == "TOKEN_EQUALS"
            return false unless ATTRIBUTE_NAME_LOOKAHEAD_TYPES.include?(token.type)

            index += token.type == "TOKEN_ERB_START" ? 3 : 1
          end
        end

        def parse_attribute # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
          name, name_tokens = parse_attribute_name
          unsupported!("an HTML attribute without a name") unless name

          equals = nil
          value = nil
          finish = name
          whitespace_before_equals = following_whitespace

          if token_after(whitespace_before_equals.length)&.type == "TOKEN_EQUALS"
            whitespace_before_equals.length.times { advance }
            equals_token = advance
            whitespace_after_equals = following_whitespace
            whitespace_after_equals.length.times { advance }
            equals = attribute_equals(equals_token, whitespace_before_equals, whitespace_after_equals)
            value = parse_attribute_value(name_tokens, equals_token)
            finish = value || equals
          end

          attribute = AST::HTMLAttributeNode.build(
            name: name,
            equals: equals,
            value: value,
            location: location_from(name, finish)
          )
          apply_tracked_boolean_attribute_location_quirk unless equals
          attribute
        end

        def apply_tracked_boolean_attribute_location_quirk # rubocop:disable Metrics/AbcSize
          return unless @options.track_whitespace

          first = @tokens[@index + 1]
          return unless first

          lookahead = @index + 1
          lookahead += 1 while WHITESPACE_TOKEN_TYPES.include?(@tokens[lookahead]&.type)
          peeked = @tokens[lookahead]
          return unless peeked

          @tokens[@index + 1] = Token.new(
            first.value,
            Range.new(peeked.range.to, first.range.to),
            Location.new(peeked.location.end, first.location.end),
            first.type
          )
        end

        def parse_attribute_name # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
          start_index = @index
          children = []
          literal_tokens = []

          until attribute_name_ending?(current, initial: @index == start_index) || structural_control_flow_erb?
            if current.type == "TOKEN_ERB_START"
              children << literal_from(literal_tokens) if literal_tokens.any?
              literal_tokens = []
              children << parse_erb
            else
              literal_tokens << advance
            end
          end

          children << literal_from(literal_tokens) if literal_tokens.any?
          tokens = @tokens[start_index...@index]
          return [nil, tokens] if children.empty?

          name = AST::HTMLAttributeNameNode.build(
            children: children,
            location: location_from(children.first, children.last),
            errors: attribute_name_errors(tokens)
          )
          [name, tokens]
        end

        def attribute_name_errors(tokens)
          tokens.filter_map do |token|
            unexpected_character_in_attribute_name_error(token) if token.type == "TOKEN_QUOTE"
          end
        end

        def attribute_equals(equals, before, after)
          return node_token(equals) unless @options.track_whitespace && (before.any? || after.any?)

          tokens = before + [equals] + after
          Token.new(tokens.map(&:value).join, range_from(tokens.first, tokens.last),
                    location_from(tokens.first, tokens.last), equals.type)
        end

        def parse_attribute_value(name_tokens, equals)
          return missing_attribute_value(name_tokens, equals) if eof? || tag_closing? || whitespace? ||
                                                                 HTML_TAG_START_TYPES.include?(current.type)

          if current.type == "TOKEN_QUOTE"
            parse_quoted_attribute_value
          else
            parse_unquoted_attribute_value
          end
        end

        def missing_attribute_value(name_tokens, equals) # rubocop:disable Metrics/AbcSize
          name = name_tokens.map(&:value).join
          location = Location.new(equals.location.end, current.location.start)
          error_location = Location.new(equals.location.start, current.location.start)
          error = Errors::MissingAttributeValueError.new(
            "MISSING_ATTRIBUTE_VALUE_ERROR",
            error_location,
            "Attribute `#{name}` at #{equals.location.start.tree_inspect} is missing a value after the equals sign.",
            name
          )

          AST::HTMLAttributeValueNode.build(children: [], quoted: false, location: location, errors: [error])
        end

        def missing_attribute_whitespace_error(found)
          Errors::MissingWhitespaceBetweenAttributesError.new(
            "MISSING_WHITESPACE_BETWEEN_ATTRIBUTES_ERROR",
            found.location,
            "Missing whitespace between attributes at #{found.location.start.tree_inspect}. " \
            "`#{found.value}` is parsed as the start of a new attribute.",
            node_token(found)
          )
        end

        def unexpected_character_in_attribute_name_error(character)
          Errors::UnexpectedCharacterInAttributeNameError.new(
            "UNEXPECTED_CHARACTER_IN_ATTRIBUTE_NAME_ERROR",
            character.location,
            "Unexpected `#{character.value}` in attribute name at #{character.location.start.tree_inspect}.",
            node_token(character)
          )
        end

        def unexpected_equals_before_attribute_name_error(equals)
          Errors::UnexpectedEqualsSignBeforeAttributeNameError.new(
            "UNEXPECTED_EQUALS_SIGN_BEFORE_ATTRIBUTE_NAME_ERROR",
            equals.location,
            "Unexpected `=` before attribute name at #{equals.location.start.tree_inspect}.",
            node_token(equals)
          )
        end

        def unexpected_solidus_in_tag_error(solidus)
          Errors::UnexpectedSolidusInTagError.new(
            "UNEXPECTED_SOLIDUS_IN_TAG_ERROR",
            solidus.location,
            "Unexpected `/` in tag at #{solidus.location.start.tree_inspect}.",
            node_token(solidus)
          )
        end

        def parse_attribute_control(context:)
          opening, content, closing = consume_erb_tag

          case attribute_control_kind(content)
          when "if"
            parse_attribute_if(opening, content, closing, root: true, context: context)
          when "unless"
            parse_attribute_unless(opening, content, closing, context: context)
          when "case"
            parse_attribute_case(opening, content, closing, context: context)
          when "begin"
            parse_attribute_begin(opening, content, closing, context: context)
          when "while"
            parse_attribute_simple_block(AST::ERBWhileNode, opening, content, closing, context: context)
          when "until"
            parse_attribute_simple_block(AST::ERBUntilNode, opening, content, closing, context: context)
          when "for"
            parse_attribute_simple_block(AST::ERBForNode, opening, content, closing, context: context)
          when "do", "brace"
            parse_attribute_do_block(opening, content, closing, context: context)
          end
        end

        def parse_attribute_if(opening, content, closing, root:, context:) # rubocop:disable Metrics/PerceivedComplexity
          statements = parse_conditional_attributes(context)
          subsequent = parse_attribute_subsequent(context)
          finish = statements.last || closing
          end_node = parse_attribute_end if root
          errors = erb_tag_errors(opening, content, closing)
          errors.concat(missing_control_end_errors(opening, closing || content, "if")) if root && !end_node

          AST::ERBIfNode.build(
            tag_opening: node_token(opening),
            content: node_token(content),
            tag_closing: closing && node_token(closing),
            then_keyword: then_keyword_location(content, root ? "if" : "elsif"),
            statements: statements,
            subsequent: subsequent,
            end_node: end_node,
            location: location_from(opening, end_node || finish),
            errors: errors
          )
        end

        def parse_attribute_unless(opening, content, closing, context:) # rubocop:disable Metrics/AbcSize
          statements = parse_conditional_attributes(context)
          else_clause = parse_attribute_else(context: context) if erb_keyword == "else"
          end_node = parse_attribute_end
          finish = else_clause || statements.last || closing

          AST::ERBUnlessNode.build(
            tag_opening: node_token(opening),
            content: node_token(content),
            tag_closing: closing && node_token(closing),
            then_keyword: then_keyword_location(content, "unless"),
            statements: statements,
            else_clause: else_clause,
            end_node: end_node,
            location: location_from(opening, end_node || finish),
            errors: erb_tag_errors(opening, content, closing).tap do |errors|
              errors.concat(missing_control_end_errors(opening, closing || content, "unless")) unless end_node
            end
          )
        end

        def parse_attribute_subsequent(context)
          case erb_keyword
          when "elsif"
            opening, content, closing = consume_erb_tag
            parse_attribute_if(opening, content, closing, root: false, context: context)
          when "else"
            parse_attribute_else(context: context)
          end
        end

        def parse_attribute_else(context:, boundaries: CONDITIONAL_BOUNDARIES, include_statements_in_location: true)
          opening, content, closing = consume_erb_tag
          statements = parse_attribute_statements(boundaries, context)
          finish = include_statements_in_location ? statements.last || closing : closing

          AST::ERBElseNode.build(
            tag_opening: node_token(opening),
            content: node_token(content),
            tag_closing: closing && node_token(closing),
            statements: statements,
            location: location_from(opening, finish),
            errors: erb_tag_errors(opening, content, closing)
          )
        end

        def parse_conditional_attributes(context)
          parse_attribute_statements(CONDITIONAL_BOUNDARIES, context)
        end

        def parse_attribute_statements(boundaries, context) # rubocop:disable Metrics/AbcSize, Metrics/PerceivedComplexity
          return parse_children(nil, boundaries: boundaries) if context == :body
          return parse_cdata_children(boundaries: boundaries) if context == :cdata
          return parse_xml_processing_instruction_children(boundaries: boundaries) if context == :xml_processing_instruction
          return parse_escapable_text_children(@escapable_text_closing_name, boundaries: boundaries) if context == :escapable_text
          return attribute_value_children(boundaries: boundaries) if context == :attribute_value
          return parse_comment_children(boundaries: boundaries) if context == :comment

          statements = []

          until eof? || tag_closing? || boundaries.include?(erb_keyword)
            if whitespace?
              whitespace = advance
              statements << whitespace_node(whitespace) if @options.track_whitespace
            elsif attribute_control_erb?
              statements << parse_attribute_control(context: :attribute)
            elsif tag_closing?
              unsupported!("an unterminated attribute control block")
            else
              statements << parse_attribute
            end
          end

          statements
        end

        def parse_attribute_case(opening, content, closing, context:) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
          children = parse_attribute_statements(CASE_BOUNDARIES, context)
          case_tag = @case_condition_tags[content.range.from]
          branch_keyword = erb_keyword
          branch_keyword = nil unless ["when", "in"].include?(branch_keyword)
          branch_keyword ||= case_tag[:keyword] if case_tag&.fetch(:escaped, false)
          branch_class = branch_keyword == "in" ? AST::ERBInNode : AST::ERBWhenNode
          node_class = branch_keyword == "in" ? AST::ERBCaseMatchNode : AST::ERBCaseNode
          conditions = []

          if case_tag&.fetch(:escaped, false)
            branch_location = children.empty? ? closing.location : location_from(children.first, children.last)
            conditions << branch_class.build(statements: children, location: branch_location)
            children = []
          elsif branch_keyword
            conditions << parse_attribute_case_branch(branch_class, branch_keyword, context) while erb_keyword == branch_keyword
          end
          if erb_keyword == "else"
            else_clause = parse_attribute_else(context: context, boundaries: ["end"], include_statements_in_location: false)
          end
          end_node = parse_attribute_end
          finish = else_clause || conditions.last || children.last || closing

          node_class.build(
            tag_opening: node_token(opening),
            content: node_token(content),
            tag_closing: closing && node_token(closing),
            children: children,
            conditions: conditions,
            else_clause: else_clause,
            end_node: end_node,
            location: location_from(opening, end_node || (closing ? finish : content)),
            errors: erb_tag_errors(opening, content, closing).tap do |errors|
              errors.concat(case_condition_errors(content))
              errors.concat(missing_control_end_errors(opening, closing || content, "case")) unless end_node
            end
          )
        end

        def parse_attribute_case_branch(node_class, keyword, context)
          opening, content, closing = consume_erb_tag
          statements = parse_attribute_statements([keyword, "else", "end"], context)
          finish = opening.value.empty? ? statements.last || closing : closing

          node_class.build(
            tag_opening: node_token(opening),
            content: node_token(content),
            tag_closing: closing && node_token(closing),
            then_keyword: then_keyword_location(content, keyword),
            statements: statements,
            location: location_from(opening, finish),
            errors: erb_tag_errors(opening, content, closing)
          )
        end

        def parse_attribute_begin(opening, content, closing, context:) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength, Metrics/PerceivedComplexity
          statements, rescue_clause, else_clause, ensure_clause, end_node = within_rescue_scope do
            statements = parse_attribute_statements(BEGIN_BOUNDARIES, context)
            rescue_clause = parse_attribute_rescue(context) if erb_keyword == "rescue"
            if erb_keyword == "else"
              else_clause = parse_attribute_else(context: context, boundaries: ["ensure", "end"],
                                                 include_statements_in_location: false)
            end
            ensure_clause = parse_attribute_ensure(context) if erb_keyword == "ensure"
            [statements, rescue_clause, else_clause, ensure_clause, parse_attribute_end]
          end
          finish = ensure_clause || else_clause || rescue_clause || closing || content

          AST::ERBBeginNode.build(
            tag_opening: node_token(opening),
            content: node_token(content),
            tag_closing: closing && node_token(closing),
            statements: statements,
            rescue_clause: rescue_clause,
            else_clause: else_clause,
            ensure_clause: ensure_clause,
            end_node: end_node,
            location: location_from(opening, end_node || (closing ? finish : content)),
            errors: erb_tag_errors(opening, content, closing).tap do |errors|
              errors.concat(missing_control_end_errors(opening, closing || content, "begin")) unless end_node
            end
          )
        end

        def parse_attribute_rescue(context)
          opening, content, closing = consume_erb_tag
          statements = parse_attribute_statements(BEGIN_BOUNDARIES, context)
          subsequent = parse_attribute_rescue(context) if erb_keyword == "rescue"

          AST::ERBRescueNode.build(
            tag_opening: node_token(opening),
            content: node_token(content),
            tag_closing: closing && node_token(closing),
            statements: statements,
            subsequent: subsequent,
            location: location_from(opening, statements.last || closing),
            errors: erb_tag_errors(opening, content, closing)
          )
        end

        def parse_attribute_ensure(context)
          opening, content, closing = consume_erb_tag
          statements = parse_attribute_statements(["end"], context)

          AST::ERBEnsureNode.build(
            tag_opening: node_token(opening),
            content: node_token(content),
            tag_closing: closing && node_token(closing),
            statements: statements,
            location: location_from(opening, closing),
            errors: erb_tag_errors(opening, content, closing)
          )
        end

        def parse_attribute_simple_block(node_class, opening, content, closing, context:)
          statements, end_node = within_loop_scope do
            statements = parse_attribute_statements(["end"], context)
            [statements, parse_attribute_end]
          end
          keyword = attribute_control_kind(content)

          node_class.build(
            tag_opening: node_token(opening),
            content: node_token(content),
            tag_closing: closing && node_token(closing),
            statements: statements,
            end_node: end_node,
            location: location_from(opening, end_node || statements.last || closing),
            errors: erb_tag_errors(opening, content, closing).tap do |errors|
              errors.concat(missing_control_end_errors(opening, closing || content, keyword)) unless end_node
            end
          )
        end

        def parse_attribute_do_block(opening, content, closing, context:) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength, Metrics/PerceivedComplexity
          terminator = attribute_control_kind(content) == "brace" ? "}" : "end"
          boundaries = terminator == "}" ? [terminator, "end"] : BEGIN_BOUNDARIES
          body, rescue_clause, else_clause, ensure_clause, end_node = within_loop_scope do
            body = parse_attribute_statements(boundaries, context)
            rescue_clause, else_clause, ensure_clause = parse_block_clauses(context, terminator)
            end_node = parse_attribute_end(erb_keyword) if boundaries.include?(erb_keyword)
            [body, rescue_clause, else_clause, ensure_clause, end_node]
          end
          errors = erb_tag_errors(opening, content, closing)
          errors.concat(missing_block_end_errors(opening, closing || content, terminator)) unless end_node
          if PrismAdapter.multiple_unclosed_blocks?(content.value)
            errors.concat(unclosed_block_parse_errors(content))
          elsif content.value.match?(/\|[^|]*\|\s*\z/)
            errors.concat(block_parse_errors(content, terminator))
          end

          attributes = {
            tag_opening: node_token(opening),
            content: node_token(content),
            tag_closing: closing && node_token(closing),
            body: body,
            block_arguments: block_parameters(content),
            rescue_clause: rescue_clause,
            else_clause: else_clause,
            ensure_clause: ensure_clause,
            end_node: end_node,
            location: location_from(opening, end_node || current),
            errors: errors,
          }
          iteration = iteration_attributes(content, context, terminator)
          if @options.render_nodes && (render = build_render_block(content, attributes, terminator))
            return render
          end

          node_class = iteration ? AST::ERBIterationBlockNode : AST::ERBBlockNode
          node_class.build(**attributes, **(iteration || {}))
        end

        def missing_block_end_errors(opening, closing, _terminator)
          keyword = "ERB block"
          error = Errors::MissingERBEndTagError.new(
            "MISSING_ERB_END_TAG_ERROR",
            location_from(opening, closing),
            "#{keyword} started here but never closed with an end tag. The end tag may be in a different scope.",
            keyword
          )
          [error]
        end

        def missing_control_end_errors(opening, closing, keyword)
          label = "`<% #{keyword} %>`"
          error = Errors::MissingERBEndTagError.new(
            "MISSING_ERB_END_TAG_ERROR",
            location_from(opening, closing),
            "#{label} started here but never closed with an end tag. The end tag may be in a different scope.",
            label
          )
          [error]
        end

        def block_parse_errors(content, terminator)
          PrismAdapter.block_errors(content.value, terminator).map do |error|
            start_offset = content.range.from + error.location.start_offset
            end_offset = content.range.from + error.location.end_offset
            prism_parse_error(error, location: slice_location_from_offsets(start_offset, end_offset))
          end
        end

        def unclosed_block_parse_errors(content)
          PrismAdapter.unclosed_block_errors(content.value).map do |error|
            start_offset = content.range.from + error.location.start_offset
            end_offset = content.range.from + error.location.end_offset
            prism_parse_error(error, location: slice_location_from_offsets(start_offset, end_offset))
          end
        end

        def ruby_parse_error(location, diagnostic_id, message, level: "syntax")
          Errors::RubyParseError.new(
            "RUBY_PARSE_ERROR", location, "#{diagnostic_id}: #{message}", message, diagnostic_id, level
          )
        end

        def within_loop_scope
          @loop_depth += 1
          yield
        ensure
          @loop_depth -= 1
        end

        def within_rescue_scope
          @rescue_depth += 1
          yield
        ensure
          @rescue_depth -= 1
        end

        def parse_block_clauses(context, terminator)
          return [nil, nil, nil] unless terminator == "end"

          rescue_clause = parse_attribute_rescue(context) if erb_keyword == "rescue"
          if erb_keyword == "else"
            else_clause = parse_attribute_else(context: context, boundaries: ["ensure", "end"],
                                               include_statements_in_location: false)
          end
          ensure_clause = parse_attribute_ensure(context) if erb_keyword == "ensure"
          [rescue_clause, else_clause, ensure_clause]
        end

        def iteration_attributes(content, context, terminator) # rubocop:disable Metrics/AbcSize, Metrics/PerceivedComplexity
          return unless context == :body && @options.analyze && @options.iteration_nodes

          expression = iteration_expression(content.value, terminator)
          return unless expression

          operator = expression.call_operator_loc
          message = expression.message_loc
          return unless expression.receiver && operator && message && ITERATION_METHODS.include?(expression.name.to_s)

          operator_offset = operator.start_offset
          message_offset = message.start_offset
          opening_offset, opening = block_opening(content.value, terminator)
          receiver_offset = content.value[/\A\s*/].bytesize

          {
            receiver: token_slice(content, content.value.byteslice(receiver_offset...operator_offset), receiver_offset,
                                  type: "TOKEN_ERB_CONTENT"),
            call_operator: token_slice(content, operator.slice, operator_offset),
            message: token_slice(content, message.slice, message_offset),
            arguments: iteration_arguments(content, message.end_offset, opening_offset),
            block_opening: token_slice(content, opening, opening_offset),
          }
        end

        def iteration_expression(source, terminator)
          PrismAdapter.block_call(source, terminator)
        end

        def block_opening(source, terminator)
          pattern = if terminator == "}"
                      /(?<opening>\{)(?:\s*\|[^|]*\|)?\s*\z/
                    else
                      /(?<opening>\bdo)(?:\s*\|[^|]*\|)?(?:\s*#[^\r\n]*)?\s*\z/
                    end
          match = source.match(pattern)
          [match.pre_match.bytesize, match[:opening]]
        end

        def iteration_arguments(content, start_offset, end_offset)
          source = content.value.byteslice(start_offset...end_offset)
          leading = source[/\A\s*/].bytesize
          value = source.strip
          return [] if value.empty?

          if value.start_with?("(") && value.end_with?(")")
            value = value.byteslice(1...-1)
            start_offset += leading + 1
          else
            start_offset += leading
          end

          build_iteration_arguments(content, value, start_offset)
        end

        def build_iteration_arguments(content, source, base_offset)
          iteration_argument_ranges(source).filter_map do |start_offset, end_offset|
            argument = source.byteslice(start_offset...end_offset)
            leading = argument[/\A\s*/].bytesize
            value = argument.strip
            next if value.empty?

            offset = base_offset + start_offset + leading
            AST::RubyLiteralNode.build(content: value, location: slice_location(content, offset, value.bytesize))
          end
        end

        def iteration_argument_ranges(source)
          ranges = parameter_ranges(source)
          keyword_index = ranges.index { |range| keyword_argument?(source, range) }
          return ranges unless keyword_index && ranges.drop(keyword_index).all? { |range| keyword_argument?(source, range) }

          ranges.take(keyword_index) + [[ranges[keyword_index].first, ranges.last.last]]
        end

        def keyword_argument?(source, range)
          source.byteslice(range.first...range.last).strip.match?(/\A[A-Za-z_]\w*:/)
        end

        def block_parameters(content)
          terminator = attribute_control_kind(content) == "brace" ? "}" : "end"
          return [] unless iteration_expression(content.value, terminator)

          match = block_parameter_match(content.value)
          return [] unless match

          parameters_offset = match.pre_match.bytesize + match[0].index("|") + 1
          build_parameter_list(content, match[:parameters], parameters_offset, destructured: false)
        end

        def block_parameter_match(source)
          unless PrismAdapter.multiple_unclosed_blocks?(source)
            return source.match(/\|(?<parameters>[^|]*)\|(?:\s*#[^\r\n]*)?\s*\z/)
          end

          _kind, opening_offset = PrismAdapter.first_control_opener(source)
          source.match(/(?:\bdo|\{)\s*\|(?<parameters>[^|]*)\|/, opening_offset)
        end

        def build_parameter_list(content, source, base_offset, destructured:) # rubocop:disable Metrics/AbcSize
          parameter_ranges(source).flat_map do |start_offset, end_offset|
            parameter = source.byteslice(start_offset...end_offset)
            leading = parameter[/\A\s*/].bytesize
            value = parameter.strip
            next [] if value.empty?

            offset = base_offset + start_offset + leading
            if value.start_with?("(") && value.end_with?(")")
              build_parameter_list(content, value.byteslice(1...-1), offset + 1, destructured: true)
            else
              Array(build_block_parameter(content, value, offset, destructured: destructured))
            end
          end
        end

        def parameter_ranges(source) # rubocop:disable Metrics/AbcSize
          ranges = []
          start_offset = 0
          depth = 0

          PrismAdapter.tokens(source).each do |token|
            depth += 1 if PrismAdapter::OPENING_TOKENS.include?(token.type)
            depth -= 1 if PrismAdapter::CLOSING_TOKENS.include?(token.type)
            next unless token.type == :COMMA && depth.zero?

            comma_offset = token.location.start_offset
            ranges << [start_offset, comma_offset]
            start_offset = token.location.end_offset
          end

          ranges << [start_offset, source.bytesize]
        end

        def build_block_parameter(content, value, relative_offset, destructured: false)
          tokens = PrismAdapter.tokens(value)
          first = tokens.first
          return unless first

          kind, name_token, separator = block_parameter_parts(tokens)
          return unless kind

          name = build_parameter_name(content, relative_offset, name_token, separator)
          default_value = build_parameter_default(content, value, relative_offset, separator)
          required = ["positional", "keyword"].include?(kind) && default_value.nil?
          location = destructured && name ? name.location : slice_location(content, relative_offset, value.bytesize)

          AST::RubyParameterNode.build(
            name: name,
            default_value: default_value,
            kind: kind,
            required: required,
            location: location
          )
        end

        def block_parameter_parts(tokens) # rubocop:disable Metrics/AbcSize, Metrics/PerceivedComplexity
          first = tokens.first
          second = tokens[1]

          if [:USTAR, :USTAR_STAR, :UAMPERSAND].include?(first.type)
            kind = { "*" => +"rest", "**" => +"keyword_rest", "&" => +"block" }.fetch(first.value)
            return [kind, second, nil]
          end

          return [+"keyword", first, first] if first.type == :LABEL
          if first.type.to_s.start_with?("KEYWORD_") && second&.type == :COLON
            return [+"keyword", first, second]
          end
          return unless first.type == :IDENTIFIER
          return [+"positional", first, second] if second&.then { |token| token.type == :EQUAL }
          return [+"keyword", first, second] if second&.then { |token| [:COLON, :SYMBOL_BEGIN].include?(token.type) }

          [+"positional", first, nil]
        end

        def build_parameter_name(content, relative_offset, token, separator) # rubocop:disable Metrics/AbcSize, Metrics/PerceivedComplexity
          return unless token && ([:IDENTIFIER, :LABEL].include?(token.type) || token.type.to_s.start_with?("KEYWORD_"))

          token_offset = token.location.start_offset
          name = token.type == :LABEL ? token.value.delete_suffix(":") : token.value
          span = if token.type == :LABEL
                   token.value.bytesize
                 elsif separator&.then { |item| item.value == ":" }
                   separator.location.end_offset - token_offset
                 else
                   name.bytesize
                 end
          token_slice(content, name, relative_offset + token_offset, span: span)
        end

        def build_parameter_default(content, value, relative_offset, separator)
          return unless separator

          separator_offset = separator.location.end_offset
          remainder = value.byteslice(separator_offset..)
          leading = remainder[/\A\s*/].bytesize
          default = remainder.strip
          return if default.empty?

          offset = relative_offset + separator_offset + leading
          AST::RubyLiteralNode.build(content: default, location: slice_location(content, offset, default.bytesize))
        end

        def token_slice(token, value, relative_offset, span: value.bytesize, type: "TOKEN_IDENTIFIER")
          start_offset = token.range.from + relative_offset
          end_offset = start_offset + span
          location = Location.new(position_at(start_offset), position_at(end_offset))
          Token.new(value.dup, Range.zero, location, type)
        end

        def slice_location(token, relative_offset, length)
          start_offset = token.range.from + relative_offset
          Location.new(position_at(start_offset), position_at(start_offset + length))
        end

        def position_at(offset)
          line = 1
          column = 0
          @source.byteslice(0, offset).scan(/\r\n|\r|\n|[^\r\n]/).each do |character|
            case character
            when "\r\n", "\r", "\n"
              line += 1
              column = 0
            else
              column += 1
            end
          end
          Position.new(line, column)
        end

        def parse_attribute_end(keyword = "end")
          return unless erb_keyword == keyword

          opening, content, closing = consume_erb_tag
          AST::ERBEndNode.build(
            tag_opening: node_token(opening),
            content: node_token(content),
            tag_closing: node_token(closing),
            location: location_from(opening, closing),
            errors: malformed_erb_closing_errors(opening, closing)
          )
        end

        def consume_erb_tag
          opening = take("TOKEN_ERB_START")
          content = take("TOKEN_ERB_CONTENT")
          closing = take("TOKEN_ERB_END")
          recoverable_nested = !closing && current.type == "TOKEN_ERB_START"
          unsupported!("an unclosed ERB tag") unless opening && content && (closing || recoverable_nested)

          [opening, content, closing]
        end

        def attribute_control_erb?
          return false unless current.type == "TOKEN_ERB_START"
          return false if custom_erb_opening?(current)

          control_erb_has_boundary? && valid_attribute_control?(@tokens[@index + 1])
        end

        def body_control_erb?
          @options.analyze && current.type == "TOKEN_ERB_START" && current.value != "<%#" &&
            !custom_erb_opening?(current) &&
            control_erb_has_boundary? && valid_attribute_control?(@tokens[@index + 1])
        end

        def control_erb_has_boundary?
          ["TOKEN_ERB_END", "TOKEN_ERB_START"].include?(@tokens[@index + 2]&.type)
        end

        def structural_control_flow_erb?
          current.type == "TOKEN_ERB_START" &&
            !custom_erb_opening?(current) &&
            PrismAdapter::STRUCTURAL_CONTROL_FLOW_KEYWORDS.include?(erb_keyword)
        end

        def valid_attribute_control?(content)
          kind = attribute_control_kind(content)
          kind && PrismAdapter.valid_control_opener?(content.value, kind)
        end

        def attribute_control_kind(content)
          if PrismAdapter.multiple_unclosed_blocks?(content.value)
            kind, = PrismAdapter.first_control_opener(content.value)
            return kind
          end

          keyword = leading_ruby_word(content.value)
          return keyword if BLOCK_OPENERS.include?(keyword)
          return "do" if content.value.match?(/\bdo(?:\s*\|[^|]*\|)?(?:\s*#[^\r\n]*)?\s*\z/)
          return "case" if PrismAdapter.valid_control_opener?(content.value, "case")

          "brace" if content.value.match?(/\{(?:\s*\|[^|]*\|)?\s*\z/)
        end

        def erb_keyword
          return unless current.type == "TOKEN_ERB_START"
          return if custom_erb_opening?(current)

          content = @tokens[@index + 1]
          leading_ruby_word(content.value) if content
        end

        def leading_ruby_word(value)
          match = value.match(/\A\s*([A-Za-z_]\w*)/)
          match ? match[1] : value.strip.split.first
        end

        def parse_quoted_attribute_value
          opening = advance
          children = within_attribute_value(-> { quoted_attribute_end?(opening) }) { attribute_value_children }
          closing = take("TOKEN_QUOTE")
          finish = closing || children.last || opening
          errors = closing ? [] : [unclosed_quote_error(opening, finish)]

          AST::HTMLAttributeValueNode.build(
            open_quote: node_token(opening),
            children: children,
            close_quote: closing && node_token(closing),
            quoted: true,
            location: location_from(opening, finish),
            errors: errors
          )
        end

        def quoted_attribute_end?(opening)
          return true if current.type == "TOKEN_QUOTE" && current.value == opening.value

          if following_attribute_after_unclosed_quote?(opening)
            @recovered_attribute_separator = true
            return true
          end

          tag_closing? && !matching_quote_ahead?(opening)
        end

        def matching_quote_ahead?(opening)
          offset = 0

          until token_after(offset).nil? || token_after(offset).type == "TOKEN_EOF"
            token = token_after(offset)
            return true if token.type == "TOKEN_QUOTE" && token.value == opening.value

            offset += 1
          end

          false
        end

        def following_attribute_after_unclosed_quote?(opening) # rubocop:disable Metrics/AbcSize, Metrics/PerceivedComplexity
          return false unless @tokens[@index - 1]&.type&.match?(/WHITESPACE|NEWLINE/)

          offset = 0
          offset += 1 until attribute_name_ending?(token_after(offset))
          return false unless token_after(offset)&.type == "TOKEN_EQUALS"

          offset += 1
          offset += 1 while WHITESPACE_TOKEN_TYPES.include?(token_after(offset)&.type)
          token_after(offset)&.type == "TOKEN_QUOTE" && token_after(offset).value == opening.value
        end

        def attribute_name_ending?(token, initial: false)
          token.nil? || (token.type == "TOKEN_EQUALS" && !initial) || token.type == "TOKEN_SLASH" ||
            WHITESPACE_TOKEN_TYPES.include?(token.type) ||
            ["TOKEN_HTML_TAG_END", "TOKEN_HTML_TAG_SELF_CLOSE", "TOKEN_EOF"].include?(token.type)
        end

        def unclosed_quote_error(opening, finish)
          Errors::UnclosedQuoteError.new(
            "UNCLOSED_QUOTE_ERROR",
            location_from(opening, finish),
            "Attribute value opened with #{opening.value} at #{opening.location.start.tree_inspect} was never closed.",
            node_token(opening)
          )
        end

        def parse_unquoted_attribute_value
          start = current
          start_index = @index
          end_condition = lambda do
            whitespace? || tag_closing? || HTML_TAG_START_TYPES.include?(current.type)
          end
          children = within_attribute_value(end_condition) { attribute_value_children }
          finish = children.last || start
          errors = unquoted_attribute_value_errors(@tokens[start_index...@index])

          AST::HTMLAttributeValueNode.build(
            children: children,
            quoted: false,
            location: location_from(start, finish),
            errors: errors
          )
        end

        def unquoted_attribute_value_errors(tokens)
          tokens.filter_map do |token|
            if INVALID_UNQUOTED_ATTRIBUTE_TOKEN_TYPES.include?(token.type) ||
               INVALID_UNQUOTED_ATTRIBUTE_VALUES.include?(token.value)
              unexpected_character_in_unquoted_value_error(token)
            end
          end
        end

        def unexpected_character_in_unquoted_value_error(character)
          Errors::UnexpectedCharacterInUnquotedAttributeValueError.new(
            "UNEXPECTED_CHARACTER_IN_UNQUOTED_ATTRIBUTE_VALUE_ERROR",
            character.location,
            "Unexpected `#{character.value}` in unquoted attribute value at #{character.location.start.tree_inspect}.",
            node_token(character)
          )
        end

        def within_attribute_value(end_condition)
          previous_end_condition = @attribute_value_end_condition
          @attribute_value_end_condition = end_condition
          yield
        ensure
          @attribute_value_end_condition = previous_end_condition
        end

        def attribute_value_children(boundaries: []) # rubocop:disable Metrics/AbcSize, Metrics/PerceivedComplexity
          children = []
          literal_tokens = []

          until eof? || @attribute_value_end_condition.call || boundaries.include?(erb_keyword)
            if current.type == "TOKEN_ERB_START"
              children << literal_from(literal_tokens) if literal_tokens.any?
              literal_tokens = []
              children << if attribute_control_erb?
                            parse_attribute_control(context: :attribute_value)
                          else
                            parse_erb
                          end
            else
              literal_tokens << advance
            end
          end

          children << literal_from(literal_tokens) if literal_tokens.any?
          children
        end

        def literal_from(tokens)
          AST::LiteralNode.build(
            content: tokens.map(&:value).join,
            location: location_from(tokens.first, tokens.last)
          )
        end

        def whitespace_node(token)
          AST::WhitespaceNode.build(value: node_token(token), location: location_from(token, token))
        end

        def parse_close_tag # rubocop:disable Metrics/AbcSize, Metrics/MethodLength, Metrics/PerceivedComplexity
          opening = take("TOKEN_HTML_TAG_START_CLOSE")
          whitespace = []
          whitespace << advance while whitespace?
          name = parse_tag_name
          errors = []
          unless name
            name = advance
            errors << unexpected_close_tag_name_error(name)
          end

          whitespace << advance while whitespace?

          closing = if ["TOKEN_HTML_TAG_END", "TOKEN_HTML_TAG_SELF_CLOSE"].include?(current.type)
                      advance
                    end
          errors << end_tag_with_trailing_solidus_error(name, closing) if closing&.type == "TOKEN_HTML_TAG_SELF_CLOSE"
          errors << unclosed_close_tag_error(opening, name) unless closing
          casing_error = dot_notation_casing_error(name)
          errors << casing_error if casing_error

          AST::HTMLCloseTagNode.build(
            tag_opening: node_token(opening),
            tag_name: node_token(name),
            children: @options.track_whitespace ? whitespace.map { |token| whitespace_node(token) } : [],
            tag_closing: closing && node_token(closing),
            location: location_from(opening, closing || name),
            errors: errors
          )
        end

        def parse_orphan_close_tag # rubocop:disable Metrics/AbcSize
          opening = current
          source_name = source_tag_name_at(@index + 1)
          close_tag = parse_close_tag
          name_token = close_tag.tag_name
          closing = @tokens[@index - 1]
          return close_tag if name_token.type != "TOKEN_IDENTIFIER"

          if VOID_ELEMENTS.include?(name_token.value.downcase)
            close_tag.errors << void_element_closing_tag_error(opening, source_name, closing) unless svg_context?
          elsif close_tag.errors.empty?
            close_tag.errors << Errors::MissingOpeningTagError.new(
              "MISSING_OPENING_TAG_ERROR",
              Location.new(opening.location.start, closing.location.end),
              "Found closing tag `</#{name_token.value}>` at #{source_name.location.start.tree_inspect} without a " \
              "matching opening tag in the same scope.",
              source_name
            )
          end
          close_tag
        end

        def parse_erb # rubocop:disable Metrics/AbcSize, Metrics/MethodLength, Metrics/PerceivedComplexity
          opening = take("TOKEN_ERB_START")
          if @boolean_attribute_location_quirk
            content_start = current.location.start
            opening = Token.new(opening.value, opening.range, Location.new(content_start, content_start), opening.type)
            @boolean_attribute_location_quirk = false
          end
          comment = opening.value == "<%#"
          output = opening.value.start_with?("<%=") && opening.value != "<%%="

          content = take("TOKEN_ERB_CONTENT")
          closing = take("TOKEN_ERB_END")
          unsupported!("an unclosed ERB tag") unless content
          return build_nested_erb_content(opening, content) if !closing && current.type == "TOKEN_ERB_START"
          return build_unclosed_erb(opening, content, comment) unless closing

          closing_errors = malformed_erb_closing_errors(opening, closing)
          return build_erb_comment(opening, content, closing, errors: closing_errors) if comment

          if analyzable_erb?(opening) && PrismAdapter.yield_control?(content.value)
            return AST::ERBYieldNode.build(
              tag_opening: node_token(opening),
              content: node_token(content),
              tag_closing: node_token(closing),
              location: location_from(opening, closing),
              errors: closing_errors
            )
          end
          if output && @options.render_nodes && (render_node = build_render_node(opening, content, closing))
            render_node.errors.concat(closing_errors)
            return render_node
          end
          AST::ERBContentNode.build(
            tag_opening: node_token(opening),
            content: node_token(content),
            tag_closing: node_token(closing),
            parsed: analyzable_erb?(opening),
            valid: valid_erb_content?(opening, content),
            location: location_from(opening, closing),
            errors: closing_errors + control_flow_scope_errors(opening, content, closing)
          )
        end

        def malformed_erb_closing_errors(opening, closing)
          return [] if valid_erb_closing?(closing)

          opening_token = node_token(opening)
          closing_token = node_token(closing)
          location = location_from(opening, closing)
          message = "ERB tag `#{opening.value}` at #{opening.location.start.tree_inspect} is closed with " \
                    "`#{closing.value}` at #{closing.location.start.tree_inspect} instead of `%>`."
          [Errors::MalformedERBClosingTagError.new(
            "MALFORMED_ERB_CLOSING_TAG_ERROR", location, message, opening_token, closing_token
          )]
        end

        def valid_erb_closing?(closing)
          !closing || closing.value.empty? || Lexer::ERB_CLOSINGS.include?(closing.value)
        end

        def then_keyword_location(content, kind)
          offset, length = PrismAdapter.then_keyword_offsets(content.value, kind)
          slice_location(content, offset, length) if offset
        end

        def erb_tag_errors(opening, content, closing)
          errors = malformed_erb_closing_errors(opening, closing)
          errors.concat(multiple_blocks_errors(opening, content, closing))
          return errors if closing

          nested = @tokens.find do |token|
            token.type == "TOKEN_ERB_START" && token.range.from == content.range.to
          end
          errors << nested_erb_tag_error(opening, nested) if nested
          errors
        end

        def multiple_blocks_errors(opening, content, closing)
          return [] unless PrismAdapter.multiple_unclosed_blocks?(content.value)

          [Errors::ERBMultipleBlocksInTagError.new(
            "ERB_MULTIPLE_BLOCKS_IN_TAG_ERROR",
            location_from(opening, closing || content),
            "Multiple unclosed control flow blocks in a single ERB tag. Split each block into its own ERB tag, " \
            "or close all blocks within the same tag."
          )]
        end

        def case_condition_errors(content)
          tag = @case_condition_tags[content.range.from]
          return [] unless tag
          return [] unless tag[:inline] || @options.strict

          if tag[:inline]
            type = "ERB_CASE_INLINE_PATTERN_MATCH_ERROR"
            error_class = Errors::ERBCaseInlinePatternMatchError
            message = "A `case` statement and its first `in` pattern on the same line read as Ruby's one-line " \
                      "pattern match, not as a `case`/`in`. Put the `in` pattern on its own line, or in its own " \
                      "ERB tag (e.g., `<% case x %>` followed by `<% in y %>`)."
          else
            type = "ERB_CASE_WITH_CONDITIONS_ERROR"
            error_class = Errors::ERBCaseWithConditionsError
            message = "A `case` statement with `when`/`in` conditions in a single ERB tag cannot be reliably " \
                      "parsed, compiled, and formatted. Use separate ERB tags for `case` and its conditions " \
                      "(e.g., `<% case x %>` followed by `<% when y %>`), or set `strict: false` to allow this."
          end

          [error_class.new(type, tag[:location], message)]
        end

        def build_unclosed_erb(opening, content, comment)
          opening_token = node_token(opening)
          location = location_from(opening, content)
          error = Errors::UnclosedERBTagError.new(
            "UNCLOSED_ERB_TAG_ERROR",
            location,
            "ERB tag `#{opening.value}` at #{opening.location.start.tree_inspect} is missing closing `%>`.",
            opening_token
          )
          attributes = {
            tag_opening: opening_token,
            content: node_token(content),
            location: location,
            errors: [error],
          }
          return AST::ERBCommentNode.build(**attributes) if comment

          AST::ERBContentNode.build(
            **attributes,
            parsed: analyzable_erb?(opening),
            valid: valid_erb_content?(opening, content)
          )
        end

        def control_flow_scope_errors(opening, content, closing)
          return [] unless @options.analyze
          return [] if custom_erb_opening?(opening)

          keyword = PrismAdapter.invalid_control_flow_keyword(
            content.value, loop_depth: @loop_depth, rescue_depth: @rescue_depth
          )
          return [] unless keyword

          label = "`<% #{keyword} %>`"
          location = Location.new(opening.location.start, closing.location.end)
          message = "#{label} appears outside its control flow block. Keep ERB control flow statements together " \
                    "within the same HTML scope (tag, attribute, or content)."
          [Errors::ERBControlFlowScopeError.new("ERB_CONTROL_FLOW_SCOPE_ERROR", location, message, label)]
        end

        def build_nested_erb_content(opening, content)
          nested = current
          opening_token = node_token(opening)
          error = nested_erb_tag_error(opening, nested)
          AST::ERBContentNode.build(
            tag_opening: opening_token,
            content: node_token(content),
            parsed: analyzable_erb?(opening),
            valid: valid_erb_content?(opening, content),
            location: location_from(opening, content),
            errors: [error]
          )
        end

        def analyzable_erb?(opening)
          @options.analyze && !custom_erb_opening?(opening)
        end

        def valid_erb_content?(opening, content)
          @options.analyze && (custom_erb_opening?(opening) || PrismAdapter.valid?(content.value))
        end

        def custom_erb_opening?(opening)
          !opening.value.empty? && !DEFAULT_ERB_OPENINGS.include?(opening.value)
        end

        def nested_erb_tag_error(opening, nested)
          opening_token = node_token(opening)
          message = "ERB tag `#{opening.value}` at #{opening.location.start.tree_inspect} was terminated by " \
                    "nested `<%` tag at #{nested.location.start.tree_inspect}. Nesting `<%` tags is not supported."
          Errors::NestedERBTagError.new(
            "NESTED_ERB_TAG_ERROR",
            nested.location,
            message,
            opening_token,
            nested.location.start.line,
            nested.location.start.column
          )
        end

        def build_erb_comment(opening, content, closing, errors: [])
          if @options.strict_locals && strict_locals_comment?(content.value)
            return build_strict_locals_node(opening, content, closing, errors)
          end

          AST::ERBCommentNode.build(
            tag_opening: node_token(opening),
            content: node_token(content),
            tag_closing: node_token(closing),
            location: location_from(opening, closing),
            errors: errors
          )
        end

        def strict_locals_comment?(source)
          source.lstrip.start_with?("locals:")
        end

        def build_strict_locals_node(opening, content, closing, errors) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
          params_open = strict_locals_params_open(content.value)
          locals = []

          if params_open
            params_close = strict_locals_params_close(content.value, params_open)
            signature = content.value.byteslice(params_open..(params_close || -1))
            signature_errors = strict_locals_signature_errors(content, signature, params_open)
            errors += signature_errors
            if signature_errors.empty?
              parameters = params_close ? signature.byteslice(1...-1) : signature.byteslice(1..)
              locals = build_parameter_list(content, parameters, params_open + 1, destructured: false)
              add_strict_locals_parameter_errors(locals)
            end
          else
            errors << strict_locals_missing_parenthesis_error(content)
          end

          node = AST::ERBStrictLocalsNode.build(
            tag_opening: node_token(opening),
            content: node_token(content),
            tag_closing: node_token(closing),
            locals: locals,
            location: location_from(opening, closing),
            errors: errors
          )
          add_duplicate_strict_locals_error(node, opening, closing)
          @found_strict_locals = true
          node
        end

        def strict_locals_params_open(source)
          prefix = source.match(/\A\s*locals:/)&.then { |match| match[0].bytesize }
          return unless prefix

          whitespace = source.byteslice(prefix..)[/\A\s*/].bytesize
          offset = prefix + whitespace
          offset if source.getbyte(offset) == 40
        end

        def strict_locals_params_close(source, opening)
          depth = 0
          offset = opening

          while offset < source.bytesize
            depth += 1 if source.getbyte(offset) == 40
            if source.getbyte(offset) == 41
              depth -= 1
              return offset if depth.zero?
            end
            offset += 1
          end
          nil
        end

        def strict_locals_signature_errors(content, signature, params_open)
          PrismAdapter.parameter_signature_errors(signature).map do |error|
            start_offset = strict_locals_error_offset(content, params_open, error.location.start_offset)
            end_offset = strict_locals_error_offset(content, params_open, error.location.end_offset)
            prism_parse_error(error, location: unbounded_location_from_offsets(start_offset, end_offset))
          end
        end

        def strict_locals_error_offset(content, params_open, synthetic_offset)
          content.range.from + params_open + [synthetic_offset - 5, 0].max
        end

        def unbounded_location_from_offsets(start_offset, end_offset)
          Location.new(unbounded_position_at(start_offset), unbounded_position_at(end_offset))
        end

        def unbounded_position_at(offset)
          position = position_at([offset, @source.bytesize].min)
          overflow = [offset - @source.bytesize, 0].max
          Position.new(position.line, position.column + overflow)
        end

        def strict_locals_missing_parenthesis_error(content) # rubocop:disable Metrics/AbcSize
          prefix_end = content.value.match(/\A\s*locals:/)[0].bytesize
          whitespace = content.value.byteslice(prefix_end..)[/\A\s*/].bytesize
          rest_offset = prefix_end + whitespace
          rest = content.value.byteslice(rest_offset..).rstrip
          location = unbounded_location_from_offsets(
            content.range.from + rest_offset, content.range.from + rest_offset + rest.bytesize
          )
          Errors::StrictLocalsMissingParenthesisError.new(
            "STRICT_LOCALS_MISSING_PARENTHESIS_ERROR",
            location,
            "Strict locals declaration requires parentheses. Expected `locals: (...)` but got `locals: #{rest}`.",
            rest
          )
        end

        def add_strict_locals_parameter_errors(locals)
          locals.each do |local|
            error = strict_locals_parameter_error(local)
            local.errors << error if error
          end
        end

        def strict_locals_parameter_error(local)
          name = local.name&.value.to_s
          case local.kind
          when "positional"
            Errors::StrictLocalsPositionalArgumentError.new(
              "STRICT_LOCALS_POSITIONAL_ARGUMENT_ERROR", local.location,
              "Strict locals only support keyword arguments. Positional argument `#{name}` is not allowed. " \
              "Use keyword argument format: `#{name}:`.", name
            )
          when "rest"
            Errors::StrictLocalsSplatArgumentError.new(
              "STRICT_LOCALS_SPLAT_ARGUMENT_ERROR", local.location,
              "Strict locals only support keyword arguments. Splat argument `*#{name}` is not allowed.", name
            )
          when "block"
            Errors::StrictLocalsBlockArgumentError.new(
              "STRICT_LOCALS_BLOCK_ARGUMENT_ERROR", local.location,
              "Strict locals only support keyword arguments. Block argument `&#{name}` is not allowed.", name
            )
          end
        end

        def add_duplicate_strict_locals_error(node, opening, closing)
          return unless @found_strict_locals

          location = Location.new(opening.location.start, closing.location.end)
          node.errors << Errors::StrictLocalsDuplicateDeclarationError.new(
            "STRICT_LOCALS_DUPLICATE_DECLARATION_ERROR",
            location,
            "Duplicate strict locals declaration. Only the first `<%# locals: (...) %>` declaration is used by Rails."
          )
        end

        def build_render_node(opening, content, closing) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
          match = content.value.match(/\A(?<prefix>\s*(?:self\.)?render)(?<separator>\s*)(?<arguments>.*?)\s*\z/m)
          return unless match
          return if match[:separator].empty? && !match[:arguments].empty?

          argument_offset = match[:prefix].bytesize + match[:separator].bytesize
          arguments = source_arguments(match[:arguments], argument_offset)
          positional = arguments.first unless render_keyword(arguments.first)
          arguments.shift if positional
          attributes, locals = classify_render_arguments(content, positional, arguments)
          render_location = location_from(opening, closing)
          inline_block = inline_render_block(content, match[:arguments], argument_offset)

          keywords = AST::RubyRenderKeywordsNode.build(
            **attributes,
            locals: locals,
            location: render_location
          )
          AST::ERBRenderNode.build(
            tag_opening: node_token(opening),
            content: node_token(content),
            tag_closing: node_token(closing),
            keywords: keywords,
            body: inline_block ? inline_block[:body] : [],
            block_arguments: inline_block ? inline_block[:block_arguments] : [],
            location: render_location,
            errors: render_errors(render_location, positional, arguments, attributes, has_block: !inline_block.nil?)
          )
        end

        def build_render_block(content, block_attributes, terminator) # rubocop:disable Metrics/AbcSize
          opening_offset, = block_opening(content.value, terminator)
          call_source = content.value.byteslice(0...opening_offset).rstrip
          match = call_source.match(/\A(?<prefix>\s*(?:self\.)?render)(?<separator>\s*)(?<arguments>.*?)\s*\z/m)
          return unless match
          return if match[:separator].empty? && !match[:arguments].empty?

          argument_offset = match[:prefix].bytesize + match[:separator].bytesize
          arguments = source_arguments(match[:arguments], argument_offset)
          positional = arguments.first unless render_keyword(arguments.first)
          arguments.shift if positional
          attributes, locals = classify_render_arguments(content, positional, arguments)
          render_location = block_attributes[:location]
          keywords = AST::RubyRenderKeywordsNode.build(**attributes, locals: locals, location: render_location)

          AST::ERBRenderNode.build(
            **block_attributes,
            keywords: keywords,
            errors: render_errors(render_location, positional, arguments, attributes, has_block: true)
          )
        end

        def inline_render_block(content, arguments, argument_offset) # rubocop:disable Metrics/AbcSize
          return unless PrismAdapter.contains_block?(content.value)

          match = arguments.match(/\A.*\{\s*(?:\|(?<parameters>[^|]*)\|\s*)?(?<body>.*?)\}\s*\z/m)
          return unless match

          body_offset = argument_offset + match.begin(:body)
          body_leading = match[:body][/\A\s*/].bytesize
          body_source = match[:body].strip
          body = if body_source.empty?
                   []
                 else
                   [AST::RubyLiteralNode.build(
                     content: body_source,
                     location: slice_location(content, body_offset + body_leading, body_source.bytesize)
                   )]
                 end
          parameters = match[:parameters]
          parameter_offset = parameters ? argument_offset + match.begin(:parameters) : 0
          block_arguments = parameters ? build_parameter_list(content, parameters, parameter_offset, destructured: false) : []
          { body: body, block_arguments: block_arguments }
        end

        def classify_render_arguments(content, positional, arguments) # rubocop:disable Metrics/AbcSize, Metrics/PerceivedComplexity
          attributes = {}
          locals = []

          if positional
            field = string_argument(positional) ? :partial : :object
            attributes[field] = render_value_token(content, positional)
            arguments.each do |argument|
              keyword = render_keyword(argument)
              next if keyword&.first == "cached"

              if render_state_argument?(keyword)
                attributes.merge!(render_state(content, argument, keyword.last))
              elsif keyword&.first == "locals"
                locals.concat(render_locals(content, keyword.last))
              else
                locals << render_local(content, argument)
              end
            end
          else
            arguments.each { |argument| classify_render_keyword(content, argument, attributes, locals) }
          end

          [attributes, locals.compact]
        end

        def render_errors(location, positional, arguments, attributes, has_block: false) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
          keyword_pairs = arguments.filter_map { |argument| render_keyword(argument) }
          keyword_names = keyword_pairs.map(&:first)
          partial = attributes[:partial]&.value
          errors = []

          if !positional && arguments.empty?
            errors << Errors::RenderNoArgumentsError.new(
              "RENDER_NO_ARGUMENTS_ERROR", location,
              "No arguments passed to `render`. It needs a partial name, a keyword argument like `partial:`, " \
              "`template:`, or `layout:`, or a renderable object."
            )
          elsif positional && keyword_names.include?("locals")
            errors << Errors::RenderAmbiguousLocalsError.new(
              "RENDER_AMBIGUOUS_LOCALS_ERROR", location,
              "Did you mean `render partial: '#{partial}', locals: { ... }`? Using `render '#{partial}', " \
              "locals: { ... }` passes a local variable named `locals` to the partial instead of setting the " \
              "`locals:` option.", partial
            )
          elsif positional && (keyword_partial = keyword_pairs.assoc("partial"))
            keyword_value = normalized_render_value(keyword_partial.last)
            errors << Errors::RenderConflictingPartialError.new(
              "RENDER_CONFLICTING_PARTIAL_ERROR", location,
              "Both a positional partial `'#{partial}'` and a keyword `partial: '#{keyword_value}'` were passed " \
              "to `render`. Use one form or the other, not both.", partial, keyword_value
            )
          elsif partial && !positional && !keyword_names.include?("locals")
            missing = keyword_names - RENDER_KEYWORDS.keys - ["cached"]
            missing.delete("state") if attributes[:state_location]
            errors << missing_render_locals_error(location, partial, missing) if missing.any?
          end

          errors << invalid_as_error(location, attributes[:as_name]) if invalid_as_name?(attributes[:as_name])
          if attributes[:object] && attributes[:collection]
            errors << Errors::RenderObjectAndCollectionError.new(
              "RENDER_OBJECT_AND_COLLECTION_ERROR", location,
              "The `object:` and `collection:` options are mutually exclusive. Use one or the other in your `render` call."
            )
          end
          if attributes[:layout] && !attributes[:partial] && !attributes[:template_path] && !has_block
            errors << layout_without_block_error(location, attributes[:layout].value)
          end
          errors
        end

        def missing_render_locals_error(location, partial, missing)
          keywords = missing.join(", ")
          Errors::RenderMissingLocalsError.new(
            "RENDER_MISSING_LOCALS_ERROR", location,
            "Wrap `#{keywords}` in `locals: { ... }` when using `partial:`. Use `render partial: '#{partial}', " \
            "locals: { #{keywords} }` instead. Without `locals:`, these keyword arguments are ignored.",
            partial, keywords
          )
        end

        def invalid_as_name?(token)
          token && !token.value.match?(/\A[a-z_]\w*\z/)
        end

        def invalid_as_error(location, token)
          value = token.value
          Errors::RenderInvalidAsOptionError.new(
            "RENDER_INVALID_AS_OPTION_ERROR", location,
            "The `as:` value `'#{value}'` is not a valid Ruby identifier. Use a name that starts with a lowercase " \
            "letter or underscore, like `as: :item`.", value
          )
        end

        def layout_without_block_error(location, layout)
          Errors::RenderLayoutWithoutBlockError.new(
            "RENDER_LAYOUT_WITHOUT_BLOCK_ERROR", location,
            "Layout rendering needs a block. Use `render layout: '#{layout}' do ... end` so the layout has content to wrap.",
            layout
          )
        end

        def normalized_render_value(argument)
          string_argument(argument) || argument[:source].delete_prefix(":")
        end

        def classify_render_keyword(content, argument, attributes, locals)
          keyword, value = render_keyword(argument)
          return unless keyword
          return if keyword == "cached"

          if render_state_argument?([keyword, value])
            attributes.merge!(render_state(content, argument, value))
          elsif keyword == "locals"
            locals.concat(render_locals(content, value))
          elsif (field = RENDER_KEYWORDS[keyword])
            attributes[field] = render_value_token(content, value, symbol: field == :as_name)
          end
        end

        def render_state_argument?(keyword)
          @options.herb_directives && keyword&.first == "state" &&
            keyword.last[:source].start_with?("{") && keyword.last[:source].end_with?("}")
        end

        def render_state(content, argument, value)
          source = value[:source]
          inner = source.byteslice(1...-1)
          state = source_arguments(inner, value[:offset] + 1).filter_map do |declaration|
            render_state_declaration(content, declaration)
          end

          {
            state: state,
            state_location: slice_location(content, argument[:offset], argument[:source].bytesize),
          }
        end

        def render_state_declaration(content, declaration) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
          source = declaration[:source]
          if source.start_with?("**")
            name = token_slice(content, source, declaration[:offset], span: source.bytesize)
            return AST::HerbStateDeclarationNode.build(
              name: name, kind: +"missing", location: slice_location(content, declaration[:offset], source.bytesize)
            )
          end

          pair = source.match(/\A(?<prefix>(?<name>[A-Za-z_]\w*):\s*)(?<value>.*)\z/m)
          return render_missing_state_declaration(content, declaration) unless pair

          name = token_slice(content, pair[:name], declaration[:offset], span: pair[:name].bytesize + 1)
          value_source = pair[:value].empty? ? pair[:name] : pair[:value]
          value_offset = pair[:value].empty? ? declaration[:offset] : declaration[:offset] + pair[:prefix].bytesize
          default_value = AST::RubyLiteralNode.build(
            content: value_source, location: slice_location(content, value_offset, value_source.bytesize)
          )
          location_length = pair[:value].empty? ? pair[:name].bytesize : source.bytesize
          AST::HerbStateDeclarationNode.build(
            name: name,
            default_value: default_value,
            kind: render_state_kind(value_source),
            location: slice_location(content, declaration[:offset], location_length)
          )
        end

        def render_missing_state_declaration(content, declaration)
          source = declaration[:source]
          key = source.match(/\A(?<key>["'].*?["'])\s*=>/m)&.[](:key) || source
          AST::HerbStateDeclarationNode.build(
            name: token_slice(content, key, declaration[:offset], span: key.bytesize),
            kind: +"missing",
            location: slice_location(content, declaration[:offset], source.bytesize)
          )
        end

        def render_state_kind(source)
          case source
          when /\A(?:true|false)\z/ then +"boolean"
          when /\A-?\d+\z/ then +"integer"
          when /\A-?(?:\d+\.\d*|\d*\.\d+)\z/ then +"float"
          when "nil" then +"nil"
          when /\A:[A-Za-z_]\w*[!?=]?\z/ then +"symbol"
          when /\A(?:"[^"#]*"|'[^']*')\z/m then +"string"
          when /\A\[.*\]\z/m then +"array"
          when /\A\{.*\}\z/m then +"hash"
          when /\A[A-Za-z_]\w*\z/ then +"bare"
          else +"seeded"
          end
        end

        def render_keyword(argument)
          return unless argument

          match = argument[:source].match(/\A(?<prefix>(?<name>[A-Za-z_]\w*):\s*)(?<value>.*)\z/m)
          return unless match

          value_offset = argument[:offset] + match[:prefix].bytesize
          [match[:name], { source: match[:value], offset: value_offset }]
        end

        def render_value_token(content, argument, symbol: false)
          string = string_argument(argument)
          value = string || argument[:source]
          value = value.delete_prefix(":") if symbol
          token_slice(content, value, argument[:offset],
                      span: argument[:source].bytesize, type: "TOKEN_ERB_CONTENT")
        end

        def render_locals(content, argument)
          source = argument[:source]
          return [] unless source.start_with?("{") && source.end_with?("}")

          inner = source.byteslice(1...-1)
          source_arguments(inner, argument[:offset] + 1).filter_map { |local| render_local(content, local) }
        end

        def source_arguments(source, base_offset)
          parameter_ranges(source).filter_map do |start_offset, end_offset|
            argument = source.byteslice(start_offset...end_offset)
            leading = argument[/\A\s*/].bytesize
            value = argument.strip
            next if value.empty?

            { source: value, offset: base_offset + start_offset + leading }
          end
        end

        def string_argument_token(content, argument)
          value = string_argument(argument)
          return unless value

          token_slice(content, value, argument[:offset], span: argument[:source].bytesize)
        end

        def string_argument(argument)
          return unless argument

          match = argument[:source].match(/\A(?<quote>["'])(?<value>.*)\k<quote>\z/m)
          match && match[:value]
        end

        def render_local(content, argument) # rubocop:disable Metrics/AbcSize
          match = argument[:source].match(/\A(?<prefix>(?<name>[A-Za-z_]\w*):\s*)(?<value>.*)\z/m)
          return unless match

          name = token_slice(content, match[:name], argument[:offset], span: match[:name].bytesize + 1)
          value_source = match[:value].empty? ? match[:name] : match[:value]
          value_offset = match[:value].empty? ? argument[:offset] : argument[:offset] + match[:prefix].bytesize
          value = AST::RubyLiteralNode.build(
            content: value_source, location: slice_location(content, value_offset, value_source.bytesize)
          )
          AST::RubyRenderLocalNode.build(
            name: name,
            value: value,
            location: slice_location(
              content, argument[:offset], match[:value].empty? ? match[:name].bytesize : argument[:source].bytesize
            )
          )
        end

        def parse_text # rubocop:disable Metrics/AbcSize
          start = current
          content = +""
          finish = start

          until eof? || DOCUMENT_CHILD_START_TYPES.include?(current.type)
            add_stray_erb_closing_error if stray_erb_closing?
            finish = current
            content << advance.value
          end

          if content.empty?
            finish = advance
            content << finish.value
          end

          location = if @boolean_attribute_location_quirk && current.type == "TOKEN_ERB_START"
                       Location.new(current.location.end, finish.location.end)
                     else
                       location_from(start, finish)
                     end
          @boolean_attribute_location_quirk = false
          AST::HTMLTextNode.build(content: content, location: location)
        end

        def parse_literal_text
          tokens = consume_until { current.type == "TOKEN_ERB_START" }
          literal_from(tokens)
        end

        def stray_erb_closing?
          current.type == "TOKEN_PERCENT" && @tokens[@index + 1]&.type == "TOKEN_HTML_TAG_END"
        end

        def add_stray_erb_closing_error
          return unless @options.strict

          closing = @tokens[@index + 1]
          @document_errors << stray_erb_closing_error(current, closing)
        end

        def stray_erb_closing_error(opening, closing)
          Errors::StrayERBClosingTagError.new(
            "STRAY_ERB_CLOSING_TAG_ERROR",
            location_from(opening, closing),
            "Stray `%>` found at #{opening.location.start.tree_inspect}. This closing delimiter is not part of an " \
            "ERB tag and will be treated as plain text. If you want a literal `%>`, use the HTML entities " \
            "`&percnt;&gt;` instead."
          )
        end

        def matching_close_tag?(name)
          return false unless name && current.type == "TOKEN_HTML_TAG_START_CLOSE"

          tag_name_at(@index + 1)&.casecmp?(name)
        end

        def closing_tag_in_scope?(name)
          return false unless name && current.type == "TOKEN_HTML_TAG_START_CLOSE"

          closing_name = tag_name_at(@index + 1)
          closing_name && !html_void_element?(closing_name) &&
            @element_names.any? { |element_name| element_name.casecmp?(closing_name) }
        end

        def implicit_close_boundary?(open_name) # rubocop:disable Metrics/AbcSize, Metrics/PerceivedComplexity
          return false unless open_name

          open_name = open_name.downcase
          return false unless OPTIONAL_END_ELEMENTS.include?(open_name)
          return false if matching_element_close_tag_ahead?(open_name)

          next_name = tag_name_at(@index + 1)&.downcase
          return false unless next_name

          if current.type == "TOKEN_HTML_TAG_START"
            return next_name != "col" if open_name == "colgroup"

            OPTIONAL_END_TAG_OPEN_BOUNDARIES.fetch(open_name, []).include?(next_name)
          elsif current.type == "TOKEN_HTML_TAG_START_CLOSE"
            OPTIONAL_END_TAG_PARENT_BOUNDARIES.fetch(open_name, []).include?(next_name)
          else
            false
          end
        end

        def matching_element_close_tag_ahead?(name)
          name = name.downcase
          return false unless element_close_tag_names.include?(name)

          balances, suffix_minimums = element_tag_balance_data(name)
          suffix_minimums[@index + 1] < balances[@index]
        end

        def matched_opening_tag_indices # rubocop:disable Metrics/AbcSize, Metrics/PerceivedComplexity
          @matched_opening_tag_indices ||= begin
            openings = Hash.new { |hash, name| hash[name] = [] }
            matched = {}

            @tokens.each_with_index do |token, index|
              next unless HTML_TAG_START_TYPES.include?(token.type)

              name = tag_name_at(index + 1)&.downcase
              next unless name

              if token.type == "TOKEN_HTML_TAG_START"
                openings[name] << index
              elsif (opening_index = openings[name].pop)
                matched[opening_index] = true
              end
            end

            matched
          end
        end

        def element_close_tag_names
          @element_close_tag_names ||= @tokens.each_with_index.with_object({}) do |(token, index), names|
            next unless token.type == "TOKEN_HTML_TAG_START_CLOSE"

            name = tag_name_at(index + 1)
            names[name.downcase] = true if name
          end
        end

        def element_tag_balance_data(name) # rubocop:disable Metrics/AbcSize, Metrics/PerceivedComplexity
          @element_tag_balance_cache[name] ||= begin
            balances = Array.new(@tokens.length + 1, 0)
            @tokens.each_with_index do |token, index|
              balance = balances[index]
              tag_name = tag_name_at(index + 1)
              balance += 1 if token.type == "TOKEN_HTML_TAG_START" && tag_name&.casecmp?(name)
              balance -= 1 if token.type == "TOKEN_HTML_TAG_START_CLOSE" && tag_name&.casecmp?(name)
              balances[index + 1] = balance
            end

            minimum = balances.last
            suffix_minimums = balances.reverse_each.map { |balance| minimum = [minimum, balance].min }.reverse
            [balances, suffix_minimums]
          end
        end

        def implicit_ancestor_close_boundary?(current_name)
          return false unless current_name && current.type == "TOKEN_HTML_TAG_START"

          @element_names[0...-1].any? { |name| implicit_close_boundary?(name) }
        end

        def element_boundary?(name, children)
          if current.type == "TOKEN_HTML_TAG_START_CLOSE" && standalone_open_tag_balance(children, tag_name_at(@index + 1)).positive?
            return false
          end

          closing_tag_in_scope?(name) || implicit_close_boundary?(name) || implicit_ancestor_close_boundary?(name)
        end

        def standalone_open_tag_balance(nodes, name)
          return 0 unless name

          nodes.sum do |node|
            case node
            when AST::HTMLOpenTagNode
              node.tag_name.value.casecmp?(name) ? 1 : 0
            when AST::HTMLCloseTagNode
              node.tag_name.value.casecmp?(name) ? -1 : 0
            when AST::HTMLElementNode
              standalone_open_tag_balance(node.body, name)
            else
              standalone_open_tag_balance(node.compact_child_nodes, name)
            end
          end
        end

        def optional_end_boundary?(name, body, boundaries)
          OPTIONAL_END_ELEMENTS.include?(name.downcase) && body.any? &&
            (eof? || erb_boundary_closes_optional_tag?(name, boundaries) || closing_tag_in_scope?(name) ||
             implicit_close_boundary?(name) ||
             @element_names.any? { |ancestor| implicit_close_boundary?(ancestor) })
        end

        def erb_boundary_closes_optional_tag?(name, boundaries)
          boundaries.include?(erb_keyword) && !matching_close_after_control_boundary?(name) &&
            !matching_element_close_tag_ahead?(name)
        end

        def matching_close_after_control_boundary?(name)
          index = control_end_token_index
          return false unless index

          index += 1 until @tokens[index].type == "TOKEN_ERB_END"
          index += 1
          index += 1 while WHITESPACE_TOKEN_TYPES.include?(@tokens[index].type)
          @tokens[index].type == "TOKEN_HTML_TAG_START_CLOSE" && tag_name_at(index + 1)&.casecmp?(name)
        end

        def control_end_token_index # rubocop:disable Metrics/PerceivedComplexity
          depth = 0
          index = @index

          while index < @tokens.length
            if @tokens[index].type == "TOKEN_ERB_START"
              content = @tokens[index + 1]
              keyword = content && content.value.strip.split.first
              if content && attribute_control_kind(content)
                depth += 1
              elsif keyword == "end"
                return index if depth.zero?

                depth -= 1
              end
            end
            index += 1
          end

          nil
        end

        def unclosed_open_tag_error(name, finish)
          Errors::UnclosedOpenTagError.new(
            "UNCLOSED_OPEN_TAG_ERROR",
            Location.new(name.location.start, finish.location.end),
            "Opening tag `<#{name.value}>` at #{name.location.start.tree_inspect} is missing closing `>`.",
            node_token(name)
          )
        end

        def unclosed_close_tag_error(opening, name)
          Errors::UnclosedCloseTagError.new(
            "UNCLOSED_CLOSE_TAG_ERROR",
            Location.new(opening.location.start, name.location.end),
            "Closing tag `</#{name.value}>` at #{name.location.start.tree_inspect} is missing closing `>`.",
            name
          )
        end

        def unexpected_close_tag_name_error(found)
          Errors::UnexpectedTokenError.new(
            "UNEXPECTED_TOKEN_ERROR",
            found.location,
            "Found `#{found.value}` when expecting an identifier at #{found.location.start.tree_inspect}.",
            "TOKEN_IDENTIFIER",
            found
          )
        end

        def end_tag_with_trailing_solidus_error(name, closing)
          Errors::EndTagWithTrailingSolidusError.new(
            "END_TAG_WITH_TRAILING_SOLIDUS_ERROR",
            closing.location,
            "Closing tag `</#{name.value}>` at #{name.location.start.tree_inspect} ends with `/>` instead of `>`.",
            name
          )
        end

        def void_element_closing_tag_error(opening, name, closing)
          expected = "<#{name.value} />"
          found = "</#{name.value}>"
          Errors::VoidElementClosingTagError.new(
            "VOID_ELEMENT_CLOSING_TAG_ERROR",
            Location.new(opening.location.start, closing.location.end),
            "`#{name.value}` is a void element and should not be used as a closing tag. " \
            "Use `<#{name.value}>` or `#{expected}` instead of `#{found}`.",
            name,
            expected,
            found
          )
        end

        def missing_closing_tag_error(opening_location, name)
          Errors::MissingClosingTagError.new(
            "MISSING_CLOSING_TAG_ERROR",
            opening_location,
            "Opening tag `<#{name.value}>` at #{name.location.start.tree_inspect} doesn't have a matching " \
            "closing tag `</#{name.value}>` in the same scope.",
            name
          )
        end

        def whitespace?
          WHITESPACE_TOKEN_TYPES.include?(current.type)
        end

        def tag_closing?
          ["TOKEN_HTML_TAG_END", "TOKEN_HTML_TAG_SELF_CLOSE"].include?(current.type)
        end

        def following_whitespace
          offset = 0
          tokens = []

          while WHITESPACE_TOKEN_TYPES.include?(token_after(offset)&.type)
            tokens << token_after(offset)
            offset += 1
          end

          tokens
        end

        def token_after(offset)
          @tokens[@index + offset]
        end

        def consume_until
          tokens = []
          tokens << advance until eof? || yield
          tokens
        end

        def take(type)
          return unless current.type == type

          advance
        end

        def advance
          token = current
          @index += 1
          token
        end

        def current
          @tokens[@index]
        end

        def eof?
          current.type == "TOKEN_EOF"
        end

        def node_token(token)
          return if token.value.empty? && ["TOKEN_ERB_START", "TOKEN_ERB_END"].include?(token.type)

          token
        end

        def strip_node_positions(node)
          node.instance_variables.each do |name|
            value = node.instance_variable_get(name)
            if value.is_a?(Token)
              node.instance_variable_set(name, Token.new(value.value, nil, nil, value.type))
            elsif value.is_a?(Location)
              node.instance_variable_set(name, nil)
            end
          end

          node.compact_child_nodes.each { |child| strip_node_positions(child) }
        end

        def source_token(offset, length, type)
          Token.new(
            @source.byteslice(offset, length),
            Range.new(offset, offset + length),
            slice_location_from_offsets(offset, offset + length),
            type
          )
        end

        def document_location
          Location.new(Position.new(1, 0), current.location.end)
        end

        def start_deadline(options)
          timeout_ms = (@options.timeout * 1_000).to_i
          return unless options.key?(:timeout) && timeout_ms.positive?

          @deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @options.timeout
        end

        def past_deadline?
          @deadline && Process.clock_gettime(Process::CLOCK_MONOTONIC) >= @deadline
        end

        def add_timeout_error(document)
          timeout_ms = (@options.timeout * 1_000).to_i
          document.errors << Errors::TimeoutError.new(
            "TIMEOUT_ERROR",
            document.location,
            "Parsing timed out after #{timeout_ms} ms.",
            timeout_ms
          )
        end

        def apply_error_limit(document)
          limit = @options.max_errors
          return unless limit&.positive?

          remaining = limit
          queue = [document]

          until queue.empty?
            node = queue.shift
            if node.errors.length > remaining
              node.errors.slice!(remaining..)
              remaining = 0
            else
              remaining -= node.errors.length
            end
            queue.unshift(*node.compact_child_nodes)
          end
        end

        def location_from(first, last)
          Location.new(first.location.start, last.location.end)
        end

        def range_from(first, last)
          Range.new(first.range.from, last.range.to)
        end

        def unsupported!(syntax)
          raise NotImplementedError, "pure-Ruby parsing does not yet support #{syntax}"
        end
      end # rubocop:enable Metrics/ClassLength
    end
  end
end
