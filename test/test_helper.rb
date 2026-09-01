ENV['RACK_ENV'] = 'test'

require 'minitest/autorun'
require 'rack/test'
require_relative '../webcam-resolver'

class ResolverTest < Minitest::Test
  include Rack::Test::Methods

  def app
    Sinatra::Application
  end
end
