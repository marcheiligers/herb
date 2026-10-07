# frozen_string_literal: true

require_relative "../../test_helper"

module Engine
  class ExecutionDomainTest < Minitest::Spec
    test "is stable within a thread" do
      current = Herb::Engine::Runtime::ExecutionDomain.current

      assert_same current, Herb::Engine::Runtime::ExecutionDomain.current
    end

    test "stays the same across fibers" do
      current = Herb::Engine::Runtime::ExecutionDomain.current
      inside_fiber = Fiber.new { Herb::Engine::Runtime::ExecutionDomain.current }.resume

      assert_same current, inside_fiber
    end

    test "distinguishes threads" do
      current = Herb::Engine::Runtime::ExecutionDomain.current
      inside_thread = Thread.new { Herb::Engine::Runtime::ExecutionDomain.current }.value

      refute_same current, inside_thread
    end
  end
end
