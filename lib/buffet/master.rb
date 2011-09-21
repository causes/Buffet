#!/usr/bin/env ruby

require 'drb'
require 'thread'
require 'socket'
require 'memoize'

module Buffet
  # The Buffet::Master class runs worker on all of the host machines 
  # (including itself), and then distributes the tests to the workers.
  # The workers request more tests after they finish their current tests.
  class Master 
    extend Memoize

    # This will initialize the server.
    def initialize(working_dir, hosts, status) 
      @ip = Settings.hostname # For druby
      @port = Settings.get["port"] + 1 # For druby
      @hosts = hosts # All host machines
      @stats = {:examples => 0, :failures => 0} # Failures and total test #.
      @lock = Mutex.new # Lock objects touched by several threads to avoid race.
      @failure_list = [] # Details of our failed test cases.
      @pass_list = [] # Our passed test cases.
      @working_dir = working_dir # Directory we clone and run tests in.
      @status = status

      # Get all tests.
      Dir.chdir(@working_dir) do
        @files = Dir["spec/**/*_spec.rb"].sort #This is specific to rspec.
        @files = @files[0..Settings.get['test_count'] - 1] if Settings.get['test_count']
      end
    end

    def next_file
      @lock.synchronize do
        @files_to_run.shift
      end
    end

    # These two methods are called on passes and fails, respectively.
    # TODO: This functionality should be moved into another class, I think.
    def example_passed(details)
      @lock.synchronize do
        @stats[:examples] += 1
        update_status
      end

      @pass_list.push({:description => details[:description]})
    end

    def example_failed(details)
      @lock.synchronize do
        @stats[:examples] += 1
        @stats[:failures] += 1

        backtrace ||= "No backtrace found."

        @failure_list.push(details)

        update_status
      end
    end

    def update_status
      new_status = (@stats.to_a.map {|keyvalue| "#{keyvalue[0].to_s}: #{keyvalue[1]}"}).join " "
      @status.set new_status, true
      @status.set @stats, false
    end

    def server_addr
      "druby://#{@ip}:#{@port}"
    end

    def start_service
      @drb_thread = Thread.new do
        DRb.start_service("druby://0.0.0.0:#{@port}", self)
        DRb.thread.join
      end
    end

    def stop_service
      DRb.stop_service
      @drb_thread.join
    end

    # This will start distributing specs. It blocks until the tests are complete.
    def run
      update_status

      Dir.chdir(@working_dir) do
        @files_to_run = @files.dup

        start_service
        @start_time = Time.now

        # Run worker on every host.
        threads = @hosts.map do |host|
          Thread.new do
            `ssh buffet@#{host} 'cd ~/#{Settings.root_dir_name}/working-directory; rvm use 1.8.7; RAILS_ENV=test bundle exec ruby ~/#{Settings.root_dir_name}/buffet/bin/buffet-worker #{server_addr}'`

            if $?.exitstatus != 0
              puts "Error on worker machine #{host}."
            end
          end
        end

        threads.each do |t|
          t.join
        end

        @end_time = Time.now
        stop_service
      end
      @status.set "Done. Final results:"
      results = ""
      @stats.each do |key, value|
        results += "#{key}: #{value}\n"
      end

      results += "\n"
      mins, secs = (@end_time - @start_time).divmod(60)
      results += "Buffet was consumed in %d mins %d secs\n" % [mins, secs]

      @status.set results
    end

    def failures
      @failure_list
    end

    def passes
      @pass_list
    end
  end
end
