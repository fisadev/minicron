require 'active_record'
require 'parse-cron'
require 'minicron/hub/models/schedule'
require 'minicron/hub/models/execution'
require 'minicron/alert'

module Minicron
  # Used to monitor the executions in the database and look for any failures
  # or missed executions based on the schedules minicron knows about
  class Monitor
    def initialize
      @active = false

      # Kill the thread when exceptions arne't caught, TODO: should this be removed?
      Thread.abort_on_exception = true
    end

    # Establishes a database connection
    def setup_db
      case Minicron.config['database']['type']
      when 'mysql'
        # Establish a database connection
        ActiveRecord::Base.establish_connection({
          :adapter => 'mysql2',
          :host => Minicron.config['database']['host'],
          :database => Minicron.config['database']['database'],
          :username => Minicron.config['database']['username'],
          :password => Minicron.config['database']['password']
        })
      else
        raise Exception, "The database #{Minicron.config['database']['type']} is not supported"
      end
    end

    # What to do when a cron didn't run when it was expected to do
    #
    # @param schedule [Minicron::Hub::Schedule] a schedule instance
    # @param expected_at [DateTime] when the schedule was expected to execute
    def handle_missed_schedule(schedule, expected_at)
      alert = Minicron::Alert.new

      Minicron.config['alerts'].each do |medium, value|
        # Check if the medium is enabled and alert hasn't already been sent
        if value['enabled'] && !alert.sent?('miss', schedule.id, expected_at, medium)
          alert.send(
            :schedule => schedule,
            :kind => 'miss',
            :expected_at => expected_at,
            :medium => medium
          )
        end
      end
    end

    # Starts the execution monitor in a new thread
    def start!
      # Activate the monitor
      @active = true

      # Establish a database connection
      setup_db

      # Start a thread for the monitor
      @thread = Thread.new do
        # While the monitor is active run it in a loop ~every second
        while @active do
          # Get all the schedules
          schedules = Minicron::Hub::Schedule.all

          # Loop every schedule we know about
          schedules.each do |schedule|
            # Parse the cron expression
            cron = CronParser.new(schedule.formatted)

            # Find the time the cron was last expected to run
            expected_at = cron.last(Time.now.utc)

            # We need to wait until after a minute past the expected run time
            if Time.now.utc > (expected_at + 60)
              # Check if this execution was created inside a minute window
              # starting when it was expected to run
              check = Minicron::Hub::Execution.exists?(
                :created_at => expected_at..(expected_at + 60),
                :job_id => schedule.job_id
              )

              # If the check failed
              unless check
                handle_missed_schedule(schedule, expected_at)
              end
            end
          end

          sleep 60
        end
      end
    end

    # Stops the execution monitor
    def stop!
      @active = false
      @thread.join
    end

    # Is the execution monitor running?
    def running?
      @active
    end
  end
end
