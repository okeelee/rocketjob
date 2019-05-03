require 'concurrent'
require 'pathname'
require 'fileutils'
module RocketJob
  class DirmonEntry
    include Plugins::Document
    include Plugins::StateMachine

    # The default archive directory that is used when the job being queued does not respond
    # to #upload, and does not have an `archive_directory` specified in this entry
    class_attribute :default_archive_directory
    self.default_archive_directory = 'archive'.freeze

    store_in collection: 'rocket_job.dirmon_entries'

    # User defined name used to identify this DirmonEntry in the Web Interface.
    field :name, type: String

    # Pattern for finding files
    #
    # Example: All files ending in '.csv' in the input_files/process1 directory
    #   input_files/process1/*.csv
    #
    # Example: All files in the input_files/process1 directory and all sub-directories
    #   input_files/process2/**/*
    #
    # Example: All files in the input_files/process2 directory with .csv or .txt extensions
    #   input_files/process2/*.{csv,txt}
    #
    # For details on valid pattern values, see: http://ruby-doc.org/core-2.2.2/Dir.html#method-c-glob
    #
    # Note
    # - If there is no '*' in the pattern then an exact filename match is expected
    # - The pattern is not validated to ensure the path exists, it will be validated against the
    #   `whitelist_paths` when processed by DirmonJob
    field :pattern, type: String

    # Job to enqueue for processing for every file that matches the pattern
    #
    # Example:
    #   "ProcessItJob"
    field :job_class_name, type: String

    # Any job properties to set
    #
    # Example, override the default job priority:
    #   { priority: 45 }
    field :properties, type: Hash, default: {}

    # Archive directory to move files to when processed to prevent processing the
    # file again.
    #
    # If supplied, the file will be moved to this directory before the job is started
    # If the file was in a sub-directory, the corresponding sub-directory will
    # be created in the archive directory.
    field :archive_directory, type: String, default: default_archive_directory

    # If this DirmonEntry is in the failed state, exception contains the cause
    embeds_one :exception, class_name: 'RocketJob::JobException'

    # The maximum number of files that should ever match during a single poll of the pattern.
    #
    # Too many files could be as a result of an invalid pattern specification.
    # Exceeding this number will result in an exception being logged in a failed Dirmon instance.
    # Dirmon processing will continue with new instances.
    # TODO: Implement max_hits
    # field :max_hits, type: Integer, default: 100

    #
    # Read-only attributes
    #

    # Current state, as set by the state machine. Do not modify directly.
    field :state, type: Symbol, default: :pending

    # Unique index on pattern to help prevent two entries from scanning the same files
    index({pattern: 1}, background: true, unique: true)

    before_validation :strip_whitespace
    validates_presence_of :pattern, :job_class_name, :archive_directory
    validate :job_is_a_rocket_job
    validate :job_has_properties

    # State Machine events and transitions
    #
    # :pending -> :enabled  -> :disabled
    #                       -> :failed
    #          -> :failed   -> :active
    #                       -> :disabled
    #          -> :disabled -> :active
    aasm column: :state, whiny_persistence: true do
      # DirmonEntry is `pending` until it is approved
      state :pending, initial: true

      # DirmonEntry is Enabled and will be included by DirmonJob
      state :enabled

      # DirmonEntry failed during processing and requires manual intervention
      # See the exception for the reason for failing this entry
      # For example: access denied, whitelist_path security violation, etc.
      state :failed

      # DirmonEntry has been manually disabled
      state :disabled

      event :enable do
        transitions from: :pending, to: :enabled
        transitions from: :disabled, to: :enabled
      end

      event :disable do
        transitions from: :enabled, to: :disabled
        transitions from: :failed, to: :disabled
      end

      event :fail, before: :set_exception do
        transitions from: :enabled, to: :failed
      end
    end

    # Security Settings
    #
    # A whitelist of paths from which to process files.
    # This prevents accidental or malicious `pattern`s from processing files from anywhere
    # in the system that the user under which Dirmon is running can access.
    #
    # All resolved `pattern`s must start with one of the whitelisted path, otherwise they will be rejected
    #
    # Note:
    # - If no whitelist paths have been added, then a whitelist check is _not_ performed
    # - Relative paths can be used, but are not considered safe since they can be manipulated
    # - These paths should be assigned in an initializer and not editable via the Web UI to ensure
    #   that they are not tampered with
    #
    # Default: [] ==> Do not enforce whitelists
    #
    # Returns [Array<String>] a copy of the whitelisted paths
    def self.get_whitelist_paths
      whitelist_paths.dup
    end

    # Add a path to the whitelist
    # Raises: Errno::ENOENT: No such file or directory
    def self.add_whitelist_path(path)
      # Confirms that path exists
      path = Pathname.new(path).realpath.to_s
      whitelist_paths << path
      whitelist_paths.uniq!
      path
    end

    # Deletes a path from the whitelist paths
    # Raises: Errno::ENOENT: No such file or directory
    def self.delete_whitelist_path(path)
      # Confirms that path exists
      path = Pathname.new(path).realpath.to_s
      whitelist_paths.delete(path)
      whitelist_paths.uniq!
      path
    end

    # Returns [Hash<String:Integer>] of the number of dirmon entries in each state.
    # Note: If there are no workers in that particular state then the hash will not have a value for it.
    #
    # Example dirmon entries in every state:
    #   RocketJob::DirmonEntry.counts_by_state
    #   # => {
    #          :pending => 1,
    #          :enabled => 37,
    #          :failed => 1,
    #          :disabled => 3
    #        }
    #
    # Example no dirmon entries:
    #   RocketJob::Job.counts_by_state
    #   # => {}
    def self.counts_by_state
      counts = {}
      collection.aggregate([{'$group' => {_id: '$state', count: {'$sum' => 1}}}]).each do |result|
        counts[result['_id'].to_sym] = result['count']
      end
      counts
    end

    # Passes each filename [Pathname] found that matches the pattern into the supplied block
    def each
      SemanticLogger.named_tagged(dirmon_entry: id.to_s) do
        # Case insensitive filename matching
        Pathname.glob(pattern, File::FNM_CASEFOLD).each do |pathname|
          next if pathname.directory?
          pathname = begin
            pathname.realpath
          rescue Errno::ENOENT
            logger.warn("Unable to expand the realpath for #{pathname.inspect}. Skipping file.")
            next
          end

          file_name = pathname.to_s

          # Skip archive directories
          next if file_name.include?(self.class.default_archive_directory)

          # Security check?
          if whitelist_paths.size.positive? && whitelist_paths.none? { |whitepath| file_name.to_s.start_with?(whitepath) }
            logger.error "Skipping file: #{file_name} since it is not in any of the whitelisted paths: #{whitelist_paths.join(', ')}"
            next
          end

          # File must be writable so it can be removed after processing
          unless pathname.writable?
            logger.error "Skipping file: #{file_name} since it is not writable by the current user. Must be able to delete/move the file after queueing the job"
            next
          end
          yield(pathname)
        end
      end
    end

    # Set exception information for this DirmonEntry and fail it
    def set_exception(worker_name, exc_or_message)
      if exc_or_message.is_a?(Exception)
        self.exception        = JobException.from_exception(exc_or_message)
        exception.worker_name = worker_name
      else
        build_exception(
          class_name:  'RocketJob::DirmonEntryException',
          message:     exc_or_message,
          backtrace:   [],
          worker_name: worker_name
        )
      end
    end

    # Returns the Job to be created.
    def job_class
      return if job_class_name.nil?
      job_class_name.constantize
    rescue NameError
      nil
    end

    # Archives the file and kicks off a proxy job to upload the file.
    def later(pathname)
      job_id             = BSON::ObjectId.new
      archived_file_name = archive_file(job_id, pathname)

      job = RocketJob::Jobs::UploadFileJob.create!(
        job_class_name:     job_class_name,
        properties:         properties,
        description:        "#{name}: #{pathname.basename}",
        upload_file_name:   archived_file_name.to_s,
        original_file_name: pathname.to_s,
        job_id:             job_id
      )

      logger.info(
        message: 'Created RocketJob::Jobs::UploadFileJob',
        payload: {
          dirmon_entry_name:  name,
          upload_file_name:   archived_file_name.to_s,
          original_file_name: pathname.to_s,
          job_class_name:     job_class_name,
          job_id:             job_id.to_s,
          upload_job_id:      job.id.to_s
        }
      )
      job
    end

    private

    # strip whitespaces from all variables that reference paths or patterns
    def strip_whitespace
      self.pattern           = pattern.strip unless pattern.nil?
      self.archive_directory = archive_directory.strip unless archive_directory.nil?
    end

    class_attribute :whitelist_paths
    self.whitelist_paths = Concurrent::Array.new

    # Move the file to the archive directory
    #
    # The archived file name is prefixed with the job id
    #
    # Returns [String] the fully qualified archived file name
    #
    # Note:
    # - Works across partitions when the file and the archive are on different partitions
    def archive_file(job_id, pathname)
      target_path = archive_pathname(pathname)
      target_path.mkpath
      target_file_name = target_path.join("#{job_id}_#{pathname.basename}")
      # In case the file is being moved across partitions
      FileUtils.move(pathname.to_s, target_file_name.to_s)
      target_file_name.to_s
    end

    # Returns [Pathname] to the archive directory, and creates it if it does not exist.
    #
    # If `archive_directory` is a relative path, it is appended to the `file_pathname`.
    # If `archive_directory` is an absolute path, it is returned as-is.
    def archive_pathname(file_pathname)
      path = Pathname.new(archive_directory)
      path = file_pathname.dirname.join(archive_directory) if path.relative?

      begin
        path.mkpath unless path.exist?
      rescue Errno::ENOENT => exc
        raise(Errno::ENOENT, "DirmonJob failed to create archive directory: #{path}, #{exc.message}")
      end
      path.realpath
    end

    # Validates job_class is a Rocket Job
    def job_is_a_rocket_job
      klass = job_class
      return if job_class_name.nil? || klass&.ancestors&.include?(RocketJob::Job)
      errors.add(:job_class_name, "Job #{job_class_name} must be defined and inherit from RocketJob::Job")
    end

    # Does the job have all the supplied properties
    def job_has_properties
      klass = job_class
      return unless klass

      properties.each_pair do |k, _v|
        next if klass.public_method_defined?("#{k}=".to_sym)
        errors.add(:properties, "Unknown Property: Attempted to set a value for #{k.inspect} which is not allowed on the job #{job_class_name}")
      end
    end
  end
end
