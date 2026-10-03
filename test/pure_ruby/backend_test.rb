# frozen_string_literal: true

require_relative "../test_helper"

module PureRuby
  class BackendTest < Minitest::Spec
    test "diffs parsed trees without the native extension" do
      result = Herb::Backend::PureRuby.diff("<p>old</p>", "<p>new</p>")

      assert_equal [:text_changed], result.operations.map(&:type)
      assert_instance_of Herb::AST::HTMLTextNode, result.first.old_node
      assert_instance_of Herb::AST::HTMLTextNode, result.first.new_node
    end

    test "recovers stray ERB closing tags inside open tags" do
      result = Herb::Backend::PureRuby.parse('<div class="first" %> id="second"></div>', strict: true)
      open_tag = result.value.children.first.open_tag

      assert_equal 3, open_tag.children.length
      assert_equal "class", open_tag.children[0].name.children.first.content
      assert_equal "%>", open_tag.children[1].content
      assert_equal "id", open_tag.children[2].name.children.first.content
      assert_instance_of Herb::AST::LiteralNode, open_tag.children[1]
      assert_instance_of Herb::Errors::StrayERBClosingTagError, open_tag.errors.first
    end

    test "uses Prism for Ruby syntax analysis" do
      assert Herb::Backend::PureRuby::PrismAdapter.valid?("user.name")
      refute Herb::Backend::PureRuby::PrismAdapter.valid?("user.")

      call = Herb::Backend::PureRuby::PrismAdapter.block_call("items&.each do |item|", "end")
      assert_equal :each, call.name
      assert_equal "&.", call.call_operator_loc.slice
    end

    test "stores a whole-document Prism program with template-aligned offsets" do
      source = "<% if visible %><%= user.name %><% end %>"
      document = Herb::Backend::PureRuby.parse(source, prism_program: true).value
      program = document.deserialized_prism_node
      conditional = program.statements.body.first

      assert_instance_of Prism::ProgramNode, program
      assert_instance_of Prism::IfNode, conditional
      assert_equal source.byteindex("if visible"), conditional.location.start_offset
      assert_equal "user.name", conditional.statements.body.first.slice
    end

    test "stores a serialized Prism node on transformed renders" do
      source = '<%= render partial: "card", locals: { title: @title } %>'
      render = Herb::Backend::PureRuby.parse(source, render_nodes: true, prism_nodes: true).value.children.first
      prism_node = render.deserialized_prism_node

      assert_instance_of Prism::CallNode, prism_node
      assert_equal :render, prism_node.name
      assert_equal 'render partial: "card", locals: { title: @title }', prism_node.location.slice
    end

    test "reports whole-document Prism diagnostics" do
      result = Herb::Backend::PureRuby.parse("<%= ) %>")
      error = result.value.errors.first

      assert_instance_of Herb::Errors::RubyParseError, error
      assert_equal "unexpected_token_ignore", error.diagnostic_id
      assert_equal "unexpected ')', ignoring it", error.error_message
      assert_equal Herb::Location.from(1, 4, 1, 5).to_hash, error.location.to_hash
    end

    test "reparses an ERB fragment when an inserted semicolon causes a diagnostic" do
      result = Herb::Backend::PureRuby.parse("<%= user. %>")
      erb = result.value.children.first
      error = erb.errors.first

      assert_empty result.value.errors
      assert_instance_of Herb::Errors::RubyParseError, error
      assert_equal "expect_message", error.diagnostic_id
      assert_equal "unexpected end-of-input; expecting a message to send to the receiver", error.error_message
      assert_equal erb.location.to_hash, error.location.to_hash
    end

    test "matches native anonymous keyword forwarding diagnostics" do
      ordinary = Herb::Backend::PureRuby.parse("<%= forward(**) %>")
      strict = Herb::Backend::PureRuby.parse("<%= forward(**) %>", strict_locals: true)
      declared = Herb::Backend::PureRuby.parse(
        "<%# locals: (**) %><%= forward(**) %>", strict_locals: true
      )

      assert_empty ordinary.errors
      assert_equal ["argument_no_forwarding_star_star"], strict.errors.map(&:diagnostic_id)
      assert_empty declared.errors
    end

    test "reports strict locals signature and declaration errors" do
      source = "<%# locals: (item) %>\n<%# locals: (other:) %>"
      declarations = Herb::Backend::PureRuby.parse(source, strict_locals: true).value.children.grep(
        Herb::AST::ERBStrictLocalsNode
      )
      malformed = Herb::Backend::PureRuby.parse(
        "<%# locals: (item: %>", strict_locals: true
      ).value.children.first

      assert_instance_of Herb::Errors::StrictLocalsPositionalArgumentError,
                         declarations.first.locals.first.errors.first
      assert_instance_of Herb::Errors::StrictLocalsDuplicateDeclarationError, declarations.last.errors.first
      assert_equal "def_params_term_paren", malformed.errors.first.diagnostic_id
    end

    test "transforms generic and state Herb directives" do
      source = <<~HTML
        <%# herb:key item.id %>
        <%# herb:state (open: false) %>
        <%# herb:state (count: 0) %>
      HTML
      children = Herb::Backend::PureRuby.parse(source, herb_directives: true).value.children
      key, first_state, second_state = children.reject { |node| node.is_a?(Herb::AST::HTMLTextNode) }

      assert_instance_of Herb::AST::HerbDirectiveNode, key
      assert_equal "item.id", key.arguments.value
      assert_equal "boolean", first_state.states.first.kind
      assert_instance_of Herb::Errors::HerbStateDuplicateDeclarationError, second_state.errors.first
    end

    test "recovers control structures with missing end tags" do
      sources = {
        "if" => "<% if visible %>",
        "unless" => "<% unless hidden %>",
        "case" => "<% case role %>",
        "begin" => "<% begin %>",
        "while" => "<% while running %>",
        "until" => "<% until finished %>",
        "for" => "<% for item in items %>",
      }

      sources.each do |keyword, source|
        node = Herb::Backend::PureRuby.parse(source).value.children.first
        error = node.errors.first

        assert_nil node.end_node
        assert_instance_of Herb::Errors::MissingERBEndTagError, error
        assert_equal "`<% #{keyword} %>`", error.keyword
      end
    end

    test "recovers repeated unmatched tags up to the error limit" do
      openings = Herb::Backend::PureRuby.parse("<div>" * 10, max_errors: 3)
      closings = Herb::Backend::PureRuby.parse("</div>" * 10, max_errors: 4)

      assert_equal 10, openings.value.children.length
      assert_equal 3, openings.errors.length
      assert_equal 10, closings.value.children.length
      assert_equal 4, closings.errors.length
    end

    test "transforms yields embedded in Ruby expressions" do
      sources = [
        "<%= yield(:header) if content_for?(:header) %>",
        "<% content = capture { yield } if block_given? %>",
        "<% foo { yield } %>"
      ]

      sources.each do |source|
        node = Herb::Backend::PureRuby.parse(source).value.children.first

        assert_instance_of Herb::AST::ERBYieldNode, node
      end

      ordinary_content = [
        "<% def render; yield; end %>",
        "<% break if yield %>",
        "<% return yield %>"
      ]
      ordinary_content.each do |source|
        node = Herb::Backend::PureRuby.parse(source).value.children.first

        assert_instance_of Herb::AST::ERBContentNode, node
      end
    end

    test "attaches block parameter diagnostics to the block" do
      result = Herb::Backend::PureRuby.parse("<% block do |name, name:| %><% end %>")
      block = result.value.children.first

      assert_equal ["parameter_name_duplicated"], result.value.errors.map(&:diagnostic_id)
      assert_equal ["parameter_name_duplicated"], block.errors.map(&:diagnostic_id)
      argument_names = block.block_arguments.map { |argument| argument.name.value }
      assert_equal ["name", "name"], argument_names
    end

    test "does not attach synthetic yield diagnostics to parameterized blocks" do
      source = "<%= yield(:sidebar).presence || capture do |item| %>fallback<% end %>"
      block = Herb::Backend::PureRuby.parse(source).value.children.first

      assert_instance_of Herb::AST::ERBBlockNode, block
      assert_empty block.errors
    end

    test "keeps complete conditionals in one tag and validates their control-flow scope" do
      source = "<% if false; next; end %>"
      node = Herb::Backend::PureRuby.parse(source).value.children.first

      assert_instance_of Herb::AST::ERBContentNode, node
      assert_instance_of Herb::Errors::ERBControlFlowScopeError, node.errors.first
      assert_equal "`<% next %>`", node.errors.first.keyword
    end

    test "recovers when attribute control flow ends in the element body" do
      source = '<div <% if condition %> class="a"> <% else %><% end %></div>'
      element = Herb::Backend::PureRuby.parse(source).value.children.first
      conditional = element.open_tag.children.first
      stray_controls = element.body.grep(Herb::AST::ERBContentNode)
      stray_keywords = stray_controls.map { |node| node.errors.first.keyword }

      assert_instance_of Herb::AST::ERBIfNode, conditional
      assert_instance_of Herb::Errors::MissingERBEndTagError, conditional.errors.first
      assert_equal ["`<% else %>`", "`<% end %>`"], stray_keywords
    end

    test "recovers when attribute-value control flow ends outside the value" do
      source = '<div class="<% if condition %>a<% else %>b"<% end %>></div>'
      element = Herb::Backend::PureRuby.parse(source).value.children.first
      value = element.open_tag.children.first.value
      conditional = value.children.first
      stray_end = element.open_tag.children.last

      assert_instance_of Herb::AST::ERBIfNode, conditional
      assert_instance_of Herb::Errors::MissingERBEndTagError, conditional.errors.first
      assert_instance_of Herb::AST::ERBContentNode, stray_end
      assert_equal "`<% end %>`", stray_end.errors.first.keyword
    end

    test "reports structural control-flow keywords outside their scope" do
      ["elsif", "else", "when", "in", "rescue", "ensure", "end"].each do |keyword|
        node = Herb::Backend::PureRuby.parse("<% #{keyword} %>").value.children.first

        assert_instance_of Herb::AST::ERBContentNode, node
        assert_instance_of Herb::Errors::ERBControlFlowScopeError, node.errors.first
        assert_equal "`<% #{keyword} %>`", node.errors.first.keyword
      end
    end

    test "transforms matching conditional element wrappers" do
      source = <<~HTML
        <% if wrapped? %>
          <div>
        <% end %>
          content
        <% if wrapped? %>
          </div>
        <% end %>
      HTML
      result = Herb::Backend::PureRuby.parse(source)
      element = result.value.children.first

      assert_instance_of Herb::AST::HTMLConditionalElementNode, element
      assert_equal "wrapped?", element.condition
      assert_equal "div", element.tag_name.value
      assert_empty element.open_tag.errors
      assert_empty element.close_tag.errors
    end

    test "transforms inline output conditionals according to their HTML context" do
      ternary = Herb::Backend::PureRuby.parse(
        "<%= visible ? 'yes' : 'no' %>", transform_conditionals: true
      ).value.children.first
      attribute = Herb::Backend::PureRuby.parse(
        '<div class="<%= \'active\' if selected %>"></div>', transform_conditionals: true
      ).value.children.first.open_tag.children.first.value.children.first
      escaped = Herb::Backend::PureRuby.parse(
        "<%= '<b>' if visible %>", transform_conditionals: true
      ).value.children.first

      assert_instance_of Herb::AST::ERBIfNode, ternary
      assert_equal "yes", ternary.statements.first.content
      assert_equal "no", ternary.subsequent.statements.first.content
      assert_instance_of Herb::AST::LiteralNode, attribute.statements.first
      assert_instance_of Herb::AST::ERBContentNode, escaped.statements.first
    end

    test "reports mismatched conditional element conditions" do
      source = <<~HTML
        <% if open? %>
          <div>
        <% end %>
        <% if close? %>
          </div>
        <% end %>
      HTML
      result = Herb::Backend::PureRuby.parse(source)
      error = result.value.errors.first

      assert_instance_of Herb::Errors::ConditionalElementConditionMismatchError, error
      assert_equal "open?", error.open_condition
      assert_equal "close?", error.close_condition
    end

    test "keeps other complete control structures in one tag" do
      ruby_sources = [
        "unless hidden; show; end",
        "case role; when :admin; show; end",
        "begin; work; rescue; recover; end",
        "while active; work; end",
        "until done; work; end",
        "for item in items; work; end",
        "work do; item; end"
      ]

      ruby_sources.each do |ruby_source|
        node = Herb::Backend::PureRuby.parse("<% #{ruby_source} %>").value.children.first

        assert_instance_of Herb::AST::ERBContentNode, node
      end
    end

    test "reports multiple unclosed control structures in one ERB tag" do
      node = Herb::Backend::PureRuby.parse("<% if a; if b %>x<% end; end %>").value.children.first

      assert_instance_of Herb::AST::ERBIfNode, node
      assert_instance_of Herb::Errors::ERBMultipleBlocksInTagError, node.errors.first
      assert_equal " end; end ", node.end_node.content.value
    end

    test "splits a case condition from a shared ERB tag" do
      node = Herb::Backend::PureRuby.parse('<% case value when "a" %>A<% end %>').value.children.first

      assert_instance_of Herb::AST::ERBCaseNode, node
      assert_nil node.tag_closing
      assert_instance_of Herb::Errors::ERBCaseWithConditionsError, node.errors.first
      assert_nil node.conditions.first.tag_opening
      assert_equal 'when "a" ', node.conditions.first.content.value
    end

    test "splits a continuation and end from a shared ERB tag" do
      node = Herb::Backend::PureRuby.parse("<% if a %>x<% else\ny\nend %>").value.children.first

      assert_instance_of Herb::AST::ERBElseNode, node.subsequent
      assert_nil node.subsequent.tag_closing
      assert_nil node.end_node.tag_opening
      assert_equal "end ", node.end_node.content.value
    end

    test "lexes an empty document" do
      result = Herb::Backend::PureRuby.lex("")

      assert_equal ["TOKEN_EOF"], result.value.map(&:type)
      assert_equal [0, 0], result.value.last.range.to_a
      assert_equal Herb::Location.from(1, 0, 1, 0).to_hash, result.value.last.location.to_hash
    end

    test "lexes basic HTML and ERB" do
      result = Herb::Backend::PureRuby.lex("<h1><%= name %></h1>")

      assert_equal(
        [
          "TOKEN_HTML_TAG_START",
          "TOKEN_IDENTIFIER",
          "TOKEN_HTML_TAG_END",
          "TOKEN_ERB_START",
          "TOKEN_ERB_CONTENT",
          "TOKEN_ERB_END",
          "TOKEN_HTML_TAG_START_CLOSE",
          "TOKEN_IDENTIFIER",
          "TOKEN_HTML_TAG_END",
          "TOKEN_EOF"
        ],
        result.value.map(&:type)
      )
      assert_equal " name ", result.value[4].value
      assert_equal [7, 13], result.value[4].range.to_a
    end

    test "recovers a malformed ERB closing delimiter after parseable Ruby" do
      erb = Herb::Backend::PureRuby.parse("<%= count > 10 >").value.children.first

      assert_equal " count > 10 ", erb.content.value
      assert_equal ">", erb.tag_closing.value
      assert_instance_of Herb::Errors::MalformedERBClosingTagError, erb.errors.first
    end

    test "parses ERB interpolation inside an attribute name" do
      element = Herb::Backend::PureRuby.parse('<img data-<%= key %>-name="example">').value.children.first
      attribute = element.open_tag.children.first

      assert_equal [Herb::AST::LiteralNode, Herb::AST::ERBContentNode, Herb::AST::LiteralNode],
                   attribute.name.children.map(&:class)
      values = attribute.name.children.map do |child|
        child.is_a?(Herb::AST::ERBContentNode) ? child.content.value : child.content
      end
      assert_equal ["data-", " key ", "-name"], values
    end

    test "recovers an unclosed ERB tag at the first HTML boundary outside Ruby" do
      element = Herb::Backend::PureRuby.parse('<p><%= tag("</p>") </p>').value.children.first
      erb = element.body.first

      assert_equal ' tag("</p>") ', erb.content.value
      assert_instance_of Herb::Errors::UnclosedERBTagError, erb.errors.first
      assert_equal "p", element.close_tag.tag_name.value
    end

    test "extracts Ruby while preserving source positions" do
      source = "<h1>\n  <% if visible %><%= title %><% end %>\n</h1>"

      assert_equal "    \n     if visible  ;    title  ;   end  ;\n     ", Herb::Backend::PureRuby.extract_ruby(source)
    end

    test "extracts HTML while blanking ERB" do
      source = "<h1><%= title %></h1>"

      assert_equal "<h1>            </h1>", Herb::Backend::PureRuby.extract_html(source)
    end

    test "parses text in nested HTML elements" do
      result = Herb::Backend::PureRuby.parse("<main>Hello <span>world</span></main>")
      main = result.value.children.first

      assert_instance_of Herb::AST::HTMLElementNode, main
      assert_equal "main", main.tag_name.value
      assert_equal [Herb::AST::HTMLTextNode, Herb::AST::HTMLElementNode], main.body.map(&:class)
      assert_equal "world", main.body.last.body.first.content
    end

    test "parses script and style bodies as raw text with ERB islands" do
      source = '<script>if (x < 1) { html = "<div>"; } <%= value %></script>' \
               '<style>.parent > .child { content: "<span>"; }</style>'
      script, style = Herb::Backend::PureRuby.parse(source).value.children

      assert_equal [Herb::AST::LiteralNode, Herb::AST::ERBContentNode], script.body.map(&:class)
      assert_equal 'if (x < 1) { html = "<div>"; } ', script.body.first.content
      assert_equal " value ", script.body.last.content.value
      assert_equal [Herb::AST::LiteralNode], style.body.map(&:class)
      assert_equal '.parent > .child { content: "<span>"; }', style.body.first.content
    end

    test "parses obsolete raw-text elements" do
      source = "<xmp><b>bold</b></xmp><noembed><img></noembed><noframes><p>fallback</p></noframes>"
      elements = Herb::Backend::PureRuby.parse(source).value.children
      names = elements.map { |element| element.tag_name.value }
      contents = elements.map { |element| element.body.first.content }

      assert_equal ["xmp", "noembed", "noframes"], names
      assert_equal ["<b>bold</b>", "<img>", "<p>fallback</p>"], contents
    end

    test "treats plaintext as HTML-only raw text through the end of the document" do
      html = Herb::Backend::PureRuby.parse("<plaintext><b>literal</b></plaintext>").value.children.first
      xml = Herb::Backend::PureRuby.parse("<?xml version=\"1.0\"?><PlainText>false</PlainText>").value.children.last

      assert_equal "<b>literal</b></plaintext>", html.body.first.content
      assert_nil html.close_tag
      assert_instance_of Herb::AST::HTMLTextNode, xml.body.first
      assert_equal "false", xml.body.first.content
    end

    test "parses doctypes and CDATA with ERB islands" do
      doctype, cdata = Herb::Backend::PureRuby.parse("<!DOCTYPE html><![CDATA[x <%= value %>]]>").value.children

      assert_instance_of Herb::AST::HTMLDoctypeNode, doctype
      assert_equal " html", doctype.children.first.content
      assert_instance_of Herb::AST::CDATANode, cdata
      assert_equal [Herb::AST::LiteralNode, Herb::AST::ERBContentNode], cdata.children.map(&:class)
    end

    test "parses XML processing instructions with ERB islands" do
      instruction = Herb::Backend::PureRuby.parse(
        '<?marker name="<%= placeholder %>"?>'
      ).value.children.first

      assert_instance_of Herb::AST::XMLProcessingInstructionNode, instruction
      assert_equal "marker", instruction.target.value
      assert_equal [Herb::AST::LiteralNode, Herb::AST::ERBContentNode, Herb::AST::LiteralNode],
                   instruction.children.map(&:class)
      assert_equal "?>", instruction.tag_closing.value
    end

    test "reports an unterminated XML processing instruction" do
      instruction = Herb::Backend::PureRuby.parse("<?marker").value.children.first

      assert_empty instruction.tag_closing.value
      assert_instance_of Herb::Errors::UnexpectedTokenError, instruction.errors.first
      assert_equal "TOKEN_XML_DECLARATION_END", instruction.errors.first.expected_type
    end

    test "keeps ERB control flow structural in XML processing instructions" do
      instruction = Herb::Backend::PureRuby.parse(
        "<?marker <% if ready? %>yes<% end %>?>"
      ).value.children.first
      conditional = instruction.children.last

      assert_instance_of Herb::AST::ERBIfNode, conditional
      assert_equal "yes", conditional.statements.first.content
    end

    test "scans declaration prefixes next to multibyte text" do
      text = Herb::Backend::PureRuby.parse("12345678é").value.children.first

      assert_equal "12345678é", text.content
    end

    test "recovers an unclosed ERB tag before a raw-text closing tag" do
      script = Herb::Backend::PureRuby.parse("<script>value = <%</script>").value.children.first
      erb = script.body.last

      assert_instance_of Herb::AST::ERBContentNode, erb
      assert_empty erb.content.value
      assert_instance_of Herb::Errors::UnclosedERBTagError, erb.errors.first
      assert_equal "script", script.close_tag.tag_name.value
    end

    test "parses textarea and title bodies as escapable text with ERB islands" do
      source = "<textarea><b>literal</b><%= value %></textarea><title>a <i>literal</i></title>"
      textarea, title = Herb::Backend::PureRuby.parse(source).value.children

      assert_equal [Herb::AST::HTMLTextNode, Herb::AST::ERBContentNode], textarea.body.map(&:class)
      assert_equal "<b>literal</b>", textarea.body.first.content
      assert_equal [Herb::AST::HTMLTextNode], title.body.map(&:class)
      assert_equal "a <i>literal</i>", title.body.first.content
    end

    test "keeps ERB control flow structural in escapable text" do
      textarea = Herb::Backend::PureRuby.parse(
        "<textarea><% if draft? %><b>Draft</b><% else %>Final<% end %></textarea>"
      ).value.children.first
      conditional = textarea.body.first

      assert_instance_of Herb::AST::ERBIfNode, conditional
      assert_equal "<b>Draft</b>", conditional.statements.first.content
      assert_equal "Final", conditional.subsequent.statements.first.content
    end

    test "treats HTML void element names as regular elements inside SVG" do
      svg = Herb::Backend::PureRuby.parse(
        "<svg><br>line</br><img></img><path /></svg>"
      ).value.children.first
      br, img, path = svg.body

      refute_predicate br, :is_void
      assert_equal "br", br.close_tag.tag_name.value
      refute_predicate img, :is_void
      assert_equal "img", img.close_tag.tag_name.value
      assert_predicate path, :is_void
    end

    test "uses SVG void semantics for orphan and ancestor closing tags" do
      orphan = Herb::Backend::PureRuby.parse("<svg></br></svg>").value.children.first.body.first
      br = Herb::Backend::PureRuby.parse("<svg><br><g></br></svg>").value.children.first.body.first

      assert_empty orphan.errors
      assert_instance_of Herb::AST::HTMLElementNode, br
      assert_instance_of Herb::AST::HTMLOpenTagNode, br.body.first
      assert_instance_of Herb::Errors::MissingClosingTagError, br.body.first.errors.first
      assert_equal "br", br.close_tag.tag_name.value
    end

    test "keeps an unclosed raw-text element as an element node" do
      script = Herb::Backend::PureRuby.parse("<script>const value = 1").value.children.first

      assert_instance_of Herb::AST::HTMLElementNode, script
      assert_nil script.close_tag
      assert_instance_of Herb::Errors::MissingClosingTagError, script.errors.first
      assert_equal "const value = 1", script.body.first.content
    end

    test "parses enabled dot-notation tag names and validates their first segment" do
      element = Herb::Backend::PureRuby.parse(
        "<Dialog.Button></Dialog.Button>", dot_notation_tags: true
      ).value.children.first
      invalid = Herb::Backend::PureRuby.parse(
        "<dialog.Button></dialog.Button>", dot_notation_tags: true
      ).value.children.first

      assert_equal "Dialog.Button", element.tag_name.value
      assert_equal "Dialog.Button", element.close_tag.tag_name.value
      assert_instance_of Herb::Errors::DotNotationCasingError, invalid.open_tag.errors.first
      assert_instance_of Herb::Errors::DotNotationCasingError, invalid.close_tag.errors.first
    end

    test "recovers malformed and void closing tags inside their parent" do
      parent = Herb::Backend::PureRuby.parse("<div></br><span></span></div>").value.children.first
      void_close = parent.body.first

      assert_instance_of Herb::Errors::VoidElementClosingTagError, void_close.errors.first
      assert_instance_of Herb::AST::HTMLElementNode, parent.body.last
      assert_equal "div", parent.close_tag.tag_name.value

      unclosed = Herb::Backend::PureRuby.parse("<p>Hello</p").value.children.first.close_tag
      assert_nil unclosed.tag_closing
      assert_instance_of Herb::Errors::UnclosedCloseTagError, unclosed.errors.first

      paragraph = Herb::Backend::PureRuby.parse("<div><p>text</div>").value.children.first.body.first
      assert_instance_of Herb::AST::HTMLOmittedCloseTagNode, paragraph.close_tag
      assert_instance_of Herb::Errors::OmittedClosingTagError, paragraph.errors.first
    end

    test "implicitly closes optional end tags at sibling and parent boundaries" do
      list = Herb::Backend::PureRuby.parse("<ul><li>one<li>two</ul>").value.children.first
      first, second = list.body

      assert_instance_of Herb::AST::HTMLElementNode, first
      assert_instance_of Herb::AST::HTMLOmittedCloseTagNode, first.close_tag
      assert_instance_of Herb::Errors::OmittedClosingTagError, first.errors.first
      assert_instance_of Herb::AST::HTMLOmittedCloseTagNode, second.close_tag
      assert_equal(["one", "two"], list.body.map { |item| item.body.first.content })
    end

    test "implicitly closes optional end tags at an ERB block boundary" do
      source = "<ul><% items.each do |item| %><li><%= item %><% end %></ul>"
      block = Herb::Backend::PureRuby.parse(source, strict: false).value.children.first.body.first
      item = block.body.first

      assert_instance_of Herb::AST::HTMLElementNode, item
      assert_instance_of Herb::AST::HTMLOmittedCloseTagNode, item.close_tag
      assert_empty item.errors
    end

    test "keeps a malformed void opening tag separate from the following element" do
      input, span = Herb::Backend::PureRuby.parse('<input name="field"<span>content</span>').value.children

      assert_instance_of Herb::AST::HTMLOpenTagNode, input
      assert_nil input.tag_closing
      assert_instance_of Herb::Errors::UnclosedOpenTagError, input.errors.first
      assert_instance_of Herb::AST::HTMLElementNode, span
    end

    test "parses non-ERB content as literals when HTML parsing is disabled" do
      document = Herb::Backend::PureRuby.parse("n <o.length", html: false).value

      assert_equal [Herb::AST::LiteralNode], document.children.map(&:class)
      assert_equal "n <o.length", document.children.first.content
    end

    test "recovers a nested element closed by its parent" do
      outer = Herb::Backend::PureRuby.parse("<div><span></div>").value.children.first
      orphaned_open_tag = outer.body.first

      assert_instance_of Herb::AST::HTMLOpenTagNode, orphaned_open_tag
      assert_instance_of Herb::Errors::MissingClosingTagError, orphaned_open_tag.errors.first
      assert_equal "div", outer.close_tag.tag_name.value
    end

    test "parses output ERB" do
      result = Herb::Backend::PureRuby.parse("<p><%= greeting %></p>")
      erb = result.value.children.first.body.first

      assert_instance_of Herb::AST::ERBContentNode, erb
      assert_equal " greeting ", erb.content.value
      assert_predicate erb, :valid
    end

    test "transforms render calls when enabled" do
      node = Herb::Backend::PureRuby.parse(
        '<%= render "user", user: user %>', render_nodes: true
      ).value.children.first

      assert_instance_of Herb::AST::ERBRenderNode, node
      assert_equal "user", node.keywords.partial.value
      assert_equal "user", node.keywords.locals.first.name.value
      assert_equal "user", node.keywords.locals.first.value.content
    end

    test "classifies render keywords and validation errors" do
      valid = Herb::Backend::PureRuby.parse(
        '<%= render partial: "card", collection: cards, as: :item %>', render_nodes: true
      ).value.children.first
      invalid = Herb::Backend::PureRuby.parse("<%= render %>", render_nodes: true).value.children.first

      assert_equal "card", valid.keywords.partial.value
      assert_equal "cards", valid.keywords.collection.value
      assert_equal "item", valid.keywords.as_name.value
      assert_instance_of Herb::Errors::RenderNoArgumentsError, invalid.errors.first
    end

    test "extracts render state declarations when directives are enabled" do
      node = Herb::Backend::PureRuby.parse(
        '<%= render "card", state: { open: modal_open, count: 3, page:, **extra } %>',
        render_nodes: true,
        herb_directives: true
      ).value.children.first

      assert_empty node.keywords.locals
      names = node.keywords.state.map { |state| state.name.value }
      assert_equal ["open", "count", "page", "**extra"], names
      assert_equal ["bare", "integer", "bare", "missing"], node.keywords.state.map(&:kind)
      values = node.keywords.state.map { |state| state.default_value&.content }
      assert_equal ["modal_open", "3", "page", nil], values
      refute_nil node.keywords.state_location
    end

    test "builds render nodes for do and inline brace blocks" do
      do_block = Herb::Backend::PureRuby.parse(
        "<%= render Card.new do |card| %><%= card %><% end %>", render_nodes: true
      ).value.children.first
      inline_block = Herb::Backend::PureRuby.parse(
        "<%= render Card.new { |card| card.title } %>", render_nodes: true
      ).value.children.first

      assert_instance_of Herb::AST::ERBRenderNode, do_block
      assert_equal "Card.new", do_block.keywords.object.value
      assert_equal "card", do_block.block_arguments.first.name.value
      assert_instance_of Herb::AST::ERBContentNode, do_block.body.first
      assert_equal "card.title", inline_block.body.first.content
      assert_equal "card", inline_block.block_arguments.first.name.value
    end

    test "recovers a nested ERB opener" do
      result = Herb::Backend::PureRuby.parse('<%= render inline: "<%= name %>" %>', render_nodes: true)

      assert_instance_of Herb::Errors::NestedERBTagError, result.value.children.first.errors.first
      assert_instance_of Herb::AST::ERBContentNode, result.value.children[1]
      assert_equal [Herb::Errors::StrayERBClosingTagError, Herb::Errors::RubyParseError],
                   result.value.errors.map(&:class)
    end

    test "keeps an unterminated control opener around a nested ERB tag" do
      node = Herb::Backend::PureRuby.parse("<% if admin?\n<%= name %>").value.children.first

      assert_instance_of Herb::AST::ERBIfNode, node
      assert_nil node.tag_closing
      assert_equal [Herb::Errors::NestedERBTagError, Herb::Errors::MissingERBEndTagError], node.errors.map(&:class)
      assert_instance_of Herb::AST::ERBContentNode, node.statements.first
    end

    test "locates an explicit then keyword on a control node" do
      node = Herb::Backend::PureRuby.parse("<% if ready? then %>yes<% end %>").value.children.first

      assert_equal Herb::Location.from(1, 13, 1, 17).to_hash, node.then_keyword.to_hash
    end

    test "transforms an assignment-wrapped case expression" do
      source = "<% header_error = case %><% when missing? then :required %><% end %>"
      node = Herb::Backend::PureRuby.parse(source).value.children.first

      assert_instance_of Herb::AST::ERBCaseNode, node
      assert_instance_of Herb::AST::ERBWhenNode, node.conditions.first
      assert_equal Herb::Location.from(1, 42, 1, 46).to_hash, node.conditions.first.then_keyword.to_hash
    end

    test "transforms link_to calls when Action View helpers are enabled" do
      node = Herb::Backend::PureRuby.parse(
        '<%= link_to "Profile", user_path(user) %>', action_view_helpers: true
      ).value.children.first

      assert_instance_of Herb::AST::HTMLElementNode, node
      assert_instance_of Herb::AST::ERBOpenTagNode, node.open_tag
      assert_equal "Profile", node.body.first.content
      assert_equal "user_path(user)", node.open_tag.children.first.value.children.first.content
    end

    test "transforms block link_to calls with model URLs and HTML options" do
      source = <<~HTML
        <%= link_to @profile, class: "profile" do %>
          <strong><%= @profile.name %></strong>
        <% end %>
      HTML
      link = Herb::Backend::PureRuby.parse(source, action_view_helpers: true).value.children.first

      attribute_names = link.open_tag.children.map { |attribute| attribute.name.children.first.content }
      assert_equal ["class", "href"], attribute_names
      assert_equal "url_for(@profile)", link.open_tag.children.last.value.children.first.content
      assert_instance_of Herb::AST::HTMLElementNode, link.body[1]
      assert_instance_of Herb::AST::ERBEndNode, link.close_tag
    end

    test "transforms turbo_frame_tag blocks when Action View helpers are enabled" do
      source = <<~HTML
        <%= turbo_frame_tag post, data: { controller: "frame" } do %>
          Content
        <% end %>
      HTML
      node = Herb::Backend::PureRuby.parse(source, action_view_helpers: true).value.children.first

      assert_instance_of Herb::AST::HTMLElementNode, node
      assert_equal "turbo-frame", node.tag_name.value
      names = node.open_tag.children.map { |attribute| attribute.name.children.first.content }
      assert_equal ["data-controller", "id"], names
      assert_equal "dom_id(post)", node.open_tag.children.last.value.children.first.content
      assert_instance_of Herb::AST::ERBEndNode, node.close_tag
    end

    test "transforms content_tag and tag helpers without rewriting a shadowed tag variable" do
      source = <<~HTML
        <%= content_tag :p, "Hello" %>
        <%= tag.hr %>
        <% tag = record %><%= tag.name %>
      HTML
      children = Herb::Backend::PureRuby.parse(source, action_view_helpers: true).value.children
      elements = children.grep(Herb::AST::HTMLElementNode)
      names = elements.map { |element| element.tag_name.value }

      assert_equal [Herb::AST::HTMLElementNode, Herb::AST::HTMLElementNode],
                   elements.map(&:class)
      assert_equal ["p", "hr"], names
      assert_instance_of Herb::AST::ERBContentNode, children[-2]
      assert_equal " tag.name ", children[-2].content.value
    end

    test "wraps javascript_tag block content in CDATA and resolves a true nonce" do
      source = <<~HTML
        <%= javascript_tag nonce: true do %>
          const value = "<%= item %>"
        <% end %>
      HTML
      script = Herb::Backend::PureRuby.parse(source, action_view_helpers: true).value.children.first
      nonce = script.open_tag.children.first
      cdata = script.body.first

      assert_instance_of Herb::AST::HTMLElementNode, script
      assert_equal "script", script.tag_name.value
      assert_equal "content_security_policy_nonce", nonce.value.children.first.content
      assert_instance_of Herb::AST::CDATANode, cdata
      assert_equal [Herb::AST::LiteralNode, Herb::AST::ERBContentNode, Herb::AST::LiteralNode],
                   cdata.children.map(&:class)
      refute_predicate cdata.children[1], :parsed
    end

    test "expands javascript_include_tag sources and keeps path options out of HTML attributes" do
      source = '<%= javascript_include_tag "application", "vendor", host: "assets.test", defer: true %>'
      children = Herb::Backend::PureRuby.parse(source, action_view_helpers: true).value.children
      scripts = children.grep(Herb::AST::HTMLElementNode)

      assert_equal 2, scripts.length
      assert_equal [Herb::AST::HTMLElementNode, Herb::AST::HTMLTextNode, Herb::AST::HTMLElementNode],
                   children.map(&:class)
      attribute_names = scripts.first.open_tag.children.map { |attribute| attribute.name.children.first.content }
      assert_equal ["src", "defer"], attribute_names
      assert_equal 'javascript_path("application", host: "assets.test")',
                   scripts.first.open_tag.children.first.value.children.first.content
      assert_equal 'javascript_path("vendor", host: "assets.test")',
                   scripts.last.open_tag.children.first.value.children.first.content
    end

    test "transforms image_tag dynamic sources, sizes, and path options" do
      source = "<%= image_tag avatar, size: dimensions, skip_pipeline: true %>"
      image = Herb::Backend::PureRuby.parse(source, action_view_helpers: true).value.children.first
      attributes = image.open_tag.children

      assert_equal "img", image.tag_name.value
      assert_predicate image, :is_void
      attribute_names = attributes.map { |attribute| attribute.name.children.first.content }
      assert_equal ["width", "height", "src"], attribute_names
      assert_equal 'dimensions.to_s.split("x", 2)[0]', attributes[0].value.children.first.content
      assert_equal 'dimensions.to_s.split("x", 2)[-1]', attributes[1].value.children.first.content
      assert_equal "image_path(avatar, skip_pipeline: true)", attributes[2].value.children.first.content
    end

    test "expands stylesheet_link_tag sources with shared attributes" do
      source = '<%= stylesheet_link_tag "application", "print", rel: "preload", media: "print" %>'
      children = Herb::Backend::PureRuby.parse(source, action_view_helpers: true).value.children
      links = children.grep(Herb::AST::HTMLElementNode)

      assert_equal [Herb::AST::HTMLElementNode, Herb::AST::HTMLTextNode, Herb::AST::HTMLElementNode],
                   children.map(&:class)
      links.each do |link|
        attribute_names = link.open_tag.children.map { |attribute| attribute.name.children.first.content }
        assert_equal ["rel", "href", "media"], attribute_names
        assert_equal "preload", link.open_tag.children.first.value.children.first.content
      end
      assert_equal 'stylesheet_path("application")', links.first.open_tag.children[1].value.children.first.content
      assert_equal 'stylesheet_path("print")', links.last.open_tag.children[1].value.children.first.content
    end

    test "parses strict locals directives when enabled" do
      node = Herb::Backend::PureRuby.parse("<%# locals: (users:) %>", strict_locals: true).value.children.first

      assert_instance_of Herb::AST::ERBStrictLocalsNode, node
      assert_equal "users", node.locals.first.name.value
      assert_equal "keyword", node.locals.first.kind
      assert_predicate node.locals.first, :required
    end

    test "parses HTML attributes" do
      element = Herb::Backend::PureRuby.parse('<input required class="card wide">').value.children.first
      required, class_attribute = element.open_tag.children

      assert_nil required.value
      assert_equal "required", required.name.children.first.content
      assert_equal "class", class_attribute.name.children.first.content
      assert_equal "card wide", class_attribute.value.children.first.content
      assert_predicate class_attribute.value, :quoted
    end

    test "parses conditional HTML attributes" do
      element = Herb::Backend::PureRuby.parse("<input <% if disabled? %>disabled<% end %>>").value.children.first
      conditional = element.open_tag.children.first

      assert_instance_of Herb::AST::ERBIfNode, conditional
      assert_equal "disabled", conditional.statements.first.name.children.first.content
      assert_instance_of Herb::AST::ERBEndNode, conditional.end_node
    end

    test "parses elsif and else HTML attributes" do
      source = "<input <% if primary? %>data-primary<% elsif secondary? %>data-secondary<% else %>data-default<% end %>>"
      conditional = Herb::Backend::PureRuby.parse(source).value.children.first.open_tag.children.first

      assert_instance_of Herb::AST::ERBIfNode, conditional.subsequent
      assert_instance_of Herb::AST::ERBElseNode, conditional.subsequent.subsequent
      assert_equal "data-default", conditional.subsequent.subsequent.statements.first.name.children.first.content
    end

    test "parses case branches around HTML attributes" do
      source = "<input <% case mode %><% when :compact %>data-compact<% else %>data-full<% end %>>"
      case_node = Herb::Backend::PureRuby.parse(source).value.children.first.open_tag.children.first

      assert_instance_of Herb::AST::ERBCaseNode, case_node
      assert_instance_of Herb::AST::ERBWhenNode, case_node.conditions.first
      assert_instance_of Herb::AST::ERBElseNode, case_node.else_clause
    end

    test "parses do blocks and their parameters around HTML attributes" do
      source = "<input <% items.each do |item| %>data-item<% end %>>"
      block = Herb::Backend::PureRuby.parse(source).value.children.first.open_tag.children.first

      assert_instance_of Herb::AST::ERBBlockNode, block
      assert_equal "item", block.block_arguments.first.name.value
      assert_equal "data-item", block.body.first.name.children.first.content
    end

    test "parses a block inside an attribute value without transforming it into an iteration" do
      source = '<div class="<% classes.each do |name| %><%= name %><% end %>"></div>'
      value = Herb::Backend::PureRuby.parse(source, iteration_nodes: true).value.children.first.open_tag.children.first.value
      block = value.children.first

      assert_instance_of Herb::AST::ERBBlockNode, block
      assert_equal "name", block.block_arguments.first.name.value
      assert_instance_of Herb::AST::ERBContentNode, block.body.first
    end

    test "parses every block parameter kind" do
      source = "<input <% items.each do |a, b = [1, 2], *c, d:, e: { x: 1 }, **f, &g| %>data-item<% end %>>"
      parameters = Herb::Backend::PureRuby.parse(source).value.children.first.open_tag.children.first.block_arguments

      assert_equal ["positional", "positional", "rest", "keyword", "keyword", "keyword_rest", "block"],
                   parameters.map(&:kind)
      assert_equal [true, false, false, true, false, false, false], parameters.map(&:required)
      defaults = parameters.map { |parameter| parameter.default_value&.content }
      assert_equal [nil, "[1, 2]", nil, nil, "{ x: 1 }", nil, nil], defaults
      assert_equal [0, 0], parameters.first.name.range.to_a
    end

    test "flattens nested destructured block parameters" do
      source = "<input <% rows.each do |(first, (second, *tail))| %>data-row<% end %>>"
      parameters = Herb::Backend::PureRuby.parse(source).value.children.first.open_tag.children.first.block_arguments

      names = parameters.map { |parameter| parameter.name.value }
      locations = parameters.map { |parameter| parameter.location.start.column }
      assert_equal ["first", "second", "tail"], names
      assert_equal ["positional", "positional", "rest"], parameters.map(&:kind)
      assert_equal [25, 33, 42], locations
    end

    test "parses body conditionals containing HTML" do
      source = "<% if visible %><p>yes</p><% else %>no<% end %>"
      conditional = Herb::Backend::PureRuby.parse(source).value.children.first

      assert_instance_of Herb::AST::ERBIfNode, conditional
      assert_instance_of Herb::AST::HTMLElementNode, conditional.statements.first
      assert_equal "no", conditional.subsequent.statements.first.content
      assert_equal " end ", conditional.end_node.content.value
    end

    test "parses a conditional open tag as one element" do
      source = '<% if admin? %><div class="admin"><% else %><div><% end %>name</div>'
      element = Herb::Backend::PureRuby.parse(source).value.children.first

      assert_instance_of Herb::AST::HTMLElementNode, element
      assert_instance_of Herb::AST::HTMLConditionalOpenTagNode, element.open_tag
      assert_instance_of Herb::AST::ERBIfNode, element.open_tag.conditional
      assert_equal "name", element.body.first.content
    end

    test "parses conditional open tags with whitespace and elsif branches" do
      source = <<~HTML
        <% if primary? %>
          <button class="primary">
        <% elsif secondary? %>
          <button class="secondary">
        <% else %>
          <button>
        <% end %>
          Save
        </button>
      HTML
      element = Herb::Backend::PureRuby.parse(source).value.children.first

      assert_instance_of Herb::AST::HTMLConditionalOpenTagNode, element.open_tag
      assert_instance_of Herb::AST::ERBIfNode, element.open_tag.conditional.subsequent
      assert_equal "button", element.tag_name.value
      assert_equal "Save", element.body.first.content.strip
    end

    test "parses an HTML comment" do
      comment = Herb::Backend::PureRuby.parse("<!-- a comment -->").value.children.first

      assert_instance_of Herb::AST::HTMLCommentNode, comment
      assert_equal "<!--", comment.comment_start.value
      assert_equal " a comment ", comment.children.first.content
      assert_equal "-->", comment.comment_end.value
    end

    test "parses ERB inside an HTML comment" do
      comment = Herb::Backend::PureRuby.parse("<!-- <% if visible? %>yes<% end %> -->").value.children.first

      assert_instance_of Herb::AST::ERBIfNode, comment.children[1]
      assert_equal "yes", comment.children[1].statements.first.content
      assert_equal " end ", comment.children[1].end_node.content.value
    end

    test "reports invalid and nested HTML comment delimiters" do
      invalid = Herb::Backend::PureRuby.parse("<!-- text --!>").value.children.first
      nested = Herb::Backend::PureRuby.parse("<!-- a <!-- b -->", strict: true).value.children.first
      non_strict = Herb::Backend::PureRuby.parse("<!-- a <!-- b -->", strict: false).value.children.first

      assert_instance_of Herb::Errors::InvalidCommentClosingTagError, invalid.errors.first
      assert_instance_of Herb::Errors::NestedCommentError, nested.errors.first
      assert_empty non_strict.errors
    end

    test "parses do blocks in an element body" do
      source = "<main><% items.each do |item| %><%= item %><% end %></main>"
      block = Herb::Backend::PureRuby.parse(source).value.children.first.body.first

      assert_instance_of Herb::AST::ERBBlockNode, block
      assert_equal "item", block.block_arguments.first.name.value
      assert_instance_of Herb::AST::ERBContentNode, block.body.first
    end

    test "parses brace blocks in a document body" do
      source = "<% items.each { |item| %><span><%= item %></span><% } %>"
      block = Herb::Backend::PureRuby.parse(source).value.children.first

      assert_instance_of Herb::AST::ERBBlockNode, block
      assert_equal "item", block.block_arguments.first.name.value
      assert_instance_of Herb::AST::HTMLElementNode, block.body.first
      assert_equal " } ", block.end_node.content.value
    end

    test "builds iteration nodes for native iteration methods" do
      methods = [
        "each", "each_with_index", "each_with_object", "each_slice", "each_cons", "each_pair", "each_entry",
        "times", "upto", "downto", "step", "map", "flat_map", "select", "filter", "reject", "filter_map", "cycle"
      ]

      methods.each do |method|
        source = "<% items.#{method} do %><% end %>"
        block = Herb::Backend::PureRuby.parse(source, iteration_nodes: true).value.children.first

        assert_instance_of Herb::AST::ERBIterationBlockNode, block
        assert_equal method, block.message.value
      end
    end

    test "extracts iteration call metadata" do
      source = "<% items&.step(limit, 2) do |index| %><%= index %><% end %>"
      block = Herb::Backend::PureRuby.parse(source, iteration_nodes: true).value.children.first

      assert_equal "items", block.receiver.value
      assert_equal "&.", block.call_operator.value
      assert_equal "step", block.message.value
      assert_equal ["limit", "2"], block.arguments.map(&:content)
      assert_equal "do", block.block_opening.value
      argument_columns = block.arguments.map { |argument| argument.location.start.column }
      assert_equal [15, 22], argument_columns
    end

    test "extracts bare and keyword iteration arguments" do
      bare = Herb::Backend::PureRuby.parse("<% items.step 1, 2 do %><% end %>", iteration_nodes: true)
      keywords = Herb::Backend::PureRuby.parse(
        "<% items.each_with_object(a: 1, b: 2) do %><% end %>", iteration_nodes: true
      )

      assert_equal ["1", "2"], bare.value.children.first.arguments.map(&:content)
      assert_equal ["a: 1, b: 2"], keywords.value.children.first.arguments.map(&:content)
    end

    test "builds iteration nodes for brace blocks" do
      source = "<% items.each { |item| %><%= item %><% } %>"
      block = Herb::Backend::PureRuby.parse(source, iteration_nodes: true).value.children.first

      assert_instance_of Herb::AST::ERBIterationBlockNode, block
      assert_equal "{", block.block_opening.value
      assert_equal " } ", block.end_node.content.value
    end

    test "recovers an iteration block missing its end tag" do
      source = "<% items.each do |item| %><%= item %>"
      result = Herb::Backend::PureRuby.parse(source, iteration_nodes: true)
      block = result.value.children.first

      assert_instance_of Herb::AST::ERBIterationBlockNode, block
      assert_nil block.end_node
      assert_instance_of Herb::Errors::MissingERBEndTagError, block.errors.first
      assert_equal 2, result.value.errors.length
    end

    test "keeps ineligible blocks as generic blocks" do
      tap = Herb::Backend::PureRuby.parse("<% item.tap do |value| %>x<% end %>", iteration_nodes: true)
      assignment = Herb::Backend::PureRuby.parse("<% result = items.each do |item| %>x<% end %>", iteration_nodes: true)
      unanalyzed = Herb::Backend::PureRuby.parse(
        "<% items.each do |item| %>x<% end %>", iteration_nodes: true, analyze: false
      )

      assert_instance_of Herb::AST::ERBBlockNode, tap.value.children.first
      assert_instance_of Herb::AST::ERBBlockNode, assignment.value.children.first
      assert_empty assignment.value.children.first.block_arguments
      assert_equal [Herb::AST::ERBContentNode, Herb::AST::HTMLTextNode, Herb::AST::ERBContentNode],
                   unanalyzed.value.children.map(&:class)
      refute_predicate unanalyzed.value.children.first, :parsed
    end

    test "does not transform iteration syntax inside ERB comments" do
      result = Herb::Backend::PureRuby.parse("<%# items.each do |item| %>", iteration_nodes: true)

      assert_instance_of Herb::AST::ERBCommentNode, result.value.children.first
    end

    test "nests arbitrary HTML attribute blocks" do
      source = "<input <% case mode %><% when :many %><% items.each do |item| %>data-item<% end %><% end %>>"
      case_node = Herb::Backend::PureRuby.parse(source).value.children.first.open_tag.children.first

      assert_instance_of Herb::AST::ERBBlockNode, case_node.conditions.first.statements.first
      assert_instance_of Herb::AST::ERBEndNode, case_node.end_node
    end

    test "recovers missing attribute values" do
      result = Herb::Backend::PureRuby.parse("<input name=>")
      value = result.value.children.first.open_tag.children.first.value

      assert_predicate result, :failed?
      assert_instance_of Herb::Errors::MissingAttributeValueError, value.errors.first
    end

    test "reports missing whitespace between attributes" do
      result = Herb::Backend::PureRuby.parse('<input id="one"class="two">')

      assert_predicate result, :failed?
      assert_instance_of Herb::Errors::MissingWhitespaceBetweenAttributesError, result.errors.first
    end

    test "parses non-output ERB inside attribute names and reports invalid attribute tokens" do
      result = Herb::Backend::PureRuby.parse('<div data-<% key %>-id=a"b / next></div>')
      open_tag = result.value.children.first.open_tag
      dynamic_attribute, next_attribute = open_tag.children

      assert_equal [Herb::AST::LiteralNode, Herb::AST::ERBContentNode, Herb::AST::LiteralNode],
                   dynamic_attribute.name.children.map(&:class)
      assert_instance_of Herb::Errors::UnexpectedCharacterInUnquotedAttributeValueError,
                         dynamic_attribute.value.errors.first
      assert_instance_of Herb::Errors::UnexpectedSolidusInTagError, open_tag.errors.last
      assert_equal "next", next_attribute.name.children.first.content
    end

    test "recovers an unclosed quote before another attribute" do
      result = Herb::Backend::PureRuby.parse('<input class="foo title="bar">')
      first, second = result.value.children.first.open_tag.children

      assert_predicate result, :failed?
      assert_instance_of Herb::Errors::UnclosedQuoteError, first.value.errors.first
      assert_equal "foo ", first.value.children.first.content
      assert_equal "title", second.name.children.first.content
    end

    test "parses ordinary silent ERB" do
      erb = Herb::Backend::PureRuby.parse("<% user = current_user %>").value.children.first

      assert_instance_of Herb::AST::ERBContentNode, erb
      assert_equal " user = current_user ", erb.content.value
      assert_predicate erb, :parsed
    end

    test "keeps configured custom ERB tags out of Ruby analysis" do
      node = Herb::Backend::PureRuby.parse(
        "<%graphql query Products($first: Int!) { id } %>", erb_openers: ["graphql"]
      ).value.children.first

      assert_instance_of Herb::AST::ERBContentNode, node
      refute_predicate node, :parsed
      assert_predicate node, :valid
    end

    test "does not transform Ruby-looking custom ERB tags" do
      nodes = ["if ready?", "yield", "render partial: :card"].map do |content|
        Herb::Backend::PureRuby.parse(
          "<%herb #{content} %>", erb_openers: ["herb"], render_nodes: true
        ).value.children.first
      end

      assert_equal [Herb::AST::ERBContentNode] * 3, nodes.map(&:class)
      assert nodes.none?(&:parsed)
      assert nodes.all?(&:valid)
    end

    test "does not treat custom ERB content as a surrounding control-flow boundary" do
      source = "<% if ready? %><%herb end %><% end %>"
      conditional = Herb::Backend::PureRuby.parse(source, erb_openers: ["herb"]).value.children.first
      custom = conditional.statements.first

      assert_instance_of Herb::AST::ERBIfNode, conditional
      assert_instance_of Herb::AST::ERBContentNode, custom
      assert_empty custom.errors
      assert_equal " end ", conditional.end_node.content.value
    end

    test "keeps Ruby-looking custom ERB opaque in an opening tag" do
      open_tag = Herb::Backend::PureRuby.parse(
        "<div <%herb if ready? %>></div>", erb_openers: ["herb"]
      ).value.children.first.open_tag
      custom = open_tag.children.first

      assert_instance_of Herb::AST::ERBContentNode, custom
      refute_predicate custom, :parsed
      assert_predicate custom, :valid
      assert_empty custom.errors
    end

    test "keeps unclosed custom ERB opaque" do
      custom = Herb::Backend::PureRuby.parse(
        "<%graphql query { id }", erb_openers: ["graphql"]
      ).value.children.first

      refute_predicate custom, :parsed
      assert_predicate custom, :valid
      assert_equal ["UNCLOSED_ERB_TAG_ERROR"], custom.errors.map(&:type)
    end

    test "lexes an empty escaped ERB tag with the native delimiter split" do
      tokens = Herb::Backend::PureRuby.lex("<%%>").value

      assert_equal ["<%", "", "%>", ""], tokens.map(&:value)
    end

    test "keeps nameless closing-tag syntax as text" do
      ["</>", "</ >", "</", "</1>"].each do |source|
        result = Herb::Backend::PureRuby.parse(source)

        assert_instance_of Herb::AST::HTMLTextNode, result.value.children.first
        assert_equal source, result.value.children.first.content
        assert_empty result.errors
      end
    end

    test "allows whitespace before a closing tag name" do
      element = Herb::Backend::PureRuby.parse("<div></ div>", track_whitespace: true).value.children.first
      whitespace = element.close_tag.children.map { |child| child.value.value }

      assert_equal "div", element.close_tag.tag_name.value
      assert_equal [" "], whitespace
      assert_empty element.errors
    end

    test "recovers an invalid underscore closing tag name" do
      result = Herb::Backend::PureRuby.parse("</_>")
      close_tag = result.value.children.first

      assert_instance_of Herb::AST::HTMLCloseTagNode, close_tag
      assert_equal "_", close_tag.tag_name.value
      assert_equal ["UNEXPECTED_TOKEN_ERROR"], close_tag.errors.map(&:type)
      assert_equal "TOKEN_IDENTIFIER", close_tag.errors.first.expected_type
    end

    test "does not add an orphan error to an already malformed closing tag" do
      unclosed = Herb::Backend::PureRuby.parse("</div")
      solidus = Herb::Backend::PureRuby.parse("</div/>")

      assert_equal ["UNCLOSED_CLOSE_TAG_ERROR"], unclosed.errors.map(&:type)
      assert_equal ["END_TAG_WITH_TRAILING_SOLIDUS_ERROR"], solidus.errors.map(&:type)
    end

    test "omits AST token positions but preserves diagnostic positions when locations are disabled" do
      result = Herb::Backend::PureRuby.parse("<div>hello</span>", track_locations: false)
      open_tag, _text, close_tag = result.value.children

      assert_nil open_tag.tag_name.location
      assert_nil open_tag.tag_name.range
      assert_nil close_tag.tag_name.location
      assert_nil close_tag.tag_name.range
      assert_instance_of Herb::Location, close_tag.errors.first.location
      assert_instance_of Herb::Location, close_tag.errors.first.closing_tag.location
    end

    test "retains internal token offsets through transformations when locations are disabled" do
      block = Herb::Backend::PureRuby.parse(
        "<% items.each do |item| %><% end %>", track_locations: false
      ).value.children.first
      directive = Herb::Backend::PureRuby.parse(
        "<%# herb:key item.id %>", track_locations: false, herb_directives: true
      ).value.children.first

      assert_nil block.block_arguments.first.name.range
      assert_equal "item.id", directive.arguments.value
      assert_nil directive.arguments.range
    end

    test "parses a snapshot when the caller mutates the source" do
      source = +"<p>original</p>"
      parser = Herb::Backend::PureRuby::Parser.new(source)
      source.replace("<p>changed</p>")
      element = parser.parse.value.children.first

      assert_equal "original", element.body.first.content
      assert_equal "<p>changed</p>", source
    end
  end
end
