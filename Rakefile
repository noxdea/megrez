# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/testtask"

Rake::TestTask.new(:test) do |test|
  test.libs << "lib" << "test"
  test.pattern = "test/**/*_test.rb"
end

desc "Measure performance (BUDGET=1 enables assertions)"
task :bench do
  Dir["bench/*.rb"].sort.each { |path| ruby path }
end

task default: :test
