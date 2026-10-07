# frozen_string_literal: true

require_relative "../test_helper"

module Engine
  class RubyValidatorTest < Minitest::Spec
    test "accepts valid Ruby" do
      assert_empty Herb::Engine::RubyValidator.errors("def foo; end")
    end

    test "reports Prism diagnostics for invalid Ruby" do
      assert_equal [
        "unexpected end-of-input; expected a `)` to close the parameters (line 1)",
        "unexpected end-of-input, assuming it is closing the parent top level context (line 1)",
        "expected an `end` to close the `def` statement (line 1)"
      ], Herb::Engine::RubyValidator.errors("def foo(")
    end

    test "allows yield because templates execute inside a method" do
      assert_empty Herb::Engine::RubyValidator.errors("yield")
    end

    test "does not let an invalid yield hide other syntax errors" do
      errors = Herb::Engine::RubyValidator.errors("yield; def foo(")

      assert_equal 3, errors.length
      assert_match(/expected a `\)`/, errors.first)
    end
  end
end
