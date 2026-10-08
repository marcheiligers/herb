# frozen_string_literal: true

require_relative "../test_helper"
require "digest"
require "json"

class WasmBackendTest < Minitest::Spec
  WASM_PATH = File.expand_path("../../wasm/portable/build/herb.wasm", __dir__)

  def setup
    skip "the WebAssembly experiment requires JRuby" unless RUBY_ENGINE == "jruby"
    skip "build the WebAssembly module first" unless File.file?(WASM_PATH)

    require_relative "../../lib/herb/backend/wasm"
  end

  test "reports the compiled libherb and Prism versions" do
    assert_equal Herb::VERSION, Herb::Backend::Wasm::Endive.libherb_version
    assert_equal Herb::PRISM_VERSION, Herb::Backend::Wasm::Endive.prism_version
    assert_equal(
      "herb gem v#{Herb::VERSION}, libprism v#{Herb::PRISM_VERSION}, " \
      "libherb v#{Herb::VERSION} (WebAssembly through Endive)",
      Herb::Backend::Wasm.version
    )
  end

  test "extracts HTML with native-compatible behavior" do
    examples = {
      "" => "",
      "<h1>Hello</h1>" => "<h1>Hello</h1>",
      "<h1><%= user.name %></h1>" => "<h1>                </h1>",
      "<p>Héllö, 世界</p><% ignored %>" => "<p>Héllö, 世界</p>             ",
    }

    examples.each do |source, expected|
      assert_equal expected, Herb::Backend::Wasm.extract_html(source)
    end
  end

  test "extracts Ruby with native-compatible options" do
    examples = {
      ["<h1><%= user.name %></h1>", {}] => "        user.name  ;     ",
      [
        "<div>\n<%# note %>\n<% x = 1 %>\n<%= x %>\n</div>",
        { comments: true, semicolons: false, preserve_positions: false }
      ] => "\n# note \n x = 1 \n x \n",
      ["<%herb slot :header %><%= name %>", { erb_openers: ["herb"] }] =>
        "                     ;    name  ;",
      ["<%herb slot :header %><%= name %>", { erb_openers: ["herb"], custom_tags: true }] =>
        "       slot :header  ;    name  ;",
      ["<%= x %>", { semicolons: nil }] => "    x  ;",
      ["<%= x %>", { semicolons: false, "semicolons" => true }] => "    x  ;",
      ["<%= x %>", { semicolons: true, "semicolons" => false }] => "    x   ",
    }

    examples.each do |(source, options), expected|
      assert_equal expected, Herb::Backend::Wasm.extract_ruby(source, **options)
    end
  end

  test "can release and reuse guest memory across repeated calls" do
    source = "<p>hello</p><%= ignored %>"
    expected = Herb::Backend::PureRuby.extract_html(source)

    100.times do
      assert_equal expected, Herb::Backend::Wasm.extract_html(source)
    end
  end

  test "serializes concurrent JRuby calls through one Wasm instance" do
    threads = Array.new(4) do |index|
      Thread.new do
        source = "<p>thread #{index}</p><%= ignored %>"
        Array.new(10) { Herb::Backend::Wasm.extract_html(source) }
      end
    end

    threads.each_with_index do |thread, index|
      source = "<p>thread #{index}</p><%= ignored %>"
      expected = Herb::Backend::PureRuby.extract_html(source)

      assert_equal [expected] * 10, thread.value
    end
  end

  test "rejects non-string input before crossing the Wasm boundary" do
    error = assert_raises(TypeError) { Herb::Backend::Wasm.extract_html(Object.new) }

    assert_match(/expected String/, error.message)
  end

  test "parses a literal document into the existing Ruby AST classes" do
    result = Herb::Backend::Wasm.parse("hello", html: false)
    document = result.value
    literal = document.children.fetch(0)

    assert_instance_of Herb::ParseResult, result
    assert_instance_of Herb::AST::DocumentNode, document
    assert_instance_of Herb::AST::LiteralNode, literal
    assert_equal "hello", literal.content
    assert_equal({ line: 1, column: 0 }, document.location.start.to_hash)
    assert_equal({ line: 1, column: 5 }, document.location.end.to_hash)
    assert_equal document.location.to_hash, literal.location.to_hash
    assert_empty result.errors
    assert_equal false, result.options.html

    empty = Herb::Backend::Wasm.parse("", html: false)
    assert_empty empty.value.children
    assert_equal({ line: 1, column: 0 }, empty.value.location.start.to_hash)
    assert_equal empty.value.location.start.to_hash, empty.value.location.end.to_hash
  end

  test "matches native AST results for generated field shapes" do
    native_contracts = {
      "hello <%= user.name %>" => "889737a7c7c621f6ecc59bc16a4c76e992da062bda5476d3b69732e11dcc9c88",
      "<% if admin? %>yes<% else %>no<% end %>" => "1a2a845c71aafee1c9bd47ef7775cfe0be6ca234af3b4f2ff427f7c3b8de0657",
      "<% if admin? then %>yes<% end %>" => "93558c67ef95c161321da5ea384c83e5ff0b0c4f0d170e91c85324f412f1e9c0",
      "<% users.each do |user| %><%= user.name %><% end %>" => "1146a2faba422f87eb68dd7b4c3317388940e9b66e35bd017bc1c27d1379926d",
    }

    native_contracts.each do |source, expected_digest|
      result = Herb::Backend::Wasm.parse(source, html: false)
      actual_digest = Digest::SHA256.hexdigest(JSON.generate(result.value.to_hash))

      assert_equal expected_digest, actual_digest, source
    end
  end

  test "matches native diagnostics" do
    native_contracts = {
      "<% if admin? %>yes" => "5d67e9c034173caa37c21a4d3512d98a548efdcb18d788fd5f71625c4887f46d",
      "<%= ( %>" => "7d3d495022b57c348b60f9c8e8ed4aca542ba2abb9fa9bce8b994ba7a197d08c",
      "<% end %>" => "29a0a323d0439ab0b5afd10cc93e901fb1d84ed4bfceaf879a74b350f59ef88b",
    }

    native_contracts.each do |source, expected_digest|
      result = Herb::Backend::Wasm.parse(source, html: false)
      payload = {
        error_count: result.error_count,
        errors: result.errors.map(&:to_hash),
        value: result.value.to_hash,
      }
      actual_digest = Digest::SHA256.hexdigest(JSON.generate(payload))

      assert_equal expected_digest, actual_digest, source
    end
  end

  test "matches native HTML parsing" do
    native_contracts = {
      "<div class=\"greeting\"><span>Hello</span><br></div>" =>
        "eb6d45d38a41ac7c98411c77e9d9ea2d6624823b94be5aa32f79876a3afbb51c",
      "<div><span></div>" => "4f9b0e30c7d8a3a15e871acc67fde64342acf0c73c04a1f32ccf5ba307a54ba2",
    }

    native_contracts.each do |source, expected_digest|
      result = Herb::Backend::Wasm.parse(source)
      payload = {
        error_count: result.error_count,
        errors: result.errors.map(&:to_hash),
        value: result.value.to_hash,
      }
      actual_digest = Digest::SHA256.hexdigest(JSON.generate(payload))

      assert_equal expected_digest, actual_digest, source
      assert result.options.html
    end
  end

  test "transports parser options used by libherb" do
    native_contracts = {
      ["<%graphql query { user { id } } %>", { html: false, erb_openers: ["graphql"] }] =>
        "1f0ce6477a5fb43343a2f7c94f2776f161663f5a3ad604cf7974be380878aa62",
      ["<ul><li>one<li>two</ul>", { strict: false }] =>
        "fcd6bbee7f45144146c888ae3707f9ba0a6111b16f55459bd9bbe6bbdeb59def",
      ["<Dialog.Button>OK</Dialog.Button>", { dot_notation_tags: true }] =>
        "a8906e49d8097c2254ac1aa5093809801c59fd591d4ee8676f12172627b4130f",
      ["<% [1].each do |item| %><%= item %><% end %>", { html: false, iteration_nodes: true }] =>
        "d72ccffec8ea97fd81c5708741e8f069eef2624a8f244a36ce1bee5c5b11bad7",
      ["<div class=\"x\">hi</div>", { track_locations: false }] =>
        "d8384c7bd04bb19dbe8459810a3f3db030b84727df890d155242e2fcf13c16bd",
      ["<div>", { track_locations: false }] =>
        "a0c50e6a09afec7a8861f4d7a9a66d73cecf624f085edeb8c8b72b00baf15c42",
    }

    native_contracts.each do |(source, options), expected_digest|
      result = Herb::Backend::Wasm.parse(source, **options)
      payload = {
        error_count: result.error_count,
        errors: result.errors.map(&:to_hash),
        value: result.value.to_hash,
      }
      actual_digest = Digest::SHA256.hexdigest(JSON.generate(payload))

      assert_equal expected_digest, actual_digest, "#{source} with #{options.inspect}"
    end
  end

  test "matches native Prism serialization" do
    source = "<%= user.name %>"
    contracts = [
      [{ prism_program: true }, :value, "a7b1cb18b084b02c7fc70ebb2fc9ca80b80283c45372ccdf7e3a11978a5ea16b", Prism::ProgramNode],
      [{ prism_nodes: true }, :child, "7cfb30898c3a79cdfe5b3b79a5ddba1d770ac9027a710db0f012a93cc8fe3bb6", Prism::CallNode]
    ]

    contracts.each do |options, target, expected_digest, expected_class|
      result = Herb::Backend::Wasm.parse(source, **options)
      node = target == :value ? result.value : result.value.children.fetch(0)
      serialized = node.prism_node

      assert_equal expected_digest, Digest::SHA256.hexdigest(serialized)
      assert_equal Encoding::BINARY, serialized.encoding
      assert_predicate serialized, :frozen?
      assert_instance_of expected_class, node.deserialized_prism_node
    end
  end

  test "rejects malformed generated AST data" do
    unknown_node = [999, 1, 0, 1, 0, 0].pack("L<*")
    node_error = assert_raises(RuntimeError) do
      Herb::Backend::Wasm::ASTCodec.decode_node(Herb::Backend::Wasm::PayloadReader.new(unknown_node))
    end

    assert_match(/unsupported Herb WebAssembly node type 999/, node_error.message)

    string_error = assert_raises(RuntimeError) do
      Herb::Backend::Wasm::ASTCodec.decode_string(Herb::Backend::Wasm::PayloadReader.new([2].pack("L<")))
    end

    assert_match(/invalid Herb WebAssembly string marker 2/, string_error.message)

    prism_error = assert_raises(RuntimeError) do
      Herb::Backend::Wasm::ASTCodec.decode_prism(Herb::Backend::Wasm::PayloadReader.new([2].pack("L<")))
    end

    assert_match(/invalid Herb WebAssembly Prism marker 2/, prism_error.message)
  end

  test "keeps unsupported arena statistics explicit" do
    error = assert_raises(NotImplementedError) do
      Herb::Backend::Wasm.parse("hello", arena_stats: true)
    end

    assert_match(/arena allocation statistics/, error.message)
  end
end
