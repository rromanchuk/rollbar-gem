require 'net/https'
require 'socket'
require 'thread'
require 'uri'
require 'multi_json'

begin
  require 'securerandom'
rescue LoadError
end

require 'rollbar/version'
require 'rollbar/configuration'
require 'rollbar/request_data_extractor'
require 'rollbar/exception_reporter'
require 'rollbar/active_record_extension' if defined?(ActiveRecord)
require 'rollbar/util'
require 'rollbar/railtie' if defined?(Rails)

unless ''.respond_to? :encode
  require 'iconv'
end

module Rollbar
  MAX_PAYLOAD_SIZE = 128 * 1024 #128kb
  ATTACHMENT_CLASSES = %w[
    ActionDispatch::Http::UploadedFile
    Rack::Multipart::UploadedFile
  ].freeze
  
  class Notifier
    attr_accessor :configuration
    
    def initialize(parent_notifier = nil, payload_options = nil)
      if parent_notifier
        @configuration = parent_notifier.configuration.clone
        
        if payload_options
          configure do |config|
            Rollbar::Util::deep_merge(config.payload_options, payload_options)
          end
        end
      end
    end

    # Similar to configure below, but used only internally within the gem
    # to configure it without initializing any of the third party hooks
    def preconfigure
      yield(configuration)
    end

    def configure
      # if configuration.enabled has not been set yet (is still 'nil'), set to true.
      if configuration.enabled.nil?
        configuration.enabled = true
      end
      yield(configuration)

      require_hooks
    end

    def reconfigure
      @configuration = Configuration.new
      @configuration.enabled = true
      yield(configuration)
    end

    def unconfigure
      @configuration = nil
    end
    
    def configuration
      @configuration ||= Configuration.new
    end
    
    def scope(options = {})
      Notifier.new self, options
    end
    
    # Sends a report to Rollbar.
    #
    # Accepts any number of arguments. The last String argument will become
    # the message or description of the report. The last Exception argument
    # will become the associated exception for the report. The last hash
    # argument will be used as the extra data for the report.
    #
    # @example
    #   begin
    #     foo = bar
    #   rescue => e
    #     Rollbar.log(e)
    #   end
    #
    # @example
    #   Rollbar.log('This is a simple log message')
    #
    # @example
    #   Rollbar.log(e, 'This is a description of the exception')
    # 
    def log(level, *args)
      return 'disabled' unless configuration.enabled
      
      message = nil
      exception = nil
      extra = nil
      
      args.each do |arg|
        if arg.is_a?(String)
          message = arg
        elsif arg.is_a?(Exception)
          exception = arg
        elsif arg.is_a?(Hash)
          extra = arg
        end
      end
      
      if exception and ignored?(exception)
        return 'ignored'
      end
      
      begin
        report(level, message, exception, extra)
      rescue Exception => e
        report_internal_error(e)
        'error'
      end
    end
    
    # See log() above
    def debug(*args)
      log('debug', *args)
    end
    
    # See log() above
    def info(*args)
      log('info', *args)
    end
    
    # See log() above
    def warn(*args)
      log('warning', *args)
    end
    
    # See log() above
    def warning(*args)
      log('warning', *args)
    end
    
    # See log() above
    def error(*args)
      log('error', *args)
    end
    
    # See log() above
    def critical(*args)
      log('critical', *args)
    end
    
    def process_payload(payload)
      if configuration.write_to_file
        if configuration.use_async
          @file_semaphore.synchronize {
            write_payload(payload)
          }
        else
          write_payload(payload)
        end
      else
        send_payload(payload)
      end
    end
    
    # Turns off reporting for the given block.
    #
    # @example
    #   Rollbar.silenced { raise }
    #
    # @yield Block which exceptions won't be reported.
    def silenced
      begin
        yield
      rescue => e
        e.instance_variable_set(:@_rollbar_do_not_report, true)
        raise
      end
    end
    
    # Provided for backwards compatibility
    def report_exception(exception, request_data = nil, person_data = nil, level = 'error')
      log_warning('[Rollbar] report_exception() has been deprecated, please use log() or one of the level functions')
      notifier = notifier_for_request_data(request_data, person_data)
      notifier.log(level, exception)
    end
    
    # Provided for backwards compatibility
    def report_message(message, level = 'info', extra_data = {})
      log_warning('[Rollbar] report_message() has been deprecated, please use log() or one of the level functions')
      log(level, message, extra_data)
    end
    
    # Provided for backwards compatibility
    def report_message_with_request(message, level = 'info', request_data = nil, person_data = nil, extra_data = {})
      log_warning('[Rollbar] report_message_with_request() has been deprecated, please use log() or one of the level functions')
      notifier = notifier_for_request_data(request_data, person_data)
      notifier.log(level, message, extra_data)
    end
    
    private
    
    def notifier_for_request_data(request_data, person_data)
      if request_data || person_data
        scope({
          :request => request_data || {},
          :person => person_data || {}
        })
      else
        self
      end
    end

    def require_hooks()
      if defined?(Delayed) && defined?(Delayed::Worker) && configuration.delayed_job_enabled
        require 'rollbar/delayed_job'
        Rollbar::Delayed::wrap_worker
      end

      require 'rollbar/sidekiq' if defined?(Sidekiq)
      require 'rollbar/goalie' if defined?(Goalie)
      require 'rollbar/rack' if defined?(Rack)
      require 'rollbar/rake' if defined?(Rake)
      require 'rollbar/better_errors' if defined?(BetterErrors)
    end
    
    def ignored?(exception)
      if filtered_level(exception) == 'ignore'
        return true
      end

      if exception.instance_variable_get(:@_rollbar_do_not_report)
        return true
      end

      false
    end
    
    def filtered_level(exception)
      filter = configuration.exception_level_filters[exception.class.name]
      if filter.respond_to?(:call)
        filter.call(exception)
      else
        filter
      end
    end
    
    def get_payload_json(payload)
      enforce_valid_utf8(payload[:data])
      scrub_payload(payload[:data])
      
      result = MultiJson.dump(payload)
      
      # Try to truncate strings in the payload a few times if the payload is too big
      original_size = result.bytesize
      if original_size > MAX_PAYLOAD_SIZE
        thresholds = [1024, 512, 256, 128]
        thresholds.each_with_index do |threshold, i|
          new_payload = payload.clone
          
          truncate_payload(new_payload, threshold)
          
          result = MultiJson.dump(new_payload)
          
          if result.bytesize <= MAX_PAYLOAD_SIZE
            break
          elsif i == thresholds.length - 1
            final_size = result.bytesize
            send_failsafe("Could not send payload due to it being too large after truncating attempts. Original size: #{original_size} Final size: #{final_size}", nil)
            log_error "[Rollbar] Payload too large to be sent: #{MultiJson.dump(payload)}"
            return 'error'
          end
        end
      end
      
      result
    end
    
    def report(level, message, exception, extra)
      unless message or exception or extra
        log_error "[Rollbar] Tried to send a report with no message, exception or extra data."
        return 'error'
      end
      
      payload = build_payload(level, message, exception, extra)
      evaluate_payload(payload[:data])
      
      if payload[:data][:person]
        person_id = payload[:data][:person][configuration.person_id_method.to_sym]
        return 'ignored' if configuration.ignored_person_ids.include?(person_id)
      end
      
      result = get_payload_json(payload)
      schedule_payload(result)
      
      data = payload[:data]
      log_instance_link(data)
      
      Rollbar._last_report = data
      
      data
    end
    
    # Reports an internal error in the Rollbar library. This will be reported within the configured
    # Rollbar project. We'll first attempt to provide a report including the exception traceback.
    # If that fails, we'll fall back to a more static failsafe response.
    def report_internal_error(exception)
      log_error "[Rollbar] Reporting internal error encountered while sending data to Rollbar."

      begin
        payload = build_payload('error', nil, exception, {:internal => true})
      rescue => e
        send_failsafe("build_payload in exception_data", e)
        return
      end
      
      result = MultiJson.dump(payload)

      begin
        process_payload(result)
      rescue => e
        send_failsafe("error in process_payload", e)
        return
      end

      begin
        log_instance_link(payload[:data])
      rescue => e
        send_failsafe("error logging instance link", e)
        return
      end
    end
    
    ## Payload building functions
    
    def build_payload(level, message, exception, extra)
      environment = configuration.environment
      
      if environment.nil? || environment.empty?
        environment = 'unspecified'
      end
      
      data = {
        :timestamp => Time.now.to_i,
        :environment => environment,
        :level => level,
        :language => 'ruby',
        :framework => configuration.framework,
        :server => server_data,
        :notifier => {
          :name => 'rollbar-gem',
          :version => VERSION
        }
      }
      
      body = build_payload_body(message, exception, extra)
      
      data[:body] = body
      
      if configuration.project_gem_paths
        data[:project_package_paths] = configuration.project_gem_paths
      end

      if configuration.code_version
        data[:code_version] = configuration.code_version
      end

      if defined?(SecureRandom) and SecureRandom.respond_to?(:uuid)
        data[:uuid] = SecureRandom.uuid
      end
      
      Rollbar::Util::deep_merge(data, configuration.payload_options)
      
      {
        :access_token => configuration.access_token,
        :data => data
      }
    end
    
    def build_payload_body(message, exception, extra)
      unless configuration.custom_data_method.nil?
        custom = Rollbar::Util::deep_copy(configuration.custom_data_method.call)
        extra = Rollbar::Util::deep_merge(custom, extra || {})
      end
  
      if exception
        build_payload_body_exception(message, exception, extra)
      else
        build_payload_body_message(message, extra)
      end
    end
    
    def build_payload_body_exception(message, exception, extra)
      # parse backtrace
      if exception.backtrace.respond_to?( :map )
        frames = exception.backtrace.map { |frame|
          # parse the line
          match = frame.match(/(.*):(\d+)(?::in `([^']+)')?/)
          if match
            { :filename => match[1], :lineno => match[2].to_i, :method => match[3] }
          else
            { :filename => "<unknown>", :lineno => 0, :method => frame }
          end
        }
        # reverse so that the order is as rollbar expects
        frames.reverse!
      else
        frames = []
      end

      body = {
        :trace => {
          :frames => frames,
          :exception => {
            :class => exception.class.name,
            :message => exception.message
          }
        }
      }
      
      if message
        body[:trace][:exception][:description] = message
      end
      
      if extra
        body[:trace][:extra] = extra
      end
      
      body
    end
    
    def build_payload_body_message(message, extra)
      result = {:body => message || 'Empty message'}
      
      if extra
        result[:extra] = extra
      end
      
      {:message => result}
    end
    
    def server_data
      data = {
        :host => Socket.gethostname
      }
      data[:root] = configuration.root.to_s if configuration.root
      data[:branch] = configuration.branch if configuration.branch

      data
    end
    
    # Walks the entire payload and replaces callable values with
    # their results
    def evaluate_payload(payload)
      evaluator = Proc.new do |key, value|
        result = value
        
        if value.respond_to? :call
          begin
            result = value.call
          rescue
            log_error "[Rollbar] Error while evaluating callable in payload for key #{key}"
            result = nil
          end
        end
        
        result
      end
      
      Rollbar::Util::iterate_and_update_hash(payload, evaluator)
    end
    
    # Walks the entire payload and replaces values with asterisks
    # for keys that are part of the sensetive params list
    def scrub_payload(payload)
      @sensitive_params_regexp ||= Regexp.new(configuration.scrub_fields.map do |val|
        Regexp.escape(val.to_s).to_s
      end.join('|'), true)
      
      scrubber = Proc.new do |key, value|
        if @sensitive_params_regexp =~ key.to_s
          '*' * (value.length rescue 8)
        elsif ATTACHMENT_CLASSES.include?(value.class.name)
          {
            :content_type => value.content_type,
            :original_filename => value.original_filename,
            :size => value.tempfile.size
          } rescue 'Uploaded file'
        elsif value.is_a?(IO)
          'IO'
        else
          value
        end
      end
      
      Rollbar::Util::iterate_and_update_hash(payload, scrubber)
    end
    
    def enforce_valid_utf8(payload)
      normalizer = Proc.new do |value|
        if value.is_a?(String)
          if value.respond_to? :encode
            value.encode('UTF-8', 'binary', :invalid => :replace, :undef => :replace, :replace => '')
          else
            ::Iconv.conv('UTF-8//IGNORE', 'UTF-8', value)
          end
        else
          value
        end
      end

      Rollbar::Util::iterate_and_update(payload, normalizer)
    end
    
    # Walks the entire payload and truncates string values that
    # are longer than the byte_threshold
    def truncate_payload(payload, byte_threshold)
      truncator = Proc.new do |value|
        if value.is_a?(String) and value.bytesize > byte_threshold
          Rollbar::Util::truncate(value, byte_threshold)
        else
          value
        end
      end
      
      Rollbar::Util::iterate_and_update(payload, truncator)
    end
    
    ## Delivery functions
    
    def schedule_payload(payload)
      log_info '[Rollbar] Scheduling payload'

      if configuration.use_async
        unless configuration.async_handler
          configuration.async_handler = method(:default_async_handler)
        end

        if configuration.write_to_file
          unless @file_semaphore
            @file_semaphore = Mutex.new
          end
        end

        configuration.async_handler.call(payload)
      else
        process_payload(payload)
      end
    end
    
    def send_payload(payload)
      log_info '[Rollbar] Sending payload'

      if configuration.use_eventmachine
        send_payload_using_eventmachine(payload)
        return
      end
      
      uri = URI.parse(configuration.endpoint)
      http = Net::HTTP.new(uri.host, uri.port)
      http.read_timeout = configuration.request_timeout

      if uri.scheme == 'https'
        http.use_ssl = true
        http.verify_mode = OpenSSL::SSL::VERIFY_NONE
      end

      request = Net::HTTP::Post.new(uri.request_uri)
      request.body = payload
      request.add_field('X-Rollbar-Access-Token', configuration.access_token)
      response = http.request(request)
      
      if response.code == '200'
        log_info '[Rollbar] Success'
      else
        log_warning "[Rollbar] Got unexpected status code from Rollbar api: #{response.code}"
        log_info "[Rollbar] Response: #{response.body}"
      end
    end

    def write_payload(payload)
      log_info '[Rollbar] Writing payload to file'

      begin
        unless @file
          filepath = configuration.filepath || 'reports.rollbar'
          @file = File.open(filepath, "a")
        end

        @file.puts payload
        @file.flush
        log_info "[Rollbar] Success"
      rescue IOError => e
        log_error "[Rollbar] Error opening/writing to file: #{e}"
      end
    end

    def send_failsafe(message, exception)
      log_error "[Rollbar] Sending failsafe response due to #{message}."
      if exception
        begin
          log_error "[Rollbar] #{exception.class.name}: #{exception}"
        rescue => e
        end
      end

      config = configuration
      environment = config.environment

      failsafe_payload = <<-eos
      {"access_token": "#{config.access_token}",
       "data": {
         "level": "error",
         "environment": "#{config.environment}",
         "body": { "message": { "body": "Failsafe from rollbar-gem: #{message}" } },
         "notifier": { "name": "rollbar-gem", "version": "#{VERSION}" },
         "internal": true,
         "failsafe": true
       }
      }
      eos

      begin
        schedule_payload(failsafe_payload)
      rescue => e
        log_error "[Rollbar] Error sending failsafe : #{e}"
      end
    end

    def default_async_handler(payload)
      if defined?(GirlFriday)
        unless @queue
          @queue = GirlFriday::WorkQueue.new(nil, :size => 5) do |payload|
            process_payload(payload)
          end
        end

        @queue.push(payload)
      else
        log_warning '[Rollbar] girl_friday not found to handle async call, falling back to Thread'
        Thread.new { process_payload(payload) }
      end
    end
    
    ## Logging
    
    def log_instance_link(data)
      if data[:uuid]
        log_info "[Rollbar] Details: #{configuration.web_base}/instance/uuid?uuid=#{data[:uuid]} (only available if report was successful)"
      end
    end
    
    def logger
      # init if not set
      unless configuration.logger
        configuration.logger = configuration.default_logger.call
      end
      configuration.logger
    end
    
    def log_error(message)
      begin
        logger.error message
      rescue
        puts "[Rollbar] Error logging error:"
        puts "[Rollbar] #{message}"
      end
    end

    def log_info(message)
      begin
        logger.info message
      rescue
        puts "[Rollbar] Error logging info:"
        puts "[Rollbar] #{message}"
      end
    end

    def log_warning(message)
      begin
        logger.warn message
      rescue
        puts "[Rollbar] Error logging warning:"
        puts "[Rollbar] #{message}"
      end
    end

    def log_debug(message)
      begin
        logger.debug message
      rescue
        puts "[Rollbar] Error logging debug:"
        puts "[Rollbar] #{message}"
      end
    end
  end
  
  @@notifier = Notifier.new
  
  class << self
    def method_missing(meth, *args, &block)
      notifier = nil
      
      if Thread.current[:_rollbar_notifier]
        notifier = Thread.current[:_rollbar_notifier]
      else
        notifier = @@notifier
      end
      
      #if notifier.respond_to? meth
        notifier.send(meth, *args, &block)
      #else
      #  super
      #end
    end
    
    def _notifier
      @@notifier
    end
    
    def _last_report
      @@last_report
    end
    
    def _last_report=(last_report)
      @@last_report = last_report
    end
  end
end
