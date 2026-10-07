# frozen_string_literal: true

source "https://rubygems.org"

require_relative "lib/herb/prism_version"

gemspec

gem "prism", github: "ruby/prism", tag: "v#{Herb::PRISM_VERSION}"

gem "actionview", "~> 8.1", require: "action_view"
gem "benchmark"
gem "cruise", path: "../cruise"
gem "css_inline", path: "../css-inline/bindings/ruby"
gem "difftastic", path: "../difftastic-ruby"
gem "digest", "~> 3.2"
gem "erubi"
gem "ffi", "~> 1.17", platforms: :jruby
gem "irb", "~> 1.18"
gem "lightningcss", path: "../lightningcss-ruby"
gem "lz_string"
gem "maxitest", "~> 6.0"
gem "minitest-difftastic", "~> 0.2"
gem "nokogiri", "~> 1.19"
gem "rake", "~> 13.4"
gem "rake-compiler", "~> 1.3"
gem "rake-compiler-dock", "~> 1.12"
gem "rbs", "~> 4.2"
gem "rbs-inline", "~> 0.14"
gem "reactionview", github: "marcoroth/reactionview", branch: "herb-v0.11"
gem "reline", "~> 0.7"
gem "rubocop", "~> 1.72"
gem "rubocop-performance", "~> 1.26.0"
gem "steep", "~> 2.1"
gem "turbo-rails", "~> 2.0", require: false
gem "webrick", "~> 1.9", require: false
gem "websocket", "~> 1.2"

install_if -> { RUBY_ENGINE != "jruby" } do
  gem "charm"
  gem "oxc", "~> 0.149.0"
  gem "rolldown", "~> 1.2"
  gem "sorbet"
  gem "yerba", "~> 0.9"
end
