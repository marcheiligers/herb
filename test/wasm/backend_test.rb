# frozen_string_literal: true

require_relative "../test_helper"

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

  test "keeps the incomplete parsing surface explicit" do
    error = assert_raises(NotImplementedError) { Herb::Backend::Wasm.parse("hello") }

    assert_match(/currently parses only with html: false/, error.message)
  end
end
