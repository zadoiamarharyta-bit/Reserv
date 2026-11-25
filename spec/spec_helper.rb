ENV['RACK_ENV'] = 'test'

require 'rspec'
require 'rack/test'
require_relative '../app'

RSpec.configure do |config|
  config.include Rack::Test::Methods

  def app
    Sinatra::Application
  end

  config.before(:each) do
    FileUtils.rm_rf(DATA_DIR)
    FileUtils.mkdir_p(CACHE_DIR)
  end
end
