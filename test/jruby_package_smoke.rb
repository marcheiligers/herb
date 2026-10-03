# frozen_string_literal: true

require "herb"

raise "expected JRuby, got #{RUBY_ENGINE}" unless RUBY_ENGINE == "jruby"

herb_specification = Gem.loaded_specs.fetch("herb")
raise "expected the java gem, got #{herb_specification.platform}" unless herb_specification.platform == Gem::Platform::JAVA

source = '<% users.each do |user| %><%= render "user", user: user %><% end %>'
result = Herb.parse(source, iteration_nodes: true, render_nodes: true, prism_program: true)
raise result.errors.inspect unless result.success?

iteration = result.value.children.first
raise "expected an iteration node" unless iteration.is_a?(Herb::AST::ERBIterationBlockNode)
raise "expected a render node" unless iteration.body.first.is_a?(Herb::AST::ERBRenderNode)
raise "expected a Prism program" unless result.value.deserialized_prism_node.is_a?(Prism::ProgramNode)

invalid = Herb.parse("<%= user. %>")
raise "expected a Ruby diagnostic" unless invalid.errors.first.is_a?(Herb::Errors::RubyParseError)

puts "JRuby package smoke test passed with Herb #{Herb::VERSION} and Prism #{Prism::VERSION}"
