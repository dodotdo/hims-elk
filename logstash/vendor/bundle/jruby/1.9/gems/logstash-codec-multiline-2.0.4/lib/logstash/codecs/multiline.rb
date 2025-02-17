# encoding: utf-8
require "logstash/codecs/base"
require "logstash/util/charset"
require "logstash/timestamp"

# The multiline codec will collapse multiline messages and merge them into a
# single event.
#
# The original goal of this codec was to allow joining of multiline messages
# from files into a single event. For example, joining Java exception and
# stacktrace messages into a single event.
#
# The config looks like this:
# [source,ruby]
#     input {
#       stdin {
#         codec => multiline {
#           pattern => "pattern, a regexp"
#           negate => "true" or "false"
#           what => "previous" or "next"
#         }
#       }
#     }
#
# The `pattern` should match what you believe to be an indicator that the field
# is part of a multi-line event.
#
# The `what` must be `previous` or `next` and indicates the relation
# to the multi-line event.
#
# The `negate` can be `true` or `false` (defaults to `false`). If `true`, a
# message not matching the pattern will constitute a match of the multiline
# filter and the `what` will be applied. (vice-versa is also true)
#
# For example, Java stack traces are multiline and usually have the message
# starting at the far-left, with each subsequent line indented. Do this:
# [source,ruby]
#     input {
#       stdin {
#         codec => multiline {
#           pattern => "^\s"
#           what => "previous"
#         }
#       }
#     }
#
# This says that any line starting with whitespace belongs to the previous line.
#
# Another example is to merge lines not starting with a date up to the previous
# line..
# [source,ruby]
#     input {
#       file {
#         path => "/var/log/someapp.log"
#         codec => multiline {
#           # Grok pattern names are valid! :)
#           pattern => "^%{TIMESTAMP_ISO8601} "
#           negate => true
#           what => previous
#         }
#       }
#     }
#
# This says that any line not starting with a timestamp should be merged with the previous line.
#
# One more common example is C line continuations (backslash). Here's how to do that:
# [source,ruby]
#     filter {
#       multiline {
#         type => "somefiletype"
#         pattern => "\\$"
#         what => "next"
#       }
#     }
#
# This says that any line ending with a backslash should be combined with the
# following line.
#
class LogStash::Codecs::Multiline < LogStash::Codecs::Base
  config_name "multiline"

  # The regular expression to match.
  config :pattern, :validate => :string, :required => true

  # If the pattern matched, does event belong to the next or previous event?
  config :what, :validate => ["previous", "next"], :required => true

  # Negate the regexp pattern ('if not matched').
  config :negate, :validate => :boolean, :default => false

  # Logstash ships by default with a bunch of patterns, so you don't
  # necessarily need to define this yourself unless you are adding additional
  # patterns.
  #
  # Pattern files are plain text with format:
  # [source,ruby]
  #     NAME PATTERN
  #
  # For example:
  # [source,ruby]
  #     NUMBER \d+
  config :patterns_dir, :validate => :array, :default => []

  # The character encoding used in this input. Examples include `UTF-8`
  # and `cp1252`
  #
  # This setting is useful if your log files are in `Latin-1` (aka `cp1252`)
  # or in another character set other than `UTF-8`.
  #
  # This only affects "plain" format logs since JSON is `UTF-8` already.
  config :charset, :validate => ::Encoding.name_list, :default => "UTF-8"

  # Tag multiline events with a given tag. This tag will only be added
  # to events that actually have multiple lines in them.
  config :multiline_tag, :validate => :string, :default => "multiline"

  # The accumulation of events can make logstash exit with an out of memory error
  # if event boundaries are not correctly defined. This settings make sure to flush
  # multiline events after reaching a number of lines, it is used in combination
  # max_bytes.
  config :max_lines, :validate => :number, :default => 500

  # The accumulation of events can make logstash exit with an out of memory error
  # if event boundaries are not correctly defined. This settings make sure to flush
  # multiline events after reaching a number of bytes, it is used in combination
  # max_lines.
  config :max_bytes, :validate => :bytes, :default => "10 MiB"

  public
  def register
    require "grok-pure" # rubygem 'jls-grok'
    require 'logstash/patterns/core'

    # Detect if we are running from a jarfile, pick the right path.
    patterns_path = []
    patterns_path += [LogStash::Patterns::Core.path]

    @grok = Grok.new

    @patterns_dir = patterns_path.to_a + @patterns_dir
    @patterns_dir.each do |path|
      if File.directory?(path)
        path = File.join(path, "*")
      end

      Dir.glob(path).each do |file|
        @logger.info("Grok loading patterns from file", :path => file)
        @grok.add_patterns_from_file(file)
      end
    end

    @grok.compile(@pattern)
    @logger.debug("Registered multiline plugin", :type => @type, :config => @config)

    reset_buffer

    @handler = method("do_#{@what}".to_sym)

    @converter = LogStash::Util::Charset.new(@charset)
    @converter.logger = @logger
  end # def register

  def decode(text, &block)
    text = @converter.convert(text)

    text.split("\n").each do |line|
      match = @grok.match(line)
      @logger.debug("Multiline", :pattern => @pattern, :text => line,
                    :match => !match.nil?, :negate => @negate)

      # Add negate option
      match = (match and !@negate) || (!match and @negate)
      @handler.call(line, match, &block)
    end
  end # def decode

  def buffer(text)
    @time = LogStash::Timestamp.now if @buffer.empty?
    @buffer_bytes += text.bytesize
    @buffer << text
  end

  def flush(&block)
    if @buffer.any?
      yield merge_events
      reset_buffer
    end
  end

  def merge_events
    event = LogStash::Event.new(LogStash::Event::TIMESTAMP => @time, "message" => @buffer.join(NL))
    event.tag @multiline_tag if @multiline_tag && @buffer.size > 1
    event.tag "multiline_codec_max_bytes_reached" if over_maximun_bytes?
    event.tag "multiline_codec_max_lines_reached" if over_maximun_lines?
    event
  end

  def reset_buffer
    @buffer = []
    @buffer_bytes = 0
  end

  def do_next(text, matched, &block)
    buffer(text)
    flush(&block) if !matched || buffer_over_limits?
  end

  def do_previous(text, matched, &block)
    flush(&block) if !matched || buffer_over_limits?
    buffer(text)
  end

  def over_maximun_lines?
    @buffer.size > @max_lines
  end

  def over_maximun_bytes?
    @buffer_bytes >= @max_bytes
  end

  def buffer_over_limits?
    over_maximun_lines? || over_maximun_bytes?
  end

  def encode(event)
    # Nothing to do.
    @on_event.call(event, event)
  end # def encode

end # class LogStash::Codecs::Multiline
