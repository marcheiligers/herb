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
  end

  test "keeps the incomplete parsing surface explicit" do
    error = assert_raises(NotImplementedError) { Herb::Backend::Wasm.parse("hello") }

    assert_match(/currently parses only with html: false/, error.message)
  end
end
