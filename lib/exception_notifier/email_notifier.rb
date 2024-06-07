# frozen_string_literal: true

require 'active_support/core_ext/time'
require 'action_mailer'
require 'action_dispatch'
require 'pp'
require 'uri'
require 'json'
require 'net/http'

module ExceptionNotifier
  class EmailNotifier < BaseNotifier
    DEFAULT_OPTIONS = {
      sender_address: %("Exception Notifier" <exception.notifier@example.com>),
      exception_recipients: [],
      email_prefix: '[ERROR] ',
      email_format: :text,
      sections: %w[request session environment backtrace],
      background_sections: %w[backtrace data],
      verbose_subject: true,
      normalize_subject: false,
      include_controller_and_action_names_in_subject: true,
      delivery_method: nil,
      mailer_settings: nil,
      email_headers: {},
      mailer_parent: 'ActionMailer::Base',
      template_path: 'exception_notifier',
      deliver_with: nil,
      count_limit: 5, # default value send email only 5 times after key expires will send again send 5 times
      expires_in_stop_send: 30.minutes, # default value key expires in 30 minutes
      api_url: nil,
      api_key: nil,
    }.freeze

    module Mailer
      class MissingController
        def method_missing(*args, &block); end
      end

      def self.extended(base)
        base.class_eval do
          send(:include, ExceptionNotifier::BacktraceCleaner)

          # Append application view path to the ExceptionNotifier lookup context.
          append_view_path "#{File.dirname(__FILE__)}/views"

          def exception_notification(env, exception, options = {}, default_options = {})
            load_custom_views

            @env        = env
            @exception  = exception

            env_options = env['exception_notifier.options'] || {}
            @options    = default_options.merge(env_options).merge(options)

            @kontroller = env['action_controller.instance'] || MissingController.new
            @request    = ActionDispatch::Request.new(env)
            @backtrace  = exception.backtrace ? clean_backtrace(exception) : []
            @timestamp  = Time.current
            @sections   = @options[:sections]
            @data       = (env['exception_notifier.exception_data'] || {}).merge(options[:data] || {})
            @file_path_json  = ""
            @sections += %w[data] unless @data.empty?
            
            if count_send_email
              send_log_to_tracker
              compose_email
            end
          end

          def background_exception_notification(exception, options = {}, default_options = {})
            load_custom_views

            @exception = exception
            @options   = default_options.merge(options).symbolize_keys
            @backtrace = exception.backtrace || []
            @timestamp = Time.current
            @sections  = @options[:background_sections]
            @data      = options[:data] || {}
            @env = @kontroller = nil
            @sections += %w[data] unless @data.empty?
            
            if count_send_email
              send_log_to_tracker
              compose_email
            end
          end

          private

          # counting send email
    def data_log
      backtrace   = @backtrace.select{|x| !x.include?("lib/ruby/gems") && !x.include?("benchmark.rb")}
      line_error  = backtrace.first.split("/").last.gsub(Rails.root.to_s, "") rescue ""

      {
        count: 0,
        time: Time.now,
        subject: compose_subject,
        backtrace: backtrace,
        line_error: line_error,
      }
    end

    def count_send_email
      count = 0
      is_valid_send = false
      today = Time.now.to_date.to_s
      tmp_data_log = data_log

      log_folder = "#{Rails.root.to_s}/log/exception_notification"
      
      Dir.exists?(log_folder) || Dir.mkdir(log_folder)
      current_log_date = "#{log_folder}/#{today}"
      Dir.exists?(current_log_date) || Dir.mkdir(current_log_date)
      endcode = Base64.urlsafe_encode64 compose_subject
      current_log_file = "#{current_log_date}/#{endcode}.json"
      
      if File.exist?(current_log_file)
        json_file =  File.read(current_log_file)
        json_file = json_file.to_json
        last_time = File.ctime(current_log_file)   #=> Wed Apr 09 08:53:13 CDT 2003

        count = last_time < @options[:expires_in_stop_send].ago ? 0 : (count + 1)
        is_valid_send = count < @options[:count_limit]
        tmp_data_log[:count] = count
      else 
        is_valid_send = true
      end

      @file_path_json = current_log_file

      File.open(current_log_file,"w") do |f|
        f.write(tmp_data_log.to_json)
      end
      return is_valid_send
    end

    # Log Request headers for send to tracker
    def send_log_to_tracker
      if  @options[:api_url].present? &&  @options[:api_key].present?
        @file_path_json
      end
    end

          def compose_subject
            subject = @options[:email_prefix].to_s.dup
            subject << "(#{@options[:accumulated_errors_count]} times)" if @options[:accumulated_errors_count].to_i > 1
            subject << "#{@kontroller.controller_name}##{@kontroller.action_name}" if include_controller?
            subject << " (#{@exception.class})"
            subject << " #{@exception.message.inspect}" if @options[:verbose_subject]
            subject = EmailNotifier.normalize_digits(subject) if @options[:normalize_subject]
            subject.length > 120 ? subject[0...120] + '...' : subject
          end

          def include_controller?
            @kontroller && @options[:include_controller_and_action_names_in_subject]
          end

          def set_data_variables
            @data.each do |name, value|
              instance_variable_set("@#{name}", value)
            end
          end

          helper_method :inspect_object

          def truncate(string, max)
            string.length > max ? "#{string[0...max]}..." : string
          end

          def inspect_object(object)
            case object
            when Hash, Array
              truncate(object.inspect, 300)
            else
              object.to_s
            end
          end

          helper_method :safe_encode

          def safe_encode(value)
            value.encode('utf-8', invalid: :replace, undef: :replace, replace: '_')
          end

          def html_mail?
            @options[:email_format] == :html
          end

          def compose_email
            set_data_variables
            subject = compose_subject
            name = @env.nil? ? 'background_exception_notification' : 'exception_notification'
            exception_recipients = maybe_call(@options[:exception_recipients])

            headers = {
              delivery_method: @options[:delivery_method],
              to: exception_recipients,
              from: @options[:sender_address],
              subject: subject,
              template_name: name
            }.merge(@options[:email_headers])

            mail = mail(headers) do |format|
              format.text
              format.html if html_mail?
            end

            mail.delivery_method.settings.merge!(@options[:mailer_settings]) if @options[:mailer_settings]

            mail
          end

          def load_custom_views
            return unless defined?(Rails) && Rails.respond_to?(:root)

            prepend_view_path Rails.root.nil? ? 'app/views' : "#{Rails.root}/app/views"
          end

          def maybe_call(maybe_proc)
            maybe_proc.respond_to?(:call) ? maybe_proc.call : maybe_proc
          end
        end
      end
    end

    def initialize(options)
      super

      delivery_method = (options[:delivery_method] || :smtp)
      mailer_settings_key = "#{delivery_method}_settings".to_sym
      options[:mailer_settings] = options.delete(mailer_settings_key)

      @base_options = DEFAULT_OPTIONS.merge(options)
    end

    def call(exception, options = {})
      message = create_email(exception, options)

      message.send(base_options[:deliver_with] || default_deliver_with(message))
    end

    def create_email(exception, options = {})
      env = options[:env]

      send_notice(exception, options, nil, base_options) do |_, default_opts|
        if env.nil?
          mailer.background_exception_notification(exception, options, default_opts)
        else
          mailer.exception_notification(env, exception, options, default_opts)
        end
      end
    end

    def self.normalize_digits(string)
      string.gsub(/[0-9]+/, 'N')
    end

    private
  
    def mailer
      @mailer ||= Class.new(base_options[:mailer_parent].constantize).tap do |mailer|
        mailer.extend(EmailNotifier::Mailer)
        mailer.mailer_name = base_options[:template_path]
      end
    end

    def default_deliver_with(message)
      # FIXME: use `if Gem::Version.new(ActionMailer::VERSION::STRING) < Gem::Version.new('4.1')`
      message.respond_to?(:deliver_now) ? :deliver_now : :deliver
    end

  end
end