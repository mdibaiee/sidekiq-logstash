module Sidekiq
  module Middleware
    module Server
      class LogstashLogging
        def call(_, job, _)
          started_at = Time.now.utc
          yield
          Sidekiq.logger.info log_job(job, started_at)
        rescue => exc
          begin
            Sidekiq.logger.warn log_job(job, started_at, exc)
          rescue => ex
            Sidekiq.logger.error 'Error logging the job execution!'
            Sidekiq.logger.error "Job: #{job}"
            Sidekiq.logger.error "Job Exception: #{exc}"
            Sidekiq.logger.error "Log Exception: #{ex}"
          end
          raise
        end

        def log_job(payload, started_at, exc = nil)
          # Create a copy of the payload using JSON
          # This should always be possible since Sidekiq store it in Redis
          payload = JSON.parse(JSON.unparse(payload))

          # Convert timestamps into Time instances
          %w( created_at enqueued_at retried_at failed_at completed_at ).each do |key|
            payload[key] = parse_time(payload[key]) if payload[key]
          end

          # Add process id params
          payload['pid'] = ::Process.pid
          payload['duration'] = elapsed(started_at)

          message = "#{payload['class']} JID-#{payload['jid']}"

          if exc
            payload['message'] = "#{message}: fail: #{payload['duration']} sec"
            payload['job_status'] = 'fail'
            payload['error_message'] = exc.message
            payload['error'] = exc.class
            payload['error_backtrace'] = %('#{exc.backtrace.join("\n")}')
          else
            payload['message'] = "#{message}: done: #{payload['duration']} sec"
            payload['job_status'] = 'done'
            payload['completed_at'] = Time.now.utc
          end

          # Merge custom_options to provide customization
          payload.merge!(call_custom_options(payload, exc)) if custom_options rescue nil

          # Filter sensitive parameters
          unless filter_args.empty?
            args_filter = Sidekiq::Logging::ArgumentFilter.new(filter_args)
            payload['args'].map! { |arg| args_filter.filter(arg) }
          end

          payload
        end

        def elapsed(start)
          (Time.now.utc - start).round(3)
        end

        def parse_time(timestamp)
          return timestamp if timestamp.is_a? Time
          timestamp.is_a?(Float) ?
              Time.at(timestamp).utc :
              Time.parse(timestamp)
        end

        def call_custom_options(payload, exc)
          custom_options.arity == 1 ?
              custom_options.call(payload) :
              custom_options.call(payload, exc)
        end

        def custom_options
          Sidekiq::Logstash.configuration.custom_options
        end

        def filter_args
          Sidekiq::Logstash.configuration.filter_args
        end
      end
    end
  end
end