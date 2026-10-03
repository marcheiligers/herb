# frozen_string_literal: true
# typed: true

module Herb
  module Backend
    module PureRuby
      # This is a direct port of the native tree reconciliation algorithm.
      # rubocop:disable Metrics/AbcSize, Metrics/ClassLength, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/ParameterLists, Metrics/PerceivedComplexity
      class TreeDiff
        LCS_MAX_SIZE = 256
        METADATA_KEYS = [:location, :errors, :prism_context, :prism_node, :analyzed_ruby, :then_keyword, :state_location].freeze
        WHITESPACE_PRESERVING_TAGS = ["iframe", "listing", "noembed", "noframes", "plaintext", "pre", "script", "style", "textarea", "xmp"].freeze

        CHILDREN_FIELDS = {
          "AST_DOCUMENT_NODE" => :children,
          "AST_HTML_OPEN_TAG_NODE" => :children,
          "AST_HTML_CLOSE_TAG_NODE" => :children,
          "AST_HTML_ELEMENT_NODE" => :body,
          "AST_HTML_CONDITIONAL_ELEMENT_NODE" => :body,
          "AST_HTML_ATTRIBUTE_VALUE_NODE" => :children,
          "AST_HTML_ATTRIBUTE_NAME_NODE" => :children,
          "AST_ERB_OPEN_TAG_NODE" => :children,
          "AST_HTML_COMMENT_NODE" => :children,
          "AST_HTML_DOCTYPE_NODE" => :children,
          "AST_XML_DECLARATION_NODE" => :children,
          "AST_XML_PROCESSING_INSTRUCTION_NODE" => :children,
          "AST_CDATA_NODE" => :children,
          "AST_ERB_ELSE_NODE" => :statements,
          "AST_ERB_IF_NODE" => :statements,
          "AST_ERB_BLOCK_NODE" => :body,
          "AST_ERB_ITERATION_BLOCK_NODE" => :body,
          "AST_ERB_WHEN_NODE" => :statements,
          "AST_ERB_CASE_NODE" => :children,
          "AST_ERB_CASE_MATCH_NODE" => :children,
          "AST_ERB_WHILE_NODE" => :statements,
          "AST_ERB_UNTIL_NODE" => :statements,
          "AST_ERB_FOR_NODE" => :statements,
          "AST_ERB_RESCUE_NODE" => :statements,
          "AST_ERB_ENSURE_NODE" => :statements,
          "AST_ERB_BEGIN_NODE" => :statements,
          "AST_ERB_UNLESS_NODE" => :statements,
          "AST_ERB_RENDER_NODE" => :body,
          "AST_ERB_IN_NODE" => :statements,
        }.freeze

        ERB_CONTENT_TYPES = [
          "AST_ERB_OPEN_TAG_NODE", "AST_ERB_CONTENT_NODE", "AST_ERB_END_NODE", "AST_ERB_ELSE_NODE",
          "AST_ERB_IF_NODE", "AST_ERB_BLOCK_NODE", "AST_ERB_ITERATION_BLOCK_NODE", "AST_ERB_WHEN_NODE",
          "AST_ERB_CASE_NODE", "AST_ERB_CASE_MATCH_NODE", "AST_ERB_WHILE_NODE", "AST_ERB_UNTIL_NODE",
          "AST_ERB_FOR_NODE", "AST_ERB_RESCUE_NODE", "AST_ERB_ENSURE_NODE", "AST_ERB_BEGIN_NODE",
          "AST_ERB_UNLESS_NODE", "AST_ERB_RENDER_NODE", "AST_ERB_STRICT_LOCALS_NODE", "AST_ERB_YIELD_NODE",
          "AST_ERB_IN_NODE", "AST_HERB_DIRECTIVE_NODE", "AST_HERB_STATE_DIRECTIVE_NODE", "AST_ERB_COMMENT_NODE"
        ].freeze

        #: (String, String, **untyped) -> void
        def initialize(old_source, new_source, **options)
          validate_source(old_source)
          validate_source(new_source)

          @old_root = PureRuby.parse(old_source).value
          @new_root = PureRuby.parse(new_source).value
          track_whitespace_changes = options["track_whitespace_changes"]
          track_whitespace_changes = options[:track_whitespace_changes] if track_whitespace_changes.nil?
          @track_whitespace_changes = !track_whitespace_changes.nil? && track_whitespace_changes != false
          @signatures = {}.compare_by_identity #: Hash[Herb::AST::Node, untyped]
          @operations = [] #: Array[Herb::Diff::Operation]
        end

        #: () -> Herb::Diff::Result
        def result
          return Herb::Diff::Result.new(true, []) if same_tree?(@old_root, @new_root)

          diff_node(@old_root, @new_root, [], false)
          Herb::Diff::Result.new(@operations.empty?, @operations)
        end

        private

        def validate_source(source)
          return if source.is_a?(String)

          raise TypeError, "wrong argument type #{source.class} (expected String)"
        end

        def signature(value)
          case value
          when Herb::AST::Node
            @signatures[value] ||= normalize_hash(value.to_hash)
          when Herb::Token
            [value.type, value.value]
          when Array
            value.map { |item| signature(item) }
          when Hash
            normalize_hash(value)
          else
            value
          end
        end

        def normalize_hash(hash)
          hash.each_with_object([]) do |(key, value), normalized|
            next if METADATA_KEYS.include?(key)

            normalized << [key, signature(value)]
          end
        end

        def same_tree?(old_node, new_node)
          signature(old_node) == signature(new_node)
        end

        def token_value(node, field)
          node&.public_send(field)&.value
        end

        def element?(node)
          node && ["AST_HTML_ELEMENT_NODE", "AST_HTML_CONDITIONAL_ELEMENT_NODE"].include?(node.type)
        end

        def element_attributes(node)
          node&.open_tag.respond_to?(:children) ? node.open_tag.children : []
        end

        def node_identity(node)
          return signature(node) unless element?(node)

          [node.type, token_value(node, :tag_name)]
        end

        def move_identity(node)
          return signature(node) unless element?(node)

          attributes = element_attributes(node).map { |attribute| signature(attribute) }
          [node.type, token_value(node, :tag_name), attributes.sort_by(&:hash)]
        end

        def nodes_match?(old_node, new_node)
          return false unless old_node && new_node
          return true if same_tree?(old_node, new_node)
          return false unless old_node.type == new_node.type
          return true unless element?(old_node)
          return false unless node_identity(old_node) == node_identity(new_node)

          old_attributes = element_attributes(old_node)
          new_attributes = element_attributes(new_node)
          return true if old_attributes.empty? || new_attributes.empty?

          move_identity(old_node) == move_identity(new_node)
        end

        def emit(type, path, old_node, new_node, old_index = 0, new_index = 0)
          @operations << Herb::Diff::Operation.new(type, path, old_node, new_node, old_index, new_index)
        end

        def diff_node(old_node, new_node, path, preserve_whitespace)
          return if old_node.nil? && new_node.nil?
          return emit(:node_inserted, path, nil, new_node) unless old_node
          return emit(:node_removed, path, old_node, nil) unless new_node
          return if same_tree?(old_node, new_node)
          return emit(:node_replaced, path, old_node, new_node) unless old_node.type == new_node.type

          case old_node.type
          when "AST_DOCUMENT_NODE", "AST_HTML_ATTRIBUTE_VALUE_NODE", "AST_HTML_ATTRIBUTE_NAME_NODE", "AST_HTML_COMMENT_NODE"
            diff_children(old_node.children, new_node.children, path, preserve_whitespace)
          when "AST_LITERAL_NODE", "AST_RUBY_LITERAL_NODE"
            emit(:text_changed, path, old_node, new_node) unless old_node.content == new_node.content
          when "AST_HTML_OPEN_TAG_NODE"
            diff_attributes(old_node.children, new_node.children, path)
          when "AST_HTML_CONDITIONAL_OPEN_TAG_NODE"
            diff_node(old_node.conditional, new_node.conditional, path, preserve_whitespace)
          when "AST_HTML_CLOSE_TAG_NODE"
            emit(:text_changed, path, old_node, new_node) unless token_value(old_node, :tag_opening) == token_value(new_node, :tag_opening)
            diff_children(old_node.children, new_node.children, path, preserve_whitespace)
          when "AST_HTML_ELEMENT_NODE", "AST_HTML_CONDITIONAL_ELEMENT_NODE"
            diff_element(old_node, new_node, path, preserve_whitespace)
          when "AST_HTML_ATTRIBUTE_NODE"
            if signature(old_node.name) != signature(new_node.name)
              emit(:node_replaced, path, old_node, new_node)
            elsif signature(old_node.value) != signature(new_node.value)
              emit(:attribute_value_changed, path, old_node, new_node)
            end
          when "AST_RUBY_HTML_ATTRIBUTES_SPLAT_NODE"
            emit(:text_changed, path, old_node, new_node) unless old_node.content == new_node.content && old_node.prefix == new_node.prefix
          when "AST_HTML_TEXT_NODE"
            diff_text(old_node, new_node, path, preserve_whitespace)
          when "AST_HTML_DOCTYPE_NODE", "AST_XML_DECLARATION_NODE", "AST_XML_PROCESSING_INSTRUCTION_NODE", "AST_CDATA_NODE"
            diff_declaration(old_node, new_node, path, preserve_whitespace)
          when *ERB_CONTENT_TYPES
            diff_erb_node(old_node, new_node, path, preserve_whitespace)
          else
            emit(:node_replaced, path, old_node, new_node)
          end
        end

        def diff_element(old_node, new_node, path, preserve_whitespace)
          emit(:tag_name_changed, path, old_node, new_node) unless token_value(old_node, :tag_name) == token_value(new_node, :tag_name)

          old_open_tag = old_node.open_tag
          new_open_tag = new_node.open_tag
          if old_open_tag && new_open_tag && !same_tree?(old_open_tag, new_open_tag)
            diff_attributes(old_open_tag.children, new_open_tag.children, path)
          end

          preserve_body_whitespace = preserve_whitespace || whitespace_preserving?(old_node) || whitespace_preserving?(new_node)
          diff_children(old_node.body, new_node.body, path, preserve_body_whitespace)
        end

        def whitespace_preserving?(node)
          WHITESPACE_PRESERVING_TAGS.include?(token_value(node, :tag_name)&.downcase)
        end

        def diff_text(old_node, new_node, path, preserve_whitespace)
          old_content = old_node.content.to_s
          new_content = new_node.content.to_s
          return if old_content == new_content

          if preserve_whitespace || collapse_whitespace(old_content) != collapse_whitespace(new_content)
            emit(:text_changed, path, old_node, new_node)
          elsif @track_whitespace_changes
            emit(:whitespace_changed, path, old_node, new_node)
          end
        end

        def collapse_whitespace(content)
          content.gsub(/[ \t\n\r]+/, " ")
        end

        def diff_declaration(old_node, new_node, path, preserve_whitespace)
          emit(:text_changed, path, old_node, new_node) unless token_value(old_node, :tag_opening) == token_value(new_node, :tag_opening)
          diff_children(old_node.children, new_node.children, path, preserve_whitespace)
        end

        def diff_erb_node(old_node, new_node, path, preserve_whitespace)
          opening_changed = old_node.respond_to?(:tag_opening) && token_value(old_node, :tag_opening) != token_value(new_node, :tag_opening)
          content_changed = old_node.respond_to?(:content) && token_value(old_node, :content) != token_value(new_node, :content)
          emit(:erb_content_changed, path, old_node, new_node) if opening_changed || content_changed

          child_fields(old_node).each do |field|
            diff_children(old_node.public_send(field), new_node.public_send(field), path, preserve_whitespace)
          end

          node_fields(old_node).each do |field|
            diff_node(old_node.public_send(field), new_node.public_send(field), path, preserve_whitespace)
          end
        end

        def child_fields(node)
          fields = []
          fields << CHILDREN_FIELDS[node.type] if CHILDREN_FIELDS.key?(node.type)
          fields << :arguments if node.type == "AST_ERB_ITERATION_BLOCK_NODE"
          fields << :block_arguments if ["AST_ERB_BLOCK_NODE", "AST_ERB_ITERATION_BLOCK_NODE", "AST_ERB_RENDER_NODE"].include?(node.type)
          fields << :conditions if ["AST_ERB_CASE_NODE", "AST_ERB_CASE_MATCH_NODE"].include?(node.type)
          fields << :locals if node.type == "AST_ERB_STRICT_LOCALS_NODE"
          fields << :states if node.type == "AST_HERB_STATE_DIRECTIVE_NODE"
          fields.uniq
        end

        def node_fields(node)
          case node.type
          when "AST_ERB_IF_NODE" then [:subsequent, :end_node]
          when "AST_ERB_BLOCK_NODE", "AST_ERB_ITERATION_BLOCK_NODE", "AST_ERB_BEGIN_NODE", "AST_ERB_RENDER_NODE"
            [:rescue_clause, :else_clause, :ensure_clause, :end_node]
          when "AST_ERB_CASE_NODE", "AST_ERB_CASE_MATCH_NODE", "AST_ERB_UNLESS_NODE" then [:else_clause, :end_node]
          when "AST_ERB_WHILE_NODE", "AST_ERB_UNTIL_NODE", "AST_ERB_FOR_NODE" then [:end_node]
          when "AST_ERB_RESCUE_NODE" then [:subsequent]
          else []
          end
        end

        def diff_attributes(old_attributes, new_attributes, path)
          old_attributes ||= []
          new_attributes ||= []
          old_matched = Array.new(old_attributes.length, false)

          new_attributes.each_with_index do |new_attribute, new_index|
            old_index = matching_attribute_index(old_attributes, old_matched, new_attribute)
            unless old_index
              emit(:attribute_added, path + [new_index], nil, new_attribute, 0, new_index)
              next
            end

            old_matched[old_index] = true
            old_attribute = old_attributes[old_index]
            if new_attribute.type != "AST_HTML_ATTRIBUTE_NODE"
              diff_node(old_attribute, new_attribute, path + [new_index], false) unless same_tree?(old_attribute, new_attribute)
            elsif signature(old_attribute.value) != signature(new_attribute.value)
              emit(:attribute_value_changed, path + [new_index], old_attribute, new_attribute, old_index, new_index)
            end
          end

          old_attributes.each_with_index do |old_attribute, old_index|
            next if old_matched[old_index]

            emit(:attribute_removed, path + [old_index], old_attribute, nil, old_index, 0)
          end
        end

        def matching_attribute_index(old_attributes, old_matched, new_attribute)
          old_attributes.each_index.find do |index|
            next false if old_matched[index]

            old_attribute = old_attributes[index]
            next old_attribute.type == new_attribute.type unless new_attribute.type == "AST_HTML_ATTRIBUTE_NODE"

            old_attribute.type == new_attribute.type && signature(old_attribute.name) == signature(new_attribute.name)
          end
        end

        def diff_children(old_children, new_children, path, preserve_whitespace)
          old_children ||= []
          new_children ||= []
          return if old_children.empty? && new_children.empty?
          return diff_children_linear(old_children, new_children, path) if old_children.length > LCS_MAX_SIZE || new_children.length > LCS_MAX_SIZE

          table = lcs_table(old_children, new_children)
          edits = edit_script(old_children, new_children, table)
          match_moves_and_wrappers(edits, old_children, new_children)

          edits.reverse_each do |edit|
            type, old_index, new_index = edit
            old_child = old_children[old_index] if old_index
            new_child = new_children[new_index] if new_index
            child_path = path + [new_index || old_index]

            case type
            when :keep
              diff_node(old_child, new_child, child_path, preserve_whitespace)
            when :insert
              emit(:node_inserted, child_path, nil, new_child, 0, new_index)
            when :delete
              emit(:node_removed, child_path, old_child, nil, old_index, 0)
            when :move
              emit(:node_moved, child_path, old_child, new_child, old_index, new_index)
              diff_node(old_child, new_child, child_path, preserve_whitespace)
            when :coalesced_keep
              emit(:node_moved, child_path, old_child, new_child, old_index, new_index) unless old_index == new_index
              diff_node(old_child, new_child, child_path, preserve_whitespace)
            when :wrap
              emit(:node_wrapped, child_path, old_child, new_child, old_index, new_index)
            when :unwrap
              emit(:node_unwrapped, child_path, old_child, new_child, old_index, new_index)
            end
          end
        end

        def lcs_table(old_children, new_children)
          table = Array.new(old_children.length + 1) { Array.new(new_children.length + 1, 0) }
          old_children.each_index do |old_index|
            new_children.each_index do |new_index|
              table[old_index + 1][new_index + 1] = if nodes_match?(old_children[old_index], new_children[new_index])
                                                      table[old_index][new_index] + 1
                                                    else
                                                      [table[old_index][new_index + 1], table[old_index + 1][new_index]].max
                                                    end
            end
          end
          table
        end

        def edit_script(old_children, new_children, table)
          edits = []
          old_index = old_children.length
          new_index = new_children.length

          while old_index.positive? || new_index.positive?
            if old_index.positive? && new_index.positive? && nodes_match?(old_children[old_index - 1], new_children[new_index - 1])
              edits << [:keep, old_index - 1, new_index - 1]
              old_index -= 1
              new_index -= 1
            elsif new_index.positive? && (old_index.zero? || table[old_index][new_index - 1] >= table[old_index - 1][new_index])
              edits << [:insert, nil, new_index - 1]
              new_index -= 1
            else
              edits << [:delete, old_index - 1, nil]
              old_index -= 1
            end
          end
          edits
        end

        def match_moves_and_wrappers(edits, old_children, new_children)
          delete_positions = edits.each_index.select { |index| edits[index][0] == :delete }
          insert_positions = edits.each_index.select { |index| edits[index][0] == :insert }
          return if delete_positions.empty? || insert_positions.empty?

          delete_matched = Array.new(delete_positions.length, false)
          insert_matched = Array.new(insert_positions.length, false)

          match_edit_pairs(edits, delete_positions, insert_positions, delete_matched, insert_matched, old_children, new_children, :move, :move_identity)
          match_edit_pairs(edits, delete_positions, insert_positions, delete_matched, insert_matched, old_children, new_children, :coalesced_keep, :node_identity)

          delete_positions.each_with_index do |delete_position, delete_index|
            next if delete_matched[delete_index]

            old_child = old_children[edits[delete_position][1]]
            insert_positions.each_with_index do |insert_position, insert_index|
              next if insert_matched[insert_index]

              new_child = new_children[edits[insert_position][2]]
              type = if child_with_signature?(new_child, signature(old_child))
                       :wrap
                     elsif child_with_signature?(old_child, signature(new_child))
                       :unwrap
                     end
              next unless type

              consume_pair(edits, delete_position, insert_position, type)
              delete_matched[delete_index] = true
              insert_matched[insert_index] = true
              break
            end
          end
        end

        def match_edit_pairs(edits, delete_positions, insert_positions, delete_matched, insert_matched, old_children, new_children, type, identity_method)
          delete_positions.each_with_index do |delete_position, delete_index|
            next if delete_matched[delete_index]

            old_child = old_children[edits[delete_position][1]]
            insert_index = insert_positions.each_index.find do |candidate|
              next false if insert_matched[candidate]

              new_child = new_children[edits[insert_positions[candidate]][2]]
              send(identity_method, old_child) == send(identity_method, new_child)
            end
            next unless insert_index

            consume_pair(edits, delete_position, insert_positions[insert_index], type)
            delete_matched[delete_index] = true
            insert_matched[insert_index] = true
          end
        end

        def consume_pair(edits, delete_position, insert_position, type)
          edits[delete_position][0] = type
          edits[delete_position][2] = edits[insert_position][2]
          edits[insert_position][0] = :consumed
        end

        def child_with_signature?(node, target_signature)
          children = CHILDREN_FIELDS[node.type] && node.public_send(CHILDREN_FIELDS[node.type])
          children&.any? { |child| signature(child) == target_signature }
        end

        def diff_children_linear(old_children, new_children, path)
          prefix = 0
          prefix += 1 while prefix < old_children.length && prefix < new_children.length && same_tree?(old_children[prefix], new_children[prefix])
          suffix = 0
          suffix += 1 while suffix < old_children.length - prefix && suffix < new_children.length - prefix &&
                            same_tree?(old_children[-suffix - 1], new_children[-suffix - 1])

          (prefix...(old_children.length - suffix)).each do |index|
            emit(:node_removed, path + [index], old_children[index], nil, index, 0)
          end
          (prefix...(new_children.length - suffix)).each do |index|
            emit(:node_inserted, path + [index], nil, new_children[index], 0, index)
          end
        end
      end
      # rubocop:enable Metrics/AbcSize, Metrics/ClassLength, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/ParameterLists, Metrics/PerceivedComplexity
    end
  end
end
