# frozen_string_literal: true
# typed: true

require_relative "prism_version"

module Herb
  module JavaGemSpecification
    module_function

    #: (Gem::Specification) -> Gem::Specification
    def build(base_specification)
      specification = base_specification.dup
      specification.platform = Gem::Platform::JAVA
      specification.extensions = []
      specification.add_runtime_dependency("prism", "= #{PRISM_VERSION}")
      specification
    end
  end
end
