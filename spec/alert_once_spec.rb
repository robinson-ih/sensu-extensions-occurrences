require "sensu/extensions/alert_once"
require "sensu/logger"
require 'webmock/rspec'
require File.join(File.dirname(__FILE__), "helpers")

describe "Sensu::Extension::Alertonce" do
  include Helpers

  before do
    @extension = Sensu::Extension::Alertonce.new
    @extension.settings = Hash.new
    @extension.settings["alert_once"] = {
        :hostname => "testsensuapi",
        :port => 4567,
        :ssl => false
    }
    @extension.instance_variable_set("@logger", Sensu::Logger.get(:log_level => :fatal))
    @extension.post_init
  end

  it "Default filter handlers, wait for occurenses, no hit to sensu API until severity change" do
    # Not stubing Http

    async_wrapper do
      event = event_template
      event[:check][:occurrences] = 3
      event[:occurrences] = 1
      @extension.safe_run(event) do |output, status|
        expect(status).to eq(0) # By default filter handlers
        event[:check][:occurrences] = 3
        @extension.safe_run(event) do |output, status|
          expect(status).to eq(0) # wait for occurrences
            async_done
        end
      end
    end
  end

  it "can notify new alerts, based on occurrences if no previous notification sent" do
    # No previous alerts - No data in stash
    stub_request(:get, /http:\/\/testsensuapi:4567/).to_return(status: 404)

    # Allow stash to register new alerts
    stub_request(:post, /http:\/\/testsensuapi:4567/).to_return(status: 200)
    
    async_wrapper do
      event = event_template
      event[:check][:occurrences] = 3
      @extension.safe_run(event) do |output, status|
        expect(status).to eq(0) # wait for occurrences
        event[:occurrences] = 4
        @extension.safe_run(event) do |output, status|
          expect(status).to eq(1) # Create new alert
          async_done
        end
      end
    end
  end

  it "can skip new alerts, based on occurrences if has previous notification sent with same severity" do
    # Has previous alerts - data in stash
    stub_request(:get, /http:\/\/testsensuapi:4567/).to_return(status: 200, body: "{\"status\":1}")
   
    async_wrapper do
      event = event_template
      event[:check][:occurrences] = 3
      @extension.safe_run(event) do |output, status|
        expect(status).to eq(0) # wait for occurrences
        event[:occurrences] = 4
        @extension.safe_run(event) do |output, status|
          expect(status).to eq(0) # Already notified
          async_done
        end
      end
    end
  end

  it "can create new alerts for different severity, if has previous notification with differ in severity" do
    # Has previous alerts - data in stash
    stub_request(:get, /http:\/\/testsensuapi:4567/).to_return(status: 202, body: "{\"status\":2}")

    # Allow stash to update status
    stub_request(:post, /http:\/\/testsensuapi:4567/).to_return(status: 200)
    
    async_wrapper do
      event = event_template
      event[:check][:occurrences] = 3
      @extension.safe_run(event) do |output, status|
        expect(status).to eq(0) # wait for occurrences
        event[:occurrences] = 4
        event[:status] = 1
        @extension.safe_run(event) do |output, status|
          expect(status).to eq(1) # Create alert for new severity
          async_done
        end
      end
    end
  end

  it "can create new alerts for resolve, if has previous notification" do
    # Has previous alerts - data in stash
    stub_request(:get, /http:\/\/testsensuapi:4567/).to_return(status: 200, body: "{\"status\":2}")

    # Allow stash to delete stash
    stub_request(:delete, /http:\/\/testsensuapi:4567/).to_return(status: 200)
    
    async_wrapper do
      event = event_template
      @extension.safe_run(event) do |output, status|
        expect(status).to eq(0) # wait for occurrences
        event[:occurrences] = 1
        event[:status] = 0
        event[:action] = :resolve
        @extension.safe_run(event) do |output, status|
          expect(status).to eq(1) # Create alert for new severity
          async_done
        end
      end
    end
  end

  it "can skip alerts for resolve, if no previous notification" do
    # No Previous alert - No data in stash
    stub_request(:get, /http:\/\/testsensuapi:4567/).to_return(status: 404)
    
    async_wrapper do
      event = event_template
      @extension.safe_run(event) do |output, status|
        expect(status).to eq(0) # wait for occurrences
        event[:occurrences] = 1
        event[:status] = 0
        event[:action] = :resolve
        @extension.safe_run(event) do |output, status|
          expect(status).to eq(0) # Ignore resolve as it may flap
          async_done
        end
      end
    end
  end

  it "Testing timeout Exception handling" do
    # Simulate timeout
    stub_request(:get, /http:\/\/testsensuapi:4567/).to_timeout.then.#to_return(status: 404)
    to_return(status: 200, body: "{\"status\":2}")
    stub_request(:delete, /http:\/\/testsensuapi:4567/).to_return(status: 200)

    #WebMock.allow_net_connect!

    async_wrapper do
      event = event_template
      @extension.safe_run(event) do |output, status|
        event[:occurrences] = 1
        event[:status] = 0
        event[:action] = :resolve
        @extension.safe_run(event) do |output, status|
          expect(status).to eq(1) # Create alert
          async_done
        end
          filter = @extension.instance_variable_get("@filters")["alert_once"]
          retries = @extension.instance_variable_get("@retries")
          expect(filter['retry_interval']).to eq(5)
          expect(filter['retry_request']).to eq(3)
          #expect(logger).to receive(:info).with("alert_once: successfully initialized filter: hostname: testsensuapi, port: 4567, uri: http://testsensuapi:4567")
          #expect(logger).to receive(:info).with("Retrying Stash API")
      end
    end
  end
end
