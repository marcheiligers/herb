# frozen_string_literal: true
# typed: true

module Herb
  class Engine
    module Runtime
      # Identifies the logical Ruby thread that owns runtime state. Thread variables cross Fiber
      # boundaries but not Thread or Ractor boundaries, including when JRuby backs a Fiber with a
      # different JVM thread.
      module ExecutionDomain
        KEY = :herb_engine_runtime_execution_domain #: Symbol

        class << self
          #: () -> Object
          def current
            Thread.current.thread_variable_get(KEY) || begin
              domain = Object.new.freeze
              Thread.current.thread_variable_set(KEY, domain)
              domain
            end
          end
        end
      end
    end
  end
end
