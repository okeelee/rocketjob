# encoding: UTF-8

# Worker behavior for a job
module RocketJob
  module Concerns
    module Worker
      def self.included(base)
        base.extend ClassMethods
        base.class_eval do
          @rocket_job_defaults = nil
        end
      end

      module ClassMethods
        # Returns [Job] after queue-ing it for processing
        def later(method, *args, &block)
          if RocketJob::Config.inline_mode
            now(method, *args, &block)
          else
            job = build(method, *args, &block)
            job.save!
            job
          end
        end

        # Create a job and process it immediately in-line by this thread
        def now(method, *args, &block)
          job    = build(method, *args, &block)
          worker = RocketJob::Worker.new(name: 'inline')
          worker.started
          job.start
          while job.running? && !job.work(worker)
          end
          job
        end

        # Build a Rocket Job instance
        #
        # Note:
        #  - #save! must be called on the return job instance if it needs to be
        #    queued for processing.
        #  - If data is uploaded into the job instance before saving, and is then
        #    discarded, call #cleanup! to clear out any partially uploaded data
        def build(method, *args, &block)
          job = new(arguments: args, perform_method: method.to_sym)
          @rocket_job_defaults.call(job) if @rocket_job_defaults
          block.call(job) if block
          job
        end

        # Method to be performed later
        def perform_later(*args, &block)
          later(:perform, *args, &block)
        end

        # Method to be performed later
        def perform_build(*args, &block)
          build(:perform, *args, &block)
        end

        # Method to be performed now
        def perform_now(*args, &block)
          now(:perform, *args, &block)
        end

        # Define job defaults
        def rocket_job(&block)
          @rocket_job_defaults = block
          self
        end

        # Returns the next job to work on in priority based order
        # Returns nil if there are currently no queued jobs, or processing batch jobs
        #   with records that require processing
        #
        # Parameters
        #   worker_name [String]
        #     Name of the worker that will be processing this job
        #
        #   skip_job_ids [Array<BSON::ObjectId>]
        #     Job ids to exclude when looking for the next job
        #
        # Note:
        #   If a job is in queued state it will be started
        def next_job(worker_name, skip_job_ids = nil)
          query        = {
            '$and' => [
              {
                '$or' => [
                  {'state' => 'queued'}, # Jobs
                  {'state' => 'running', 'sub_state' => :processing} # Slices
                ]
              },
              {
                '$or' => [
                  {run_at: {'$exists' => false}},
                  {run_at: {'$lte' => Time.now}}
                ]
              }
            ]
          }
          query['_id'] = {'$nin' => skip_job_ids} if skip_job_ids && skip_job_ids.size > 0

          while (doc = find_and_modify(
            query:  query,
            sort:   [['priority', 'asc'], ['created_at', 'asc']],
            update: {'$set' => {'worker_name' => worker_name, 'state' => 'running'}}
          ))
            job = load(doc)
            if job.running?
              return job
            else
              if job.expired?
                job.destroy
                logger.info "Destroyed expired job #{job.class.name}, id:#{job.id}"
              else
                # Also update in-memory state and run call-backs
                job.start
                job.set(started_at: job.started_at)
                return job
              end
            end
          end
        end

      end

      # Works on this job
      #
      # Returns [true|false] whether this job should be excluded from the next lookup
      #
      # If an exception is thrown the job is marked as failed and the exception
      # is set in the job itself.
      #
      # Thread-safe, can be called by multiple threads at the same time
      def work(worker)
        raise(ArgumentError, 'Job must be started before calling #work') unless running?
        begin
          # before_perform
          call_method(perform_method, arguments, event: :before, log_level: log_level)

          # perform
          ret = call_method(perform_method, arguments, log_level: log_level)
          if self.collect_output?
            self.result = (ret.is_a?(Hash) || ret.is_a?(BSON::OrderedHash)) ? ret : {result: ret}
          end

          # after_perform
          call_method(perform_method, arguments, event: :after, log_level: log_level)

          complete!
        rescue StandardError => exc
          fail!(worker.name, exc) unless failed?
          logger.error("Exception running #{self.class.name}##{perform_method}", exc)
          raise exc if RocketJob::Config.inline_mode
        end
        false
      end

      protected

      # Calls a method on this job, if it is defined
      # Adds the event name to the method call if supplied
      #
      # Returns [Object] the result of calling the method
      #
      # Parameters
      #   method [Symbol]
      #     The method to call on this job
      #
      #   arguments [Array]
      #     Arguments to pass to the method call
      #
      #   Options:
      #     event: [Symbol]
      #       Any one of: :before, :after
      #       Default: None, just calls the method itself
      #
      #     log_level: [Symbol]
      #       Log level to apply to silence logging during the call
      #       Default: nil ( no change )
      #
      def call_method(method, arguments, options = {})
        options   = options.dup
        event     = options.delete(:event)
        log_level = options.delete(:log_level)
        raise(ArgumentError, "Unknown #{self.class.name}#call_method options: #{options.inspect}") if options.size > 0

        the_method = event.nil? ? method : "#{event}_#{method}".to_sym
        if respond_to?(the_method)
          method_name = "#{self.class.name}##{the_method}"
          logger.info "Start #{method_name}"
          logger.benchmark_info(
            "Completed #{method_name}",
            metric:             "rocketjob/#{self.class.name.underscore}/#{the_method}",
            log_exception:      :full,
            on_exception_level: :error,
            silence:            log_level
          ) do
            send(the_method, *arguments)
          end
        end
      end

    end
  end
end