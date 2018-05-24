require "sensu/extension"
require 'uri'
require 'net/http'
require 'net/https'
require 'json'

module Sensu
  module Extension
    class Alertonce < Filter

       @@extension_name = "alert_once"

      def name
        @@extension_name
      end

      def description
        "Filter events using event occurrences & sensu stashes to store teh previous notification to reduce noise."
      end

      @@default_config = {
        :hostname       => "127.0.0.1",
        :port           => "4567",
        :ssl            => false
      }

      def create_config(name, defaults)
        if settings[name].nil?
          @logger.warn("No configuration for #{name} provided. Using default settings.")
        end
        config = defaults.merge(settings[name] || {})
        @logger.debug("Config for #{name} created: #{config}")
        # validate_config(name, config)

        hostname         = config[:hostname]
        port             = config[:port]
        ssl              = config[:ssl]
        ssl_ca_file      = config[:ssl_ca_file]
        ssl_verify       = if config.key?(:ssl_verify) then config[:ssl_verify] else true end
        protocol         = if ssl then "https" else "http" end
        username         = if config.key?(:username) then config[:username] else nil end
        password         = if config.key?(:password) then config[:password] else nil end
        channel_name     = if config.key?(:channel_name) then config[:channel_name] else 'notification' end
        retry_request    = if config.key?(:retry_request) then config[:retry_request] else 3 end
        retry_interval   = if config.key?(:retry_interval) then config[:retry_interval] else 5 end

        string = "#{protocol}://#{hostname}:#{port}"
        uri = URI(string)
        http = Net::HTTP::new(uri.host, uri.port)
        if ssl
          http.ssl_version = :TLSv1
          http.use_ssl = true
          http.verify_mode = if ssl_verify then OpenSSL::SSL::VERIFY_PEER else OpenSSL::SSL::VERIFY_NONE end
          http.ca_file = ssl_ca_file
        end

        @filters ||= Hash.new
        @filters[name] = {
          "http" => http,  
          "uri" => uri,
          "username" => username,
          "password" => password,
          "channel_name" => channel_name,
          "retry_request" => retry_request,
          "retry_interval" => retry_interval
        }

        @logger.info("#{name}: successfully initialized filter: hostname: #{hostname}, port: #{port}, uri: #{uri.to_s}")
        return config
      end

      def post_init
        main_config = create_config(@@extension_name, @@default_config)
      end

      # Convert a string value to an integer, or return nil if this
      # fails. Integer values are returned unchanged.
      #
      # @param x [String]
      # @return [Integer]
      def str2int(x)
        if x.is_a?(Integer)
          return x
        elsif x.is_a?(String)
          begin
            result = Integer(x)
          rescue
            result = nil
          end
        end
      end
        
      # Determine if an event occurrence count meets the user defined
      # requirements in the event check definition. Users can specify
      # a minimum number of `occurrences` before an event will be
      # passed to a handler. Users should specify a `sensu_stash` hash,
      # to store the previous notification.
      #
      # @param event [Hash]
      # @return [Array] containing filter output and status.
      def event_filtered?(event)
        #check = event[:check]
        #event = ::JSON.parse(event)
        occurrences = str2int(event[:check][:occurrences]) || 1

        if event[:action] == :resolve
          response = api_request('/stashes/' + @filters[name]['channel_name'] + '/' + event[:client][:name] + '/' + event[:check][:name], 'GET', event)
          if response.code == '200' # Already has notification
            api_request('/stashes/' + @filters[name]['channel_name'] + '/' + event[:client][:name] + '/' + event[:check][:name], 'DELETE', event) # Delete stash
            return ['Notify it Resolve the event', 1]
          else
            return ['Filter event due to flapping', 0]
          end
        else
          if event[:occurrences] > occurrences && [:create, :flapping].include?(event[:action])
            response = api_request('/stashes/' + @filters[name]['channel_name'] + '/' + event[:client][:name] + '/' + event[:check][:name], 'GET', event)
            if response.code == '200' # Already notified
              if ::JSON.parse(response.body)['status'] != event[:check][:status] # Update Severity status
                api_request('/stashes', 'POST', event)
                # Notify the updated status
                return ['Change in severity status', 1]
              end  
            else
            # Notify event
            api_request('/stashes', 'POST', event)
            return ['New notification alert', 1]
            end
          end
        end
        ['Can be filtered', 0]
      end

      def api_request(resource, method_name, event)
        filter = @filters[name]
        http = filter['http']
        # header = { 'Content-Type' => 'application/json' }
        body = { path: filter['channel_name'] + '/' + event[:client][:name] + '/' + event[:check][:name], content: { status: event[:check][:status] } }

        case method_name
        when 'GET'
          req =  Net::HTTP::Get.new(resource)
        when 'POST'
          req =  Net::HTTP::Post.new(resource)
        when 'DELETE'
          req =  Net::HTTP::Delete.new(resource)
        end
        req.body = body.to_json
        req.basic_auth(filter['username'], filter['password']) if filter['username'] && filter['password']

        retries = 0
        begin
          r = http.request(req)
          return r
        rescue StandardError => e
          logger.info("Retrying Stash API")
          sleep @filters[name]['retry_interval']
          retry if (retries += 1) < @filters[name]['retry_request']
          logger.error("Sensu stash error for #{event[:client][:name]}/#{event[:check][:name]} for status #{event[:check][:status]}")
          logger.error(e.message)
          logger.error(e.backtrace)
          logger.error("Http: #{http}, Body: #{body}, Method: #{method_name}")
        end
      end

      def run(event)
        yield event_filtered?(event)
      end
    end
  end
end
