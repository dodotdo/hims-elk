module LogStash; module Outputs; class ElasticSearch
  module CommonConfigs
    def self.included(mod)
      # The index to write events to. This can be dynamic using the `%{foo}` syntax.
      # The default value will partition your indices by day so you can more easily
      # delete old data or only search specific date ranges.
      # Indexes may not contain uppercase characters.
      # For weekly indexes ISO 8601 format is recommended, eg. logstash-%{+xxxx.ww}
      mod.config :index, :validate => :string, :default => "logstash-%{+YYYY.MM.dd}"

      # The index type to write events to. Generally you should try to write only
      # similar events to the same 'type'. String expansion `%{foo}` works here.
      #
      # Deprecated in favor of `docoument_type` field.
      mod.config :index_type, :validate => :string, :obsolete => "Please use the 'document_type' setting instead. It has the same effect, but is more appropriately named."

      # The document type to write events to. Generally you should try to write only
      # similar events to the same 'type'. String expansion `%{foo}` works here.
      # Unless you set 'document_type', the event 'type' will be used if it exists
      # otherwise the document type will be assigned the value of 'logs'
      mod.config :document_type, :validate => :string

      # Starting in Logstash 1.3 (unless you set option `manage_template` to false)
      # a default mapping template for Elasticsearch will be applied, if you do not
      # already have one set to match the index pattern defined (default of
      # `logstash-%{+YYYY.MM.dd}`), minus any variables.  For example, in this case
      # the template will be applied to all indices starting with `logstash-*`
      #
      # If you have dynamic templating (e.g. creating indices based on field names)
      # then you should set `manage_template` to false and use the REST API to upload
      # your templates manually.
      mod.config :manage_template, :validate => :boolean, :default => true

      # This configuration option defines how the template is named inside Elasticsearch.
      # Note that if you have used the template management features and subsequently
      # change this, you will need to prune the old template manually, e.g.
      #
      # `curl -XDELETE <http://localhost:9200/_template/OldTemplateName?pretty>`
      #
      # where `OldTemplateName` is whatever the former setting was.
      mod.config :template_name, :validate => :string, :default => "logstash"

      # You can set the path to your own template here, if you so desire.
      # If not set, the included template will be used.
      mod.config :template, :validate => :path

      # Overwrite the current template with whatever is configured
      # in the `template` and `template_name` directives.
      mod.config :template_overwrite, :validate => :boolean, :default => false

      # The document ID for the index. Useful for overwriting existing entries in
      # Elasticsearch with the same ID.
      mod.config :document_id, :validate => :string

      # A routing override to be applied to all processed events.
      # This can be dynamic using the `%{foo}` syntax.
      mod.config :routing, :validate => :string

      # For child documents, ID of the associated parent.
      # This can be dynamic using the `%{foo}` syntax.
      mod.config :parent, :validate => :string, :default => nil

      # Sets the host(s) of the remote instance. If given an array it will load balance requests across the hosts specified in the `hosts` parameter.
      # Remember the `http` protocol uses the http://www.elastic.co/guide/en/elasticsearch/reference/current/modules-http.html#modules-http[http] address (eg. 9200, not 9300).
      #     `"127.0.0.1"`
      #     `["127.0.0.1:9200","127.0.0.2:9200"]`
      # It is important to exclude http://www.elastic.co/guide/en/elasticsearch/reference/current/modules-node.html[dedicated master nodes] from the `hosts` list
      # to prevent LS from sending bulk requests to the master nodes.  So this parameter should only reference either data or client nodes in Elasticsearch.
      mod.config :hosts, :validate => :array, :default => ["127.0.0.1"]

      mod.config :host, :obsolete => "Please use the 'hosts' setting instead. You can specify multiple entries separated by comma in 'host:port' format."

      # The port setting is obsolete.  Please use the 'hosts' setting instead.
      # Hosts entries can be in "host:port" format.
      mod.config :port, :obsolete => "Please use the 'hosts' setting instead. Hosts entries can be in 'host:port' format."

      # This plugin uses the bulk index API for improved indexing performance.
      # To make efficient bulk API calls, we will buffer a certain number of
      # events before flushing that out to Elasticsearch. This setting
      # controls how many events will be buffered before sending a batch
      # of events. Increasing the `flush_size` has an effect on Logstash's heap size.
      # Remember to also increase the heap size using `LS_HEAP_SIZE` if you are sending big documents
      # or have increased the `flush_size` to a higher value.
      mod.config :flush_size, :validate => :number, :default => 500

      # The amount of time since last flush before a flush is forced.
      #
      # This setting helps ensure slow event rates don't get stuck in Logstash.
      # For example, if your `flush_size` is 100, and you have received 10 events,
      # and it has been more than `idle_flush_time` seconds since the last flush,
      # Logstash will flush those 10 events automatically.
      #
      # This helps keep both fast and slow log streams moving along in
      # near-real-time.
      mod.config :idle_flush_time, :validate => :number, :default => 1

      # Set upsert content for update mode.s
      # Create a new document with this parameter as json string if `document_id` doesn't exists
      mod.config :upsert, :validate => :string, :default => ""

      # Enable `doc_as_upsert` for update mode.
      # Create a new document with source if `document_id` doesn't exist in Elasticsearch
      mod.config :doc_as_upsert, :validate => :boolean, :default => false

      # Set max retry for each event. The total time spent blocked on retries will be
      # (max_retries * retry_max_interval). This may vary a bit if Elasticsearch is very slow to respond
      mod.config :max_retries, :validate => :number, :default => 3

      # Set max interval between bulk retries.
      mod.config :retry_max_interval, :validate => :number, :default => 2

      # DEPRECATED This setting no longer does anything. If you need to change the number of retries in flight
      # try increasing the total number of workers to better handle this.
      mod.config :retry_max_items, :validate => :number, :default => 500, :deprecated => true
    end
  end
end end end