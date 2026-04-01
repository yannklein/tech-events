require './app'
require 'sinatra/activerecord/rake'
require 'irb'

task :fetch_event do
  require_relative 'app'
  fetch_event
end

desc 'Open an interactive console with database access'
task :c do
  ARGV.clear  # Prevent Rake from misinterpreting IRB arguments
  puts 'Starting interactive console...'
  IRB.start
end
