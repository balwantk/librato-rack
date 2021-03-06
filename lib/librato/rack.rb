require 'thread'
require 'librato/rack/network_modes'
require 'librato/metrics'

module Librato
  extend SingleForwardable
  def_delegators :tracker, :increment, :measure, :timing, :group

  def self.register_tracker(tracker)
    @tracker = tracker
  end

  def self.tracker
    @tracker ||= Librato::Rack::Tracker.new(Librato::Rack::Configuration.new)
  end
end

module Librato
  # Middleware for rack applications. Installs tracking hearbeat for
  # metric submission and tracks performance metrics.
  #
  # @example A basic rack app
  #   require 'rack'
  #   require 'librato-rack'
  #
  #   app = Rack::Builder.app do
  #     use Librato::Rack
  #     run lambda { |env| [200, {"Content-Type" => 'text/html'}, ["Hello!"]] }
  #   end
  #
  class Rack
    attr_reader :config, :tracker

    def initialize(app, options={})
      if options.respond_to?(:tracker) # old-style single argument
        config = options
      else
        config = options.fetch(:config, Configuration.new)
      end
      @app, @config = app, config
      @tracker = Tracker.new(@config)
      Librato.register_tracker(@tracker) # create global reference
    end

    def call(env)
      check_log_output(env)
      @tracker.check_worker
      record_header_metrics(env)
      response, duration = process_request(env)
      record_request_metrics(response.first, duration)
      response
    end

    private

    def check_log_output(env)
      return if @log_target
      if in_heroku_env?
        tracker.on_heroku = true
        default = ::Logger.new($stdout)
      else
        default = env['rack.errors'] || $stderr
      end
      config.log_target ||= default
      @log_target = config.log_target
    end

    def in_heroku_env?
      # don't have any custom http vars anymore, check if hostname is UUID
      Socket.gethostname =~ /[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}/i
    end

    def process_request(env)
      time = Time.now
      begin
        response = @app.call(env)
      rescue Exception => e
        record_exception(e)
        raise
      end
      duration = (Time.now - time) * 1000.0
      [response, duration]
    end

    def record_header_metrics(env)
      # TODO: track generalized queue wait
    end

    def record_request_metrics(status, duration)
      return if config.disable_rack_metrics
      tracker.group 'rack.request' do |group|
        group.increment 'total'
        group.timing    'time', duration
        group.increment 'slow' if duration > 200.0

        group.group 'status' do |s|
          s.increment status
          s.increment "#{status.to_s[0]}xx"

          s.timing "#{status}.time", duration
          s.timing "#{status.to_s[0]}xx.time", duration
        end
      end
    end

    def record_exception(exception)
      return if config.disable_rack_metrics
      tracker.increment 'rack.request.exceptions'
    end

  end
end

require 'librato/collector'
require 'librato/rack/configuration'
require 'librato/rack/errors'
require 'librato/rack/logger'
require 'librato/rack/tracker'
require 'librato/rack/validating_queue'
require 'librato/rack/version'
require 'librato/rack/worker'
