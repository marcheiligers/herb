# frozen_string_literal: true
# typed: true

module Herb
  module Backend
    module PureRuby
      module PrismAdapter # rubocop:disable Metrics/ModuleLength
        DocumentParse = Data.define(
          :result,     #: Prism::ParseResult
          :serialized, #: String?
          :node_serializer #: NodeSerializer?
        )

        class NodeSerializer
          attr_reader :result, :serialized

          def initialize(source)
            require "prism/serialize"

            @source = source
            @serialized = Prism.dump(source, partial_script: true)
            @result = Prism.load(source, @serialized)
            @ranges = {}.compare_by_identity
            load_ranges
          end

          def serialize_at(start_offset)
            range = @node_ranges.find { |candidate| candidate[:source_start] == start_offset }
            serialize_range(range)
          end

          def serialize_for(start_offset, end_offset)
            range = @node_ranges.find do |candidate|
              candidate[:source_start] >= start_offset && candidate[:source_start] < end_offset
            end
            serialize_range(range)
          end

          private

          def serialize_range(range)
            return unless range

            node = @serialized.byteslice(range[:serialized_start]...range[:serialized_end])
            serialized = @serialized.byteslice(0...@prefix_end).dup
            serialized[@pool_offset_position, 4] = [@prefix_end + node.bytesize].pack("L")
            serialized << node << @serialized.byteslice(@pool_start..)
          end

          def load_ranges # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
            serialize = Prism.const_get(:Serialize)
            loader = serialize.const_get(:Loader).new(Prism::Source.for(@source.dup), @serialized)
            ranges = @ranges
            loader.define_singleton_method(:load_node) do |constant_pool, encoding, freeze|
              serialized_start = io.pos
              node = super(constant_pool, encoding, freeze)
              range = {
                source_start: node.location.start_offset,
                source_end: node.location.end_offset,
                serialized_start: serialized_start,
                serialized_end: io.pos,
              }
              ranges[node] = range
              node
            end

            loader.load_header
            encoding = loader.load_encoding
            loader.load_varsint
            loader.load_line_offsets(false)
            loader.load_comments(false)
            loader.load_magic_comments(false)
            loader.load_optional_location_object(false)
            loader.load_errors(encoding, false)
            loader.load_warnings(encoding, false)
            @pool_offset_position = loader.io.pos
            @pool_start = loader.load_uint32
            pool_size = loader.load_varuint
            @prefix_end = loader.io.pos
            constant_pool = serialize.const_get(:ConstantPool).new(@source, @serialized, @pool_start, pool_size)
            root = loader.load_node(constant_pool, encoding, false)
            @node_ranges = []
            collect_prism_nodes(root)
          end

          def collect_statements(statements)
            statements&.body&.each do |node|
              @node_ranges << @ranges.fetch(node)
              collect_prism_nodes(node)
            end
          end

          # rubocop:disable Lint/DuplicateBranch, Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
          def collect_prism_nodes(node)
            case node
            when Prism::ProgramNode
              collect_statements(node.statements)
            when Prism::IfNode
              collect_statements(node.statements)
              collect_prism_nodes(node.subsequent) if node.subsequent
            when Prism::UnlessNode
              collect_statements(node.statements)
              collect_prism_nodes(node.else_clause) if node.else_clause
            when Prism::ElseNode, Prism::WhileNode, Prism::UntilNode, Prism::ForNode,
                 Prism::WhenNode, Prism::InNode, Prism::EnsureNode
              collect_statements(node.statements)
            when Prism::CaseNode, Prism::CaseMatchNode
              node.conditions.each { |condition| collect_prism_nodes(condition) }
              collect_prism_nodes(node.else_clause) if node.else_clause
            when Prism::BeginNode
              collect_statements(node.statements)
              collect_prism_nodes(node.rescue_clause) if node.rescue_clause
              collect_prism_nodes(node.else_clause) if node.else_clause
              collect_prism_nodes(node.ensure_clause) if node.ensure_clause
            when Prism::RescueNode
              collect_statements(node.statements)
              collect_prism_nodes(node.subsequent) if node.subsequent
            when Prism::CallNode
              collect_statements(node.block.body) if node.block.is_a?(Prism::BlockNode)
            when Prism::LambdaNode
              collect_statements(node.body)
            end
          end
          # rubocop:enable Lint/DuplicateBranch, Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
        end
        ConditionalBranch = Data.define(
          :source,             #: String?
          :start_offset,       #: Integer?
          :end_offset,         #: Integer?
          :static,             #: bool
          :static_output,      #: String?
          :static_start_offset, #: Integer?
          :static_end_offset,   #: Integer?
          :nested_conditional #: ConditionalExpression?
        )
        ConditionalExpression = Data.define(
          :kind,         #: Symbol
          :condition,    #: String
          :true_branch,  #: ConditionalBranch
          :false_branch  #: ConditionalBranch?
        )
        TagHelperValue = Data.define(
          :kind, :source, :value, :start_offset, :end_offset,
          :opening_start_offset, :opening_end_offset,
          :content_start_offset, :content_end_offset,
          :closing_start_offset, :closing_end_offset
        )
        TagHelperAttribute = Data.define(
          :name, :name_start_offset, :name_end_offset,
          :separator, :separator_type, :separator_start_offset, :separator_end_offset,
          :value, :splat_source, :splat_offset, :prefix
        )
        TagHelperCall = Data.define(
          :name, :name_start_offset, :name_end_offset, :receiver_start_offset,
          :arguments, :attributes, :attribute_hash, :block, :block_value
        )

        OPENING_TOKENS = [
          :PARENTHESIS_LEFT, :BRACKET_LEFT, :BRACKET_LEFT_ARRAY, :BRACE_LEFT, :LAMBDA_BEGIN, :EMBEXPR_BEGIN
        ].freeze
        CLOSING_TOKENS = [
          :PARENTHESIS_RIGHT, :BRACKET_RIGHT, :BRACE_RIGHT, :EMBEXPR_END
        ].freeze
        BLOCK_ERROR_EXCLUSIONS = [
          :block_term_end, :block_term_brace, :unexpected_token_close_context, :invalid_yield
        ].freeze
        UNCLOSED_BLOCK_ERRORS = [
          :begin_term, :block_term_brace, :block_term_end, :case_term, :conditional_term, :for_term, :until_term,
          :while_term
        ].freeze
        STRUCTURAL_CONTROL_FLOW_KEYWORDS = ["elsif", "else", "when", "in", "rescue", "ensure", "end"].freeze
        CONTROL_OPENING_TOKENS = {
          KEYWORD_BEGIN: "begin", KEYWORD_CASE: "case", KEYWORD_DO: "do", KEYWORD_FOR: "for", KEYWORD_IF: "if",
          KEYWORD_UNLESS: "unless", KEYWORD_UNTIL: "until", KEYWORD_WHILE: "while", BRACE_LEFT: "brace",
        }.freeze
        CASE_CONDITION_TOKENS = [:KEYWORD_WHEN, :KEYWORD_IN].freeze
        FRAGMENT_WRAPPERS = [
          ["", ""],
          ["", "\nend"],
          ["if __herb__\n", ""],
          ["if __herb__\n", "\nend"],
          ["begin\n", "\nend"],
          ["case __herb__\n", "\nend"]
        ].freeze

        module_function

        #: (String, ?serialize: bool) -> DocumentParse
        def parse_document(source, serialize: false)
          load_prism

          if serialize
            serializer = NodeSerializer.new(source)
            DocumentParse.new(result: serializer.result, serialized: serializer.serialized, node_serializer: serializer)
          else
            DocumentParse.new(result: Prism.parse(source, partial_script: true), serialized: nil, node_serializer: nil)
          end
        end

        #: (String) -> bool
        def valid?(source)
          load_prism
          Prism.parse_success?(source)
        end

        #: (String) -> bool
        def valid_fragment?(source)
          load_prism
          FRAGMENT_WRAPPERS.any? { |prefix, suffix| Prism.parse_success?("#{prefix}#{source}#{suffix}") }
        end

        #: (String, String) -> Prism::CallNode?
        def block_call(source, terminator)
          load_prism
          suffix = terminator == "}" ? "}" : "; end"
          result = Prism.parse("#{source}#{suffix}")
          statement = result.value.statements.body.first

          statement if statement.is_a?(Prism::CallNode) && statement.block.is_a?(Prism::BlockNode)
        end

        #: (String) -> bool
        def contains_block?(source)
          load_prism
          result = Prism.parse(source)
          result.success? && contains_node?(result.value, Prism::BlockNode)
        end

        #: (String) -> bool
        def yield_control?(source)
          load_prism
          result = Prism.parse(source)
          candidates = []
          collect_yield_control_candidates(result.value, candidates)
          candidates.min_by(&:last)&.first == :yield
        end

        #: (String) -> ConditionalExpression?
        def inline_conditional(source)
          load_prism
          result = Prism.parse(source)
          return unless result.success?
          return unless result.value.statements.body.one?

          statement = result.value.statements.body.first
          postfix_conditional(statement, source) || ternary_conditional(statement, source)
        end

        #: (String) -> Array[Prism::ParseError]
        def parameter_signature_errors(source)
          load_prism
          Prism.parse("def _#{source}; end").errors.reject { |error| error.type == :def_term }
        end

        #: (String) -> String
        def expression_kind(source) # rubocop:disable Metrics/AbcSize
          load_prism
          node = Prism.parse(source).value.statements.body.first

          case node
          when Prism::TrueNode, Prism::FalseNode then +"boolean"
          when Prism::IntegerNode then +"integer"
          when Prism::FloatNode then +"float"
          when Prism::StringNode then +"string"
          when Prism::SymbolNode then +"symbol"
          when Prism::NilNode then +"nil"
          when Prism::ArrayNode then +"array"
          when Prism::HashNode, Prism::KeywordHashNode then +"hash"
          when Prism::LocalVariableReadNode then +"bare"
          when Prism::CallNode
            node.receiver || node.arguments || node.block ? +"seeded" : +"bare"
          else +"seeded"
          end
        end

        #: (String, String, ?block: bool) -> TagHelperCall?
        def tag_helper_call(source, name, block: false)
          load_prism
          result = Prism.parse(block ? "#{source}; end" : source)
          call = top_level_call(result)
          normalize_tag_helper_call(call, source) if call&.name.to_s == name
        end

        #: (String, ?block: bool) -> TagHelperCall?
        def tag_builder_call(source, block: false)
          load_prism
          result = Prism.parse(block ? "#{source}; end" : source)
          call = top_level_call(result)
          receiver = call&.receiver
          return unless receiver.is_a?(Prism::CallNode) && receiver.name == :tag && !receiver.receiver

          normalize_tag_helper_call(call, source)
        end

        #: (String) -> Array[[Symbol, String]]
        def interpolated_string_parts(source) # rubocop:disable Metrics/AbcSize
          load_prism
          node = Prism.parse(source).value.statements.body.first
          return [] unless node.is_a?(Prism::InterpolatedStringNode)

          node.parts.filter_map do |part|
            case part
            when Prism::StringNode
              [:literal, part.unescaped] unless part.unescaped.empty?
            when Prism::EmbeddedStatementsNode
              statements = part.statements
              [:ruby, statements ? statements.location.slice : part.location.slice]
            end
          end
        end

        #: (String) -> bool
        def route_helper?(source)
          load_prism
          node = Prism.parse(source).value.statements.body.first
          return false unless node.is_a?(Prism::CallNode)

          name = node.name.to_s
          name.end_with?("_path", "_url")
        end

        #: (Prism::ParseResult, String, Integer) -> bool
        def local_variable_read_at?(result, name, offset)
          node = find_node_at_offset(result.value, Prism::LocalVariableReadNode, offset)
          node&.name.to_s == name
        end

        #: (String, String) -> Array[Prism::ParseError]
        def block_errors(source, terminator)
          load_prism
          suffix = terminator == "}" ? "}" : "; end"
          Prism.parse("#{source}#{suffix}").errors.reject do |error|
            BLOCK_ERROR_EXCLUSIONS.include?(error.type)
          end
        end

        #: (String) -> Array[Prism::ParseError]
        def unclosed_block_errors(source)
          parse_document(source).result.errors.reject do |error|
            BLOCK_ERROR_EXCLUSIONS.include?(error.type)
          end
        end

        #: (String, loop_depth: Integer, rescue_depth: Integer) -> String?
        def invalid_control_flow_keyword(source, loop_depth:, rescue_depth:)
          structural_control_flow_keyword(source) ||
            invalid_jump_control_flow_keyword(source, loop_depth: loop_depth, rescue_depth: rescue_depth)
        end

        #: (String) -> String?
        def structural_control_flow_keyword(source)
          keyword = source.strip.split.first
          keyword if STRUCTURAL_CONTROL_FLOW_KEYWORDS.include?(keyword)
        end

        #: (String, loop_depth: Integer, rescue_depth: Integer) -> String?
        def invalid_jump_control_flow_keyword(source, loop_depth:, rescue_depth:)
          load_prism

          messages = Prism.parse(source).errors.map(&:message)

          if loop_depth.zero?
            return "break" if messages.include?("Invalid break")
            return "next" if messages.include?("Invalid next")
            return "redo" if messages.include?("Invalid redo")
          end
          "retry" if rescue_depth.zero? && messages.include?("Invalid retry without rescue")
        end
        private_class_method :structural_control_flow_keyword, :invalid_jump_control_flow_keyword

        #: (String, String) -> bool
        def valid_control_opener?(source, kind) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
          load_prism
          result = Prism.parse(source)
          statement = result.value.statements.body.first

          case kind
          when "if" then statement.is_a?(Prism::IfNode) && missing_location?(statement.end_keyword_loc)
          when "unless" then statement.is_a?(Prism::UnlessNode) && missing_location?(statement.end_keyword_loc)
          when "case"
            case_node = find_node(statement, [Prism::CaseNode, Prism::CaseMatchNode])
            case_node && missing_location?(case_node.end_keyword_loc)
          when "begin" then statement.is_a?(Prism::BeginNode) && missing_location?(statement.end_keyword_loc)
          when "while" then statement.is_a?(Prism::WhileNode) && missing_location?(statement.closing_loc)
          when "until" then statement.is_a?(Prism::UntilNode) && missing_location?(statement.closing_loc)
          when "for" then statement.is_a?(Prism::ForNode) && missing_location?(statement.end_keyword_loc)
          when "do" then contains_unclosed_block?(result.value, "do")
          when "brace" then contains_unclosed_block?(result.value, "{")
          else false
          end
        end

        #: (String) -> bool
        def multiple_unclosed_blocks?(source)
          parse_document(source).result.errors.count { |error| UNCLOSED_BLOCK_ERRORS.include?(error.type) } > 1
        end

        #: (String) -> [String, Integer]?
        def first_control_opener(source)
          token = tokens(source).find { |candidate| CONTROL_OPENING_TOKENS.key?(candidate.type) }
          [CONTROL_OPENING_TOKENS.fetch(token.type), token.location.start_offset] if token
        end

        #: (String) -> [Integer, String, bool]?
        def case_condition_split(source)
          node = unclosed_case_node(source)
          return unless node

          keyword = first_case_condition_token(source, node)
          return unless keyword

          case_offset = node.case_keyword_loc.start_offset
          inline = keyword.type == :KEYWORD_IN && !source.byteslice(case_offset...keyword.location.start_offset).include?("\n")
          [keyword.location.start_offset, keyword.value, inline]
        end

        def unclosed_case_node(source)
          statement = parse_document(source).result.value.statements.body.first
          node = find_node(statement, [Prism::CaseNode, Prism::CaseMatchNode])
          node if node && missing_location?(node.end_keyword_loc)
        end
        private_class_method :unclosed_case_node

        def first_case_condition_token(source, node)
          tokens(source).find do |token|
            token.location.start_offset > node.case_keyword_loc.start_offset &&
              CASE_CONDITION_TOKENS.include?(token.type)
          end
        end
        private_class_method :first_case_condition_token

        #: (String, String) -> Integer?
        def continuation_end_offset(source, keyword)
          load_prism
          prefix, type = continuation_wrapper(keyword)
          return unless prefix

          statement = parse_document("#{prefix}#{source}").result.value.statements.body.first
          node = find_node(statement, type)
          location = node&.end_keyword_loc
          location.start_offset - prefix.bytesize if location && !missing_location?(location)
        end

        #: (String, String) -> [Integer, Integer]?
        def then_keyword_offsets(source, kind)
          load_prism
          wrapped, prefix_length, node_type = then_keyword_source(source, kind)
          return unless wrapped

          node = find_node(Prism.parse(wrapped).value, node_type)
          location = node.then_loc if node.is_a?(Prism::InNode)
          location ||= node.then_keyword_loc if node.respond_to?(:then_keyword_loc)
          return unless location

          [location.start_offset - prefix_length, location.length]
        end

        #: (String) -> Array[Prism::Token]
        def tokens(source)
          load_prism
          Prism.lex(source).value.filter_map do |token, _state|
            token unless token.type == :EOF
          end
        end

        #: (Prism::Node?, singleton(Prism::BlockNode)) -> bool
        def contains_node?(node, type)
          node.is_a?(type) || node&.child_nodes&.any? { |child| contains_node?(child, type) } || false
        end
        private_class_method :contains_node?

        def find_node(node, type)
          types = Array(type)
          return node if types.any? { |candidate| node.is_a?(candidate) }

          node&.child_nodes&.each do |child|
            found = find_node(child, types)
            return found if found
          end
          nil
        end
        private_class_method :find_node

        def find_node_at_offset(node, type, offset)
          return node if node.is_a?(type) && node.location.start_offset == offset

          node&.child_nodes&.each do |child|
            found = find_node_at_offset(child, type, offset)
            return found if found
          end
          nil
        end
        private_class_method :find_node_at_offset

        def top_level_call(result)
          statement = result.value.statements.body.first
          statement if statement.is_a?(Prism::CallNode)
        end
        private_class_method :top_level_call

        def normalize_tag_helper_call(call, source) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
          return unless call

          arguments = (call.arguments&.arguments || []).to_a
          attribute_hash = arguments.last if arguments.last.is_a?(Prism::KeywordHashNode) ||
                                             arguments.last.is_a?(Prism::HashNode)
          positional = attribute_hash ? arguments[0...-1] : arguments
          block_body = call.block&.body
          block_statement = block_body.body.first if block_body.is_a?(Prism::StatementsNode) && block_body.body.one?
          TagHelperCall.new(
            name: call.name.to_s,
            name_start_offset: call.message_loc.start_offset,
            name_end_offset: call.message_loc.end_offset,
            receiver_start_offset: call.receiver&.location&.start_offset,
            arguments: positional.map { |argument| tag_helper_value(argument, source) },
            attributes: attribute_hash ? tag_helper_attributes(attribute_hash.elements, source) : [],
            attribute_hash: attribute_hash && tag_helper_value(attribute_hash, source),
            block: !call.block.nil?,
            block_value: block_statement && tag_helper_value(block_statement, source)
          )
        end
        private_class_method :normalize_tag_helper_call

        def tag_helper_value(node, source) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
          opening, content, closing = tag_helper_delimiters(node)
          kind = case node
                 when Prism::StringNode then :string
                 when Prism::SymbolNode then :symbol
                 when Prism::TrueNode then :boolean_true
                 when Prism::FalseNode then :boolean_false
                 when Prism::NilNode then :nil
                 when Prism::IntegerNode then :integer
                 when Prism::ArrayNode
                   static = node.elements.all? { |element| element.is_a?(Prism::StringNode) || element.is_a?(Prism::SymbolNode) }
                   static ? :static_array : :array
                 when Prism::HashNode, Prism::KeywordHashNode then :hash
                 when Prism::InterpolatedStringNode then :interpolated_string
                 when Prism::ImplicitNode then :implicit
                 else :ruby
                 end
          value = if node.is_a?(Prism::StringNode) || node.is_a?(Prism::SymbolNode)
                    node.unescaped
                  elsif kind == :static_array
                    node.elements.map(&:unescaped).join(" ")
                  elsif kind == :implicit
                    source.byteslice(node.location.start_offset...node.location.end_offset).delete_suffix(":")
                  end
          TagHelperValue.new(
            kind: kind,
            source: source.byteslice(node.location.start_offset...node.location.end_offset),
            value: value,
            start_offset: node.location.start_offset,
            end_offset: node.location.end_offset,
            opening_start_offset: opening&.start_offset,
            opening_end_offset: opening&.end_offset,
            content_start_offset: (content || node.location).start_offset,
            content_end_offset: (content || node.location).end_offset,
            closing_start_offset: closing&.start_offset,
            closing_end_offset: closing&.end_offset
          )
        end
        private_class_method :tag_helper_value

        def tag_helper_delimiters(node)
          case node
          when Prism::StringNode
            [node.opening_loc, node.content_loc, node.closing_loc]
          when Prism::SymbolNode
            [node.opening_loc, node.value_loc, node.closing_loc]
          else
            [nil, nil, nil]
          end
        end
        private_class_method :tag_helper_delimiters

        def tag_helper_attributes(elements, source, prefix = nil)
          elements.flat_map do |element|
            if element.is_a?(Prism::AssocSplatNode)
              tag_helper_splat_attribute(element, source, prefix)
            elsif element.is_a?(Prism::AssocNode)
              tag_helper_assoc_attributes(element, source, prefix)
            else
              []
            end
          end
        end
        private_class_method :tag_helper_attributes

        def tag_helper_splat_attribute(element, source, prefix)
          return [] unless element.value

          [TagHelperAttribute.new(
            name: nil, name_start_offset: nil, name_end_offset: nil,
            separator: nil, separator_type: nil, separator_start_offset: nil, separator_end_offset: nil,
            value: nil,
            splat_source: source.byteslice(element.value.location.start_offset...element.value.location.end_offset),
            splat_offset: element.location.start_offset,
            prefix: prefix
          )]
        end
        private_class_method :tag_helper_splat_attribute

        def tag_helper_assoc_attributes(assoc, source, prefix) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength, Metrics/PerceivedComplexity
          key = tag_helper_key(assoc.key)
          return [] unless key && assoc.value

          if ["data", "aria"].include?(key[:name]) && assoc.value.is_a?(Prism::HashNode)
            return tag_helper_attributes(assoc.value.elements, source, key[:name])
          end

          value = if assoc.value.is_a?(Prism::ImplicitNode)
                    TagHelperValue.new(
                      kind: :implicit,
                      source: key[:name].dup,
                      value: key[:name].dup,
                      start_offset: key[:start_offset],
                      end_offset: key[:end_offset],
                      opening_start_offset: nil,
                      opening_end_offset: nil,
                      content_start_offset: key[:start_offset],
                      content_end_offset: key[:end_offset],
                      closing_start_offset: nil,
                      closing_end_offset: nil
                    )
                  else
                    tag_helper_value(assoc.value, source)
                  end
          separator = assoc.operator_loc ? " => " : ": "
          separator_type = assoc.operator_loc ? "TOKEN_EQUALS" : "TOKEN_COLON"
          separator_start = assoc.operator_loc ? assoc.key.location.end_offset : assoc.key.location.end_offset - 1
          name = [prefix, key[:name].tr("_", "-")].compact.join("-")
          [TagHelperAttribute.new(
            name: name,
            name_start_offset: key[:start_offset],
            name_end_offset: key[:end_offset],
            separator: separator,
            separator_type: separator_type,
            separator_start_offset: separator_start,
            separator_end_offset: assoc.value.location.start_offset,
            value: value,
            splat_source: nil,
            splat_offset: nil,
            prefix: prefix
          )]
        end
        private_class_method :tag_helper_assoc_attributes

        def tag_helper_key(node)
          case node
          when Prism::StringNode
            { name: node.unescaped, start_offset: node.content_loc.start_offset, end_offset: node.content_loc.end_offset }
          when Prism::SymbolNode
            { name: node.unescaped, start_offset: node.value_loc.start_offset, end_offset: node.value_loc.end_offset }
          end
        end
        private_class_method :tag_helper_key

        def postfix_conditional(node, source) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength, Metrics/PerceivedComplexity
          kind = case node
                 when Prism::IfNode
                   :if if node.if_keyword_loc && !node.end_keyword_loc
                 when Prism::UnlessNode
                   :unless if node.keyword_loc && !node.end_keyword_loc
                 end
          return unless kind

          nested = nested_ternary(node.statements)
          branch = if nested
                     ConditionalBranch.new(
                       source: nil,
                       start_offset: nil,
                       end_offset: nil,
                       static: false,
                       static_output: nil,
                       static_start_offset: nil,
                       static_end_offset: nil,
                       nested_conditional: ternary_conditional(nested, source)
                     )
                   else
                     conditional_branch(node.statements, source, postfix: true)
                   end
          return unless branch

          ConditionalExpression.new(
            kind: kind,
            condition: node.predicate.location.slice,
            true_branch: branch,
            false_branch: nil
          )
        end
        private_class_method :postfix_conditional

        def ternary_conditional(node, source)
          return unless node.is_a?(Prism::IfNode)
          return if node.if_keyword_loc || !node.subsequent

          true_branch = conditional_branch(node.statements, source)
          false_branch = conditional_branch(node.subsequent.statements, source)
          return unless true_branch && false_branch

          ConditionalExpression.new(
            kind: :if,
            condition: node.predicate.location.slice,
            true_branch: true_branch,
            false_branch: false_branch
          )
        end
        private_class_method :ternary_conditional

        def nested_ternary(statements) # rubocop:disable Metrics/AbcSize, Metrics/PerceivedComplexity
          return unless statements&.body&.one?

          node = statements.body.first
          if node.is_a?(Prism::ParenthesesNode) && node.body.is_a?(Prism::StatementsNode) && node.body.body.one?
            node = node.body.body.first
          end
          node if node.is_a?(Prism::IfNode) && !node.if_keyword_loc && node.subsequent
        end
        private_class_method :nested_ternary

        def conditional_branch(statements, source, postfix: false) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength, Metrics/PerceivedComplexity
          return unless statements&.body&.any?

          first = statements.body.first
          last = statements.body.last
          static_output = static_output(first, source) if statements.body.one?
          start_offset = first.location.start_offset
          end_offset = last.location.end_offset
          start_offset -= 1 if start_offset.positive? && source.getbyte(start_offset - 1) == 32
          end_offset += 1 if end_offset < source.bytesize && source.getbyte(end_offset) == 32

          if postfix
            value = source.byteslice(0...end_offset)
            start_offset = 0
          else
            value = source.byteslice(start_offset...end_offset)
            value = " #{value}" unless value.start_with?(" ")
            value = "#{value} " unless value.end_with?(" ")
          end

          ConditionalBranch.new(
            source: value,
            start_offset: start_offset,
            end_offset: end_offset,
            static: !static_output.nil?,
            static_output: static_output,
            static_start_offset: first.location.start_offset,
            static_end_offset: first.location.end_offset,
            nested_conditional: nil
          )
        end
        private_class_method :conditional_branch

        def static_output(node, source)
          output = case node
                   when Prism::StringNode, Prism::SymbolNode then node.unescaped
                   when Prism::IntegerNode
                     value = source.byteslice(node.location.start_offset...node.location.end_offset)
                     value if value.match?(/\A-?(?:0|[1-9]\d*)\z/)
                   when Prism::TrueNode then "true"
                   when Prism::FalseNode then "false"
                   when Prism::NilNode then ""
                   end
          output if output && !output.match?(/[&<>"']/)
        end
        private_class_method :static_output

        def then_keyword_source(source, kind)
          case kind
          when "if" then ["#{source}\nend", 0, Prism::IfNode]
          when "elsif" then ["#{source.sub(/\belsif\b/, "if   ")}\nend", 0, Prism::IfNode]
          when "unless" then ["#{source}\nend", 0, Prism::UnlessNode]
          when "when"
            prefix = "case __herb__\n"
            ["#{prefix}#{source}\nend", prefix.bytesize, Prism::WhenNode]
          when "in"
            prefix = "case __herb__\n"
            ["#{prefix}#{source}\nend", prefix.bytesize, Prism::InNode]
          end
        end
        private_class_method :then_keyword_source

        def continuation_wrapper(keyword)
          case keyword
          when "elsif", "else" then ["if __herb__\n", Prism::IfNode]
          when "when", "in" then ["case __herb__\n", [Prism::CaseNode, Prism::CaseMatchNode]]
          when "rescue", "ensure" then ["begin\n", Prism::BeginNode]
          end
        end
        private_class_method :continuation_wrapper

        #: (Prism::Node?, String) -> bool
        def contains_unclosed_block?(node, opening)
          return false unless node

          if [Prism::BlockNode, Prism::LambdaNode].any? { |type| node.is_a?(type) } &&
             node.opening_loc.slice == opening && missing_location?(node.closing_loc)
            return true
          end

          node.child_nodes.any? { |child| contains_unclosed_block?(child, opening) }
        end
        private_class_method :contains_unclosed_block?

        #: (Prism::Location?) -> bool
        def missing_location?(location)
          location.nil? || location.start_offset == location.end_offset
        end
        private_class_method :missing_location?

        #: (Prism::Node?, Array[[Symbol | String, Integer]]) -> void
        def collect_yield_control_candidates(node, candidates) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
          return unless node
          return if node.is_a?(Prism::DefNode)

          candidate = case node
                      when Prism::YieldNode then [:yield, node.location.start_offset]
                      when Prism::IfNode
                        ["if", node.if_keyword_loc.start_offset] if node.if_keyword_loc
                      when Prism::UnlessNode then ["unless", node.keyword_loc.start_offset]
                      when Prism::CaseNode, Prism::CaseMatchNode then ["case", node.case_keyword_loc.start_offset]
                      when Prism::WhileNode then ["while", node.keyword_loc.start_offset]
                      when Prism::UntilNode then ["until", node.keyword_loc.start_offset]
                      when Prism::ForNode then ["for", node.for_keyword_loc.start_offset]
                      when Prism::BeginNode
                        ["begin", (node.begin_keyword_loc || node.location).start_offset]
                      when Prism::BreakNode, Prism::NextNode, Prism::ReturnNode
                        [:flow, node.location.start_offset]
                      end
          candidates << candidate if candidate
          node.child_nodes.each { |child| collect_yield_control_candidates(child, candidates) }
        end
        private_class_method :collect_yield_control_candidates

        #: () -> void
        def load_prism
          require "prism"
        end
        private_class_method :load_prism
      end
    end
  end
end
