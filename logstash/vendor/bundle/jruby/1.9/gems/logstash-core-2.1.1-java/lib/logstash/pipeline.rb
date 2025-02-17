# encoding: utf-8
require "thread"
require "stud/interval"
require "concurrent"
require "logstash/namespace"
require "logstash/errors"
require "logstash/event"
require "logstash/config/file"
require "logstash/filters/base"
require "logstash/inputs/base"
require "logstash/outputs/base"
require "logstash/config/cpu_core_strategy"
require "logstash/util/defaults_printer"
require "logstash/shutdown_controller"

module LogStash; class Pipeline
  attr_reader :inputs, :filters, :outputs, :input_to_filter, :filter_to_output

  def initialize(configstr)
    @logger = Cabin::Channel.get(LogStash)

    @inputs = nil
    @filters = nil
    @outputs = nil

    grammar = LogStashConfigParser.new
    @config = grammar.parse(configstr)

    if @config.nil?
      raise LogStash::ConfigurationError, grammar.failure_reason
    end
    # This will compile the config to ruby and evaluate the resulting code.
    # The code will initialize all the plugins and define the
    # filter and output methods.
    code = @config.compile
    # The config code is hard to represent as a log message...
    # So just print it.
    @logger.debug? && @logger.debug("Compiled pipeline code:\n#{code}")
    begin
      eval(code)
    rescue => e
      raise
    end

    @input_to_filter = SizedQueue.new(20)
    # if no filters, pipe inputs directly to outputs
    @filter_to_output = filters? ? SizedQueue.new(20) : @input_to_filter

    @settings = {
      "default-filter-workers" => LogStash::Config::CpuCoreStrategy.fifty_percent
    }

    # @ready requires thread safety since it is typically polled from outside the pipeline thread
    @ready = Concurrent::AtomicBoolean.new(false)
    @input_threads = []
    @filter_threads = []
  end # def initialize

  def ready?
    @ready.value
  end

  def configure(setting, value)
    @settings[setting] = value
  end

  def safe_filter_worker_count
    default = @settings["default-filter-workers"]
    thread_count = @settings["filter-workers"] #override from args "-w 8" or config
    safe_filters, unsafe_filters = @filters.partition(&:threadsafe?)
    if unsafe_filters.any?
      plugins = unsafe_filters.collect { |f| f.class.config_name }
      case thread_count
      when nil
        # user did not specify a worker thread count
        # warn if the default is multiple
        @logger.warn("Defaulting filter worker threads to 1 because there are some filters that might not work with multiple worker threads",
          :count_was => default, :filters => plugins) if default > 1
        1 # can't allow the default value to propagate if there are unsafe filters
      when 0, 1
        1
      else
        @logger.warn("Warning: Manual override - there are filters that might not work with multiple worker threads",
          :worker_threads => thread_count, :filters => plugins)
        thread_count # allow user to force this even if there are unsafe filters
      end
    else
      thread_count || default
    end
  end

  def filters?
    return @filters.any?
  end

  def run
    @logger.terminal(LogStash::Util::DefaultsPrinter.print(@settings))

    begin
      start_inputs
      start_filters if filters?
      start_outputs
    ensure
      # it is important to garantee @ready to be true after the startup sequence has been completed
      # to potentially unblock the shutdown method which may be waiting on @ready to proceed
      @ready.make_true
    end

    @logger.info("Pipeline started")
    @logger.terminal("Logstash startup completed")

    wait_inputs

    if filters?
      shutdown_filters
      wait_filters
      flush_filters_to_output!(:final => true)
    end

    shutdown_outputs
    wait_outputs

    @logger.info("Pipeline shutdown complete.")
    @logger.terminal("Logstash shutdown completed")

    # exit code
    return 0
  end # def run

  def wait_inputs
    @input_threads.each(&:join)
  end

  def shutdown_filters
    @flusher_thread.kill
    @input_to_filter.push(LogStash::SHUTDOWN)
  end

  def wait_filters
    @filter_threads.each(&:join)
  end

  def shutdown_outputs
    # nothing, filters will do this
    @filter_to_output.push(LogStash::SHUTDOWN)
  end

  def wait_outputs
    # Wait for the outputs to stop
    @output_threads.each(&:join)
  end

  def start_inputs
    moreinputs = []
    @inputs.each do |input|
      if input.threadable && input.threads > 1
        (input.threads - 1).times do |i|
          moreinputs << input.clone
        end
      end
    end
    @inputs += moreinputs

    @inputs.each do |input|
      input.register
      start_input(input)
    end
  end

  def start_filters
    @filters.each(&:register)
    # dynamically get thread count based on filter threadsafety
    # moved this test to here to allow for future config reloading
    to_start = safe_filter_worker_count
    @filter_threads = to_start.times.collect do |i|
      Thread.new do
        LogStash::Util.set_thread_name("|filterworker.#{i}")
        filterworker
      end
    end
    actually_started = @filter_threads.select(&:alive?).size
    msg = "Worker threads expected: #{to_start}, worker threads started: #{actually_started}"
    if actually_started < to_start
      @logger.warn(msg)
    else
      @logger.info(msg)
    end
    @flusher_thread = Thread.new { Stud.interval(5) { @input_to_filter.push(LogStash::FLUSH) } }
  end

  def start_outputs
    @outputs.each(&:register)
    @output_threads = [
      Thread.new { outputworker }
    ]
  end

  def start_input(plugin)
    @input_threads << Thread.new { inputworker(plugin) }
  end

  def inputworker(plugin)
    LogStash::Util.set_thread_name("<#{plugin.class.config_name}")
    LogStash::Util.set_thread_plugin(plugin)
    begin
      plugin.run(@input_to_filter)
    rescue => e
      # if plugin is stopping, ignore uncatched exceptions and exit worker
      if plugin.stop?
        @logger.debug("Input plugin raised exception during shutdown, ignoring it.",
                      :plugin => plugin.class.config_name, :exception => e,
                      :backtrace => e.backtrace)
        return
      end

      # otherwise, report error and restart
      if @logger.debug?
        @logger.error(I18n.t("logstash.pipeline.worker-error-debug",
                             :plugin => plugin.inspect, :error => e.to_s,
                             :exception => e.class,
                             :stacktrace => e.backtrace.join("\n")))
      else
        @logger.error(I18n.t("logstash.pipeline.worker-error",
                             :plugin => plugin.inspect, :error => e))
      end

      # Assuming the failure that caused this exception is transient,
      # let's sleep for a bit and execute #run again
      sleep(1)
      retry
    ensure
      plugin.do_close
    end
  end # def inputworker

  def filterworker
    begin
      while true
        event = @input_to_filter.pop

        case event
        when LogStash::Event
          # filter_func returns all filtered events, including cancelled ones
          filter_func(event).each { |e| @filter_to_output.push(e) unless e.cancelled? }
        when LogStash::FlushEvent
          # handle filter flushing here so that non threadsafe filters (thus only running one filterworker)
          # don't have to deal with thread safety implementing the flush method
          flush_filters_to_output!
        when LogStash::ShutdownEvent
          # pass it down to any other filterworker and stop this worker
          @input_to_filter.push(event)
          break
        end
      end
    rescue Exception => e
      # Plugins authors should manage their own exceptions in the plugin code
      # but if an exception is raised up to the worker thread they are considered
      # fatal and logstash will not recover from this situation.
      #
      # Users need to check their configuration or see if there is a bug in the
      # plugin.
      @logger.error("Exception in filterworker, the pipeline stopped processing new events, please check your filter configuration and restart Logstash.",
                    "exception" => e, "backtrace" => e.backtrace)
      raise
    ensure
      @filters.each(&:do_close)
    end
  end # def filterworker

  def outputworker
    LogStash::Util.set_thread_name(">output")
    @outputs.each(&:worker_setup)

    while true
      event = @filter_to_output.pop
      break if event == LogStash::SHUTDOWN
      output_func(event)
      LogStash::Util.set_thread_plugin(nil)
    end
  ensure
    @outputs.each do |output|
      output.worker_plugins.each(&:do_close)
    end
  end # def outputworker

  # initiate the pipeline shutdown sequence
  # this method is intended to be called from outside the pipeline thread
  # @param before_stop [Proc] code block called before performing stop operation on input plugins
  def shutdown(&before_stop)
    # shutdown can only start once the pipeline has completed its startup.
    # avoid potential race conditoon between the startup sequence and this
    # shutdown method which can be called from another thread at any time
    sleep(0.1) while !ready?

    # TODO: should we also check against calling shutdown multiple times concurently?

    before_stop.call if block_given?

    @inputs.each(&:do_stop)
  end # def shutdown

  def plugin(plugin_type, name, *args)
    args << {} if args.empty?
    klass = LogStash::Plugin.lookup(plugin_type, name)
    return klass.new(*args)
  end

  # for backward compatibility in devutils for the rspec helpers, this method is not used
  # in the pipeline anymore.
  def filter(event, &block)
    # filter_func returns all filtered events, including cancelled ones
    filter_func(event).each { |e| block.call(e) }
  end

  # perform filters flush and yeild flushed event to the passed block
  # @param options [Hash]
  # @option options [Boolean] :final => true to signal a final shutdown flush
  def flush_filters(options = {}, &block)
    flushers = options[:final] ? @shutdown_flushers : @periodic_flushers

    flushers.each do |flusher|
      flusher.call(options, &block)
    end
  end

  # perform filters flush into the output queue
  # @param options [Hash]
  # @option options [Boolean] :final => true to signal a final shutdown flush
  def flush_filters_to_output!(options = {})
    flush_filters(options) do |event|
      unless event.cancelled?
        @logger.debug? and @logger.debug("Pushing flushed events", :event => event)
        @filter_to_output.push(event)
      end
    end
  end # flush_filters_to_output!

  def inflight_count
    data = {}
    total = 0

    input_to_filter = @input_to_filter.size
    total += input_to_filter
    filter_to_output = @filter_to_output.size
    total += filter_to_output

    data["input_to_filter"] = input_to_filter if input_to_filter > 0
    data["filter_to_output"] = filter_to_output if filter_to_output > 0

    output_worker_queues = []
    @outputs.each do |output|
      next unless output.worker_queue && output.worker_queue.size > 0
      plugin_info = output.debug_info
      size = output.worker_queue.size
      total += size
      plugin_info << size
      output_worker_queues << plugin_info
    end
    data["output_worker_queues"] = output_worker_queues unless output_worker_queues.empty?
    data["total"] = total
    data
  end

  def stalling_threads
    plugin_threads
     .reject {|t| t["blocked_on"] } # known begnin blocking statuses
     .each {|t| t.delete("backtrace") }
     .each {|t| t.delete("blocked_on") }
     .each {|t| t.delete("status") }
  end

  def plugin_threads
    input_threads = @input_threads.select {|t| t.alive? }.map {|t| thread_info(t) }
    filter_threads = @filter_threads.select {|t| t.alive? }.map {|t| thread_info(t) }
    output_threads = @output_threads.select {|t| t.alive? }.map {|t| thread_info(t) }
    output_worker_threads = @outputs.flat_map {|output| output.worker_threads }.map {|t| thread_info(t) }
    input_threads + filter_threads + output_threads + output_worker_threads
  end

  def thread_info(thread)
    LogStash::Util.thread_info(thread)
  end
end; end
