# frozen_string_literal: true

# Try requiring sidekiq-cron to ensure it's loaded before the integration.
# If sidekiq-cron is not available, do nothing.
begin
  require "sidekiq-cron"
rescue LoadError
  return
end

module Sentry
  module Sidekiq
    module Cron
      module Job
        # Handles sidekiq-cron < 2.0.0
        def enque!(*)
          # make sure the current thread has a clean hub
          Sentry.clone_hub_to_current_thread

          Sentry.with_scope do |scope|
            Sentry.with_session_tracking do
              transaction = Sentry.start_transaction(op: "queue.sidekiq.cron", name: 'SidekiqCron/enqueue!')
              begin
                Sentry.get_current_scope.set_span(transaction)

                super

                transaction.set_status("ok")
              rescue
                transaction.set_status("internal_error")
                raise
              ensure
                if transaction
                  transaction.finish
                end
              end
            end
          end
        end

        # Handles newest changes in sidekiq-cron 2.0.0 when released.
        def enqueue!(*)
          # make sure the current thread has a clean hub
          Sentry.clone_hub_to_current_thread

          Sentry.with_scope do |scope|
            Sentry.with_session_tracking do
              super
            end
          end
        end


        def save
          # validation failed, do nothing
          return false unless super

          # fail gracefully if can't find class
          klass_const =
            begin
              ::Sidekiq::Cron::Support.constantize(klass.to_s)
            rescue NameError
              return true
            end

          # only patch if not explicitly included in job by user
          unless klass_const.send(:ancestors).include?(Sentry::Cron::MonitorCheckIns)
            klass_const.send(:include, Sentry::Cron::MonitorCheckIns)
            klass_const.send(:sentry_monitor_check_ins,
                             slug: name.to_s,
                             monitor_config: Sentry::Cron::MonitorConfig.from_crontab(parsed_cron.original))
          end

          true
        end
      end
    end
  end
end

Sentry.register_patch(:sidekiq_cron, Sentry::Sidekiq::Cron::Job, ::Sidekiq::Cron::Job)
