# frozen_string_literal: true
# typed: true

module Herb
  class Engine
    module RubyValidator
      class << self
        #: (String) -> Array[String]
        def errors(source)
          return native_errors(source) if defined?(::RubyVM::InstructionSequence)

          prism_errors(source)
        end

        private

        #: (String) -> Array[String]
        def native_errors(source)
          ::RubyVM::InstructionSequence.compile(source)

          []
        rescue SyntaxError => e
          prism_errors(source, fallback: e.message)
        end

        #: (String, ?fallback: String?) -> Array[String]
        def prism_errors(source, fallback: nil)
          require "prism"

          Prism.parse(source).errors.filter_map do |error|
            next if error.type == :invalid_yield

            "#{error.message} (line #{error.location.start_line})"
          end
        rescue LoadError
          raise unless fallback

          [fallback]
        end
      end
    end
  end
end
