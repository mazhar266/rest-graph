
# optional http client
begin; require 'restclient'     ; rescue LoadError; end
begin; require 'em-http-request'; rescue LoadError; end

# optional gem
begin; require 'rack'           ; rescue LoadError; end

# stdlib
require 'digest/md5'
require 'openssl'

require 'cgi'
require 'timeout'

module RestCore
  # ------------------------ class ------------------------
  def self.included mod
    return if   mod < DefaultAttributes
    mod.send(:extend, DefaultAttributes)
    mod.send(:extend, Hmac)
    setup_accessor(mod)
    select_json!(mod)
  end

  def self.members_core
    [:auto_decode, :timeout, :server, :accept, :lang,
     :data, :cache, :log_method, :log_handler, :error_handler]
  end

  def self.struct prefix, *members
    name = "#{prefix}Struct"
    if const_defined?(name)
      const_get(name)
    else
      # Struct.new(*members_core, *members) if RUBY_VERSION >= '1.9.2'
      const_set(name, Struct.new(*(members_core + members)))
    end
  end

  def self.setup_accessor mod
    # honor default attributes
    src = mod.members.map{ |name|
      <<-RUBY
        def #{name}
          if (r = super).nil? then self.#{name} = self.class.default_#{name}
                              else r end
        end
        self
      RUBY
    }
    # if RUBY_VERSION < '1.9.2'
    src << <<-RUBY if mod.members.first.kind_of?(String)
      def members
        super.map(&:to_sym)
      end
      self
    RUBY
    # end
    accessor = Module.new.module_eval(src.join("\n"))
    const_set("#{mod.name}Accessor", accessor)
    mod.send(:include, accessor)
  end
  # ------------------------ class ------------------------



  # ------------------------ default ----------------------
  module DefaultAttributes
    extend self
    def default_auto_decode  ; true               ; end
    def default_timeout      ; 10                 ; end
    def default_server       ; 'http://localhost/'; end
    def default_accept       ; 'text/javascript'  ; end
    def default_lang         ; 'en-us'            ; end
    def default_data         ; {}                 ; end
    def default_cache        ; nil                ; end
    def default_log_method   ; nil                ; end
    def default_log_handler  ; nil                ; end
    def default_error_handler; nil                ; end
  end
  extend DefaultAttributes
  # ------------------------ default ----------------------

  # ------------------------ event ------------------------
  EventStruct = Struct.new(:duration, :url) unless
    RestCore.const_defined?(:EventStruct)

  class Event < EventStruct
    # self.class.name[/(?<=::)\w+$/] if RUBY_VERSION >= '1.9.2'
    def name; self.class.name[/::\w+$/].tr(':', ''); end
    def to_s; "RestCore: spent #{sprintf('%f', duration)} #{name} #{url}";end
  end
  class Event::MultiDone < Event; end
  class Event::Requested < Event; end
  class Event::CacheHit  < Event; end
  class Event::Failed    < Event; end
  # ------------------------ event ------------------------



  # ------------------------ json -------------------------
  module YajlRuby
    def self.extended mod
      mod.const_set(:ParseError, Yajl::ParseError)
    end
    def json_encode hash
      Yajl::Encoder.encode(hash)
    end
    def json_decode json
      Yajl::Parser.parse(json)
    end
  end

  module Json
    def self.extended mod
      mod.const_set(:ParseError, JSON::ParserError)
    end
    def json_encode hash
      JSON.dump(hash)
    end
    def json_decode json
      JSON.parse(json)
    end
  end

  module Gsub
    class ParseError < RuntimeError; end
    def self.extended mod
      mod.const_set(:ParseError, Gsub::ParseError)
    end
    # only works for flat hash
    def json_encode hash
      middle = hash.inject([]){ |r, (k, v)|
                 r << "\"#{k}\":\"#{v.gsub('"','\\"')}\""
               }.join(',')
      "{#{middle}}"
    end
    def json_decode json
      raise NotImplementedError.new(
        'You need to install either yajl-ruby, json, or json_pure gem')
    end
  end

  def self.select_json! mod, picked=false
    if    Object.const_defined?(:Yajl)
      mod.send(:extend, YajlRuby)
    elsif Object.const_defined?(:JSON)
      mod.send(:extend, Json)
    elsif picked
      mod.send(:extend, Gsub)
    else
      # pick a json gem if available
      %w[yajl json].each{ |json|
        begin
          require json
          break
        rescue LoadError
        end
      }
      select_json!(mod, true)
    end
  end
  # ------------------------ json -------------------------


  # ------------------------ hmac -------------------------
  module Hmac
    # Fallback to ruby-hmac gem in case system openssl
    # lib doesn't support SHA256 (OSX 10.5)
    def hmac_sha256 key, data
      OpenSSL::HMAC.digest('sha256', key, data)
    rescue RuntimeError
      require 'hmac-sha2'
      HMAC::SHA256.digest(key, data)
    end
  end
  # ------------------------ hmac -------------------------



  # ------------------------ instance ---------------------
  def initialize o={}
    (members + [:access_token]).each{ |name|
      send("#{name}=", o[name]) if o.key?(name)
    }
  end

  def attributes
    Hash[each_pair.map{ |k, v| [k, send(k)] }]
  end

  def inspect
    "#<struct #{self.class.name} #{attributes.map{ |k, v|
      "#{k}=#{v.inspect}" }.join(', ')}>"
  end

  def lighten! o={}
    attributes.each{ |k, v| case v; when Proc, IO; send("#{k}=", false); end}
    send(:initialize, o)
    self
  end

  def lighten o={}
    dup.lighten!(o)
  end

  def url path, query={}, prefix=server, opts={}
    "#{prefix}#{path}#{build_query_string(query, opts)}"
  end

  # extra options:
  #   auto_decode: Bool # decode with json or not in this API request
  #                     # default: auto_decode in rest-graph instance
  #       timeout: Int  # the timeout for this API request
  #                     # default: timeout in rest-graph instance
  #        secret: Bool # use secret_acccess_token or not
  #                     # default: false
  #         cache: Bool # use cache or not; if it's false, update cache, too
  #                     # default: true
  #    expires_in: Int  # control when would the cache be expired
  #                     # default: nil
  #         async: Bool # use eventmachine for http client or not
  #                     # default: false, but true in aget family
  #       headers: Hash # additional hash you want to pass
  #                     # default: {}
  def get    path, query={}, opts={}, &cb
    request(opts, [:get   , url(path, query, server, opts)], &cb)
  end

  def delete path, query={}, opts={}, &cb
    request(opts, [:delete, url(path, query, server, opts)], &cb)
  end

  def post   path, payload={}, query={}, opts={}, &cb
    request(opts, [:post  , url(path, query, server, opts), payload],
            &cb)
  end

  def put    path, payload={}, query={}, opts={}, &cb
    request(opts, [:put   , url(path, query, server, opts), payload],
            &cb)
  end

  # request by eventmachine (em-http)

  def aget    path, query={}, opts={}, &cb
    get(path, query, {:async => true}.merge(opts), &cb)
  end

  def adelete path, query={}, opts={}, &cb
    delete(path, query, {:async => true}.merge(opts), &cb)
  end

  def apost   path, payload={}, query={}, opts={}, &cb
    post(path, payload, query, {:async => true}.merge(opts), &cb)
  end

  def aput    path, payload={}, query={}, opts={}, &cb
    put(path, payload, query, {:async => true}.merge(opts), &cb)
  end

  def multi reqs, opts={}, &cb
    request({:async => true}.merge(opts),
      *reqs.map{ |(meth, path, query, payload)|
        [meth, url(path, query || {}, server, opts), payload]
      }, &cb)
  end

  def request opts, *reqs, &cb
    Timeout.timeout(opts[:timeout] || timeout){
      reqs.each{ |(meth, uri, payload)|
        next if meth != :get     # only get result would get cached
        cache_assign(opts, uri, nil)
      } if opts[:cache] == false # remove cache if we don't want it

      if opts[:async]
        request_em(opts, reqs, &cb)
      else
        request_rc(opts, *reqs.first, &cb)
      end
    }
  end
  # ------------------------ instance ---------------------



  protected
  # those are for user to override
  def prepare_query_string opts={};    {}; end
  def prepare_headers      opts={};    {}; end
  def error?               decoded; false; end

  private
  def request_em opts, reqs
    start_time = Time.now
    rs = reqs.map{ |(meth, uri, payload)|
      r = EM::HttpRequest.new(uri).send(meth, :body => payload,
                                              :head => build_headers(opts))
      if cached = cache_get(opts, uri)
        # TODO: this is hack!!
        r.instance_variable_set('@response', cached)
        r.instance_variable_set('@state'   , :finish)
        r.on_request_complete
        r.succeed(r)
      else
        r.callback{
          cache_for(opts, uri, meth, r.response)
          log(Event::Requested.new(Time.now - start_time, uri))
        }
        r.error{
          log(Event::Failed.new(Time.now - start_time, uri))
        }
      end
      r
    }
    EM::MultiRequest.new(rs){ |m|
      # TODO: how to deal with the failed?
      clients = m.responses[:succeeded]
      results = clients.map{ |client|
        post_request(opts, client.uri, client.response)
      }

      if reqs.size == 1
        yield(results.first)
      else
        log(Event::MultiDone.new(Time.now - start_time,
          clients.map(&:uri).join(', ')))
        yield(results)
      end
    }
  end

  def request_rc opts, meth, uri, payload=nil, &cb
    start_time = Time.now
    post_request(opts, uri,
                 cache_get(opts, uri) || fetch(opts, uri, meth, payload),
                 &cb)
  rescue RestClient::Exception => e
    post_request(opts, uri, e.http_body, &cb)
  ensure
    log(Event::Requested.new(Time.now - start_time, uri))
  end

  def build_query_string query={}, opts={}
                                              # compacting the hash
    q = prepare_query_string(opts).merge(query).select{ |k, v| v }
    return '' if q.empty?
    return '?' + q.map{ |(k, v)| "#{k}=#{CGI.escape(v.to_s)}" }.join('&')
  end

  def build_headers opts={}
    headers = {}
    headers['Accept']          = accept if accept
    headers['Accept-Language'] = lang   if lang
    headers.merge(prepare_headers(opts).merge(opts[:headers] || {}))
  end

  def post_request opts, uri, result
    if decode?(opts)
                                  # [this].first is not needed for yajl-ruby
      decoded = self.class.json_decode("[#{result}]").first
      if error?(decoded)
        cache_assign(opts, uri, nil)
        error_handler.call(decoded, uri) if error_handler
      end
      block_given? ? yield(decoded) : decoded
    else
      block_given? ? yield(result ) : result
    end
  rescue self.class.const_get(:ParseError) => error
    error_handler.call(error, uri) if error_handler
  end

  def decode? opts
    if opts.has_key?(:auto_decode)
      opts[:auto_decode]
    else
      auto_decode
    end
  end

  def cache_key opts, uri
    Digest::MD5.hexdigest(opts[:uri] || uri)
  end

  def cache_assign opts, uri, value
    return unless cache
    cache[cache_key(opts, uri)] = value
  end

  def cache_get opts, uri
    return unless cache
    start_time = Time.now
    cache[cache_key(opts, uri)].tap{ |result|
      log(Event::CacheHit.new(Time.now - start_time, uri)) if result
    }
  end

  def cache_for opts, uri, meth, value
    return unless cache
    # fake post (opts[:post] => true) is considered get and need cache
    return if meth != :get unless opts[:post]

    if opts[:expires_in].kind_of?(Fixnum) && cache.method(:store).arity == -3
      cache.store(cache_key(opts, uri), value,
                  :expires_in => opts[:expires_in])
    else
      cache_assign(opts, uri, value)
    end
  end

  def fetch opts, uri, meth, payload
    RestClient::Request.execute(:method => meth, :url => uri,
                                :headers => build_headers(opts),
                                :payload => payload).body.
      tap{ |result| cache_for(opts, uri, meth, result) }
  end

  def log event
    log_handler.call(event)             if log_handler
    log_method .call("DEBUG: #{event}") if log_method
  end
end
