# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/herb/java_gem_specification"

class JavaGemSpecificationTest < Minitest::Spec
  test "builds a Java package without Herb's native extension" do
    base = Gem::Specification.load(File.expand_path("../herb.gemspec", __dir__))
    java = Herb::JavaGemSpecification.build(base)
    prism = java.runtime_dependencies.find { |dependency| dependency.name == "prism" }

    assert_equal Gem::Platform::JAVA, java.platform
    assert_empty java.extensions
    assert_equal "= #{Herb::PRISM_VERSION}", prism.requirement.to_s
    assert_equal ["ext/herb/extconf.rb"], base.extensions
    assert_empty base.runtime_dependencies
  end
end
