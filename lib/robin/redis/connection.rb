# frozen_string_literal: true

require "socket"
require "uri"
require "digest/sha1"
require "openssl"
require_relative "resp"

module Robin
  module Redis
    class ConnectionError < StandardError; end

    class TimeoutError < ConnectionError; end

    # Picks the reply parser: the optional C extension when it's available
    # (and not disabled with ROBIN_NO_EXT=1), else the pure-Ruby one.
    def self.parser(disabled: !ENV.fetch("ROBIN_NO_EXT", "").empty?, loader: Kernel.public_method(:require))
      return RESP if disabled

      loader.call("robin_resp/robin_resp")
      NativeRESP
    rescue LoadError
      RESP
    end

    PARSER = parser

    # The C extension's socket reader (Robin::Redis::NativeIO.fill), when the
    # C parser is in use (it's missing where the system has no poll(2)).
    def self.native_io(parser, mod)
      mod::NativeIO if !parser.equal?(RESP) && mod.const_defined?(:NativeIO)
    end

    NATIVE_IO = native_io(PARSER, self)

    # Encodes commands: the extension's encoder where it has one (the Java
    # one does), else the pure-Ruby one.
    def self.encoder(parser) = parser.respond_to?(:encode) ? parser : RESP

    ENCODER = encoder(PARSER)

    # A single, non-thread-safe connection to a Redis server. Use
    # Robin::Redis::Pool to share connections between threads.
    class Connection
      DEFAULTS = {
        host: "127.0.0.1", port: 6379, db: 0, path: nil, username: nil, password: nil,
        ssl: false, ssl_params: {}, connect_timeout: 1.0, read_timeout: 3.0,
        write_timeout: 3.0, name: nil, sentinels: nil, master_name: nil,
        sentinel_username: nil, sentinel_password: nil
      }.freeze

      SENTINEL_PORT = 26_379

      SCHEMES = %w[redis rediss valkey valkeys].freeze
      TLS_SCHEMES = %w[rediss valkeys].freeze
      READ_CHUNK = 65_536

      # Error replies saying this server can't serve the command right now
      # because of its role or state: a primary demoted to replica by a
      # failover (READONLY, UNBLOCKED), a primary without enough replicas
      # (NOREPLICAS), a replica cut off from its primary (MASTERDOWN), or a
      # server still loading its data (LOADING). None of them ran the
      # command. The connection is closed so the next command reconnects,
      # which reaches the new primary when a proxy, DNS name or VIP has
      # moved; a single command is retried once on the fresh connection.
      # Pipelines and transactions are not retried.
      RECONNECT_ERRORS = %w[READONLY NOREPLICAS UNBLOCKED MASTERDOWN LOADING].freeze

      attr_reader :options

      # +url+ with any password (or user) replaced, fit for messages.
      # Everything up to the last "@" goes, as a password may itself
      # contain "@" or "/".
      def self.redact(url) = url.to_s.sub(%r{//.+@}m, "//REDACTED@")

      def self.parse_url(url)
        uri = begin
          URI.parse(url)
        rescue URI::InvalidURIError
          # Ruby's message would show the URL, password and all.
          raise ArgumentError, "invalid Redis URL: #{redact(url)}"
        end
        opts = if uri.scheme == "unix"
          {path: uri.path}
        elsif SCHEMES.include?(uri.scheme)
          tcp_options(uri)
        else
          raise ArgumentError, "unsupported Redis URL scheme: #{uri.scheme.inspect}"
        end
        user = uri.user.to_s
        opts[:username] = URI.decode_www_form_component(user) unless user.empty?
        if (password = uri.password) then opts[:password] = URI.decode_www_form_component(password) end
        URI.decode_www_form(uri.query.to_s).each { |key, value| opts[:db] = Integer(value) if key == "db" }
        opts
      end

      def self.tcp_options(uri)
        opts = {ssl: TLS_SCHEMES.include?(uri.scheme)} #: Hash[Symbol, untyped]
        host = uri.host.to_s
        opts[:host] = host unless host.empty?
        opts[:port] = uri.port if uri.port
        db = uri.path.to_s.delete_prefix("/")
        opts[:db] = Integer(db) unless db.empty?
        opts
      end
      private_class_method :tcp_options

      # The Redis URL from the environment: ROBIN_REDIS_URL, else the
      # variable REDIS_PROVIDER names (e.g. REDIS_PROVIDER=REDISCLOUD_URL, as
      # some hosts' add-ons set), else REDIS_URL.
      def self.env_url(env = ENV)
        provider = env["REDIS_PROVIDER"].to_s
        from_provider = provider.include?("://") ? provider : env[provider]
        env["ROBIN_REDIS_URL"] || from_provider || env["REDIS_URL"]
      end

      def initialize(**options)
        # @type var options: Hash[Symbol, untyped]
        url = options.delete(:url) || (self.class.env_url unless options.key?(:host) || options.key?(:path))
        options = self.class.parse_url(url).merge(options) if url
        unknown = options.keys - DEFAULTS.keys
        raise ArgumentError, "unknown Redis options: #{unknown.join(", ")}" unless unknown.empty?

        @options = DEFAULTS.merge(options)
        @sentinels = self.class.sentinel_list(@options.fetch(:sentinels))
        if @sentinels
          @options[:master_name] ||= options[:host]
          raise ArgumentError, "Sentinel needs a master_name (or the URL's host)" unless @options.fetch(:master_name)
        end
        reset
      end

      # Normalizes the +sentinels:+ option: "host:port" strings or
      # {host:, port:} hashes (the port defaults to 26379).
      # (Each entry becomes a [host, port] pair, which Steep sees as an Array.)
      def self.sentinel_list(sentinels) # steep:ignore MethodBodyTypeMismatch
        return unless sentinels

        list = Array(sentinels).map do |entry|
          case entry
          when Hash
            entry = entry.transform_keys(&:to_sym)
            [entry.fetch(:host), Integer(entry.fetch(:port, SENTINEL_PORT))]
          else
            host, port = entry.split(":")
            [host, Integer(port || SENTINEL_PORT)]
          end
        end
        raise ArgumentError, "sentinels must not be empty" if list.empty?

        list
      end

      # Never shows the password.
      def inspect = "#<#{self.class} #{id}>"

      def id
        return @options.fetch(:path) if @options.fetch(:path)

        target = @sentinels ? "sentinel:#{@options.fetch(:master_name)}" : "#{@options.fetch(:host)}:#{@options.fetch(:port)}"
        "#{target}/#{@options.fetch(:db)}"
      end

      # Sends a command and returns its reply. Error replies are raised as
      # Robin::Redis::CommandError (see RECONNECT_ERRORS for the ones that
      # are retried first).
      def call(*args) = call_with_timeout(@options.fetch(:read_timeout), args)

      # Like #call, but for blocking commands (BLMOVE, BLPOP...). The read
      # timeout is extended by +timeout+ seconds so the server gets the
      # chance to answer first.
      def blocking_call(timeout, *args) = call_with_timeout(@options.fetch(:read_timeout) + timeout, args)

      # Sends several commands in one round-trip. Yields a Pipeline; returns
      # the array of replies. The first error reply is raised after all
      # replies have been read. A pipeline holding a blocking command passes
      # its +timeout+, which extends the read timeout like #blocking_call's
      # (Redis runs the commands after it once it returns).
      #
      # A pipeline runs scripts by their SHA once this connection's server
      # has them (see Pipeline#evalsha): it loads each the first time,
      # with a SCRIPT LOAD whose reply isn't among the results.
      def pipelined(timeout: 0)
        pipe = Pipeline.new(@scripts)
        yield pipe
        return [] if pipe.commands.empty?

        results = roundtrip(pipe.commands, @options.fetch(:read_timeout) + timeout)
        loads = pipe.loads
        unless loads.empty?
          @scripts.merge(pipe.loading)
          results = results.reject.with_index { |_, i| loads.include?(i) }
        end
        raise_first_error(results)
        results
      end

      # MULTI/EXEC transaction. Returns the EXEC reply (array of results).
      def multi
        pipe = Pipeline.new
        yield pipe
        results = roundtrip([["MULTI"], *pipe.commands, ["EXEC"]], @options.fetch(:read_timeout))
        raise_first_error(results) # errors queueing commands
        exec = results.last
        raise_first_error(exec) # errors running them
        exec
      end

      # Runs a Lua script by SHA, loading it transparently the first time
      # (in one more round trip, with the script run again).
      def evalsha(script, keys = [], argv = nil)
        result = begin
          # (A nil argv splats to nothing.)
          call("EVALSHA", script.sha, keys.size, *keys, *argv) # steep:ignore ArgumentTypeMismatch
        rescue CommandError => e
          raise unless e.message.start_with?("NOSCRIPT")

          pipelined do |p|
            p.call("SCRIPT", "LOAD", script.source)
            p.call("EVALSHA", script.sha, keys.size, *keys, *argv) # steep:ignore ArgumentTypeMismatch
          end.last
        end
        @scripts << script.sha # it has it now
        result
      end

      def close
        @sock&.close
      rescue IOError, SystemCallError
        nil
      ensure
        reset
      end

      # Lets go of the connection without a word to the server, as a forked
      # child must with the ones it inherited: closing a TLS socket sends a
      # goodbye (close_notify) down the socket the parent still uses, and
      # Redis hangs up on the parent. Closing just this process's file
      # descriptor leaves the parent's connection as it was.
      def abandon
        # (An SSLSocket's #io is the socket under it.)
        (@sock.respond_to?(:io) ? @sock.io : @sock)&.close # steep:ignore NoMethod
      rescue IOError, SystemCallError
        nil
      ensure
        reset
      end

      private

      # Forgets the socket and any buffered reply bytes.
      def reset
        @sock = nil
        @buf = "".b
        @pos = 0
        # The SHAs of the scripts the server has, as far as we know (a new
        # socket may reach another server).
        @scripts = Set.new
      end

      def call_with_timeout(read_timeout, args, retried: false)
        result = roundtrip([args], read_timeout).first
        return result unless result.instance_of?(CommandError)
        raise result unless reconnect_error?(result)

        close
        raise result if retried

        call_with_timeout(read_timeout, args, retried: true)
      end

      def raise_first_error(results)
        error = results.find { |r| r.instance_of?(CommandError) }
        return unless error

        # The server lost its scripts (SCRIPT FLUSH): load them again.
        @scripts.clear if error.message.start_with?("NOSCRIPT")
        close if reconnect_error?(error)
        raise error
      end

      def reconnect_error?(error)
        RECONNECT_ERRORS.include?(error.message[/\A\S+/])
      end

      def encode(commands)
        commands.each_with_object("".b) { |cmd, out| ENCODER.encode(cmd, out) }
      end

      def roundtrip(commands, read_timeout)
        send_commands(encode(commands), read_timeout)
        read_replies(commands.size, read_timeout)
      end

      def send_commands(payload, read_timeout)
        retried = false
        begin
          # NativeIO.roundtrip checks the socket itself.
          close if @sock && (roundtrip? ? @pos < @buf.bytesize : stale?)
          connect unless @sock
          roundtrip? ? send_and_read(payload, read_timeout) : write(payload)
        rescue Errno::EPIPE, Errno::ECONNRESET, Errno::ECONNABORTED, IOError => e
          # The write failed before sending anything (see #write), so the
          # server never saw the command: reconnect and retry once.
          close
          raise ConnectionError, "#{e.class}: #{e} (#{id})" if retried

          retried = true
          retry
        end
      end

      def roundtrip? = @native_io.respond_to?(:roundtrip)

      # With the C extension: checks the connection, sends +payload+, and
      # waits for and reads the start of the replies, in one call (one
      # release of the GVL). Reconnects once if the connection was dropped;
      # a write that fails before sending anything raises its Errno, for
      # #send_commands to retry.
      def send_and_read(payload, read_timeout, reconnected: false)
        # @type ivar @native_io: singleton(NativeIO)
        # @type ivar @sock: Socket | UNIXSocket
        result = begin
          @native_io.roundtrip(@sock, payload, @buf, @options.fetch(:write_timeout), read_timeout)
        rescue SystemCallError => e
          # Only reads raise these: the commands went out, so never retry.
          raise ConnectionError, "#{e.class}: #{e} (#{id})"
        end
        case result
        when :stale
          raise ConnectionError, "connection unusable right after connecting (#{id})" if reconnected

          close
          connect
          send_and_read(payload, read_timeout, reconnected: true)
        when Array then write_failed(result)
        else filled(result)
        end
      rescue Exception # rubocop:disable Lint/RescueException
        # Anything else (an error, Thread#raise) leaves the connection in
        # an unknown state.
        close
        raise
      end

      # Raises for a write NativeIO.roundtrip couldn't finish: [bytes written,
      # errno].
      def write_failed(failure)
        written, errno = failure
        raise TimeoutError, "timed out talking to Redis (#{id})" unless errno

        error = SystemCallError.new("writing to Redis", errno)
        raise error if written.zero?

        raise ConnectionError, "#{error.class}: #{error} after a partial write (#{id})"
      end

      def read_replies(count, read_timeout)
        # @type ivar @sock: Socket | UNIXSocket | OpenSSL::SSL::SSLSocket
        completed = false
        # The commands were only just sent, so their replies can't have
        # arrived: wait for them instead of first trying a read (a syscall
        # that would only say "not yet"). Over TLS, OpenSSL may hold bytes
        # the socket doesn't show, so a read comes first there.
        wait(@sock, :wait_readable, read_timeout) unless @native_io || @pos < @buf.bytesize || @options.fetch(:ssl)
        replies = Array.new(count) { read_reply(read_timeout) }
        completed = true
        replies
      rescue SystemCallError, IOError => e
        raise ConnectionError, "#{e.class}: #{e} (#{id})"
      ensure
        # Anything that interrupts us mid-read (an error, a timeout, or
        # Thread#raise) leaves unread replies on the socket; the
        # connection can't be reused.
        close unless completed
      end

      # A connection may have been dropped by the server or a proxy (while
      # idle, or by a restart or failover). Checking before every write
      # means the command can safely go out on a fresh connection instead.
      # The C extension peeks without reading; otherwise a non-blocking read
      # checks, which also consumes TLS housekeeping records (like session
      # tickets) that don't count. Leftover bytes mean the stream is out of
      # sync.
      def stale?
        # @type ivar @sock: Socket | UNIXSocket | OpenSSL::SSL::SSLSocket
        # @type ivar @native_io: singleton(NativeIO)
        return true if @pos < @buf.bytesize
        # (The native reader is only used on plain sockets.)
        return @native_io.stale?(@sock) if @native_io # steep:ignore ArgumentTypeMismatch

        !@sock.read_nonblock(READ_CHUNK, exception: false).instance_of?(Symbol)
      rescue IOError, SystemCallError
        true
      end

      def connect
        @sock = open_socket
        # Plain sockets can use the C reader; TLS ones (an OpenSSL::SSL::SSLSocket
        # isn't an IO) need OpenSSL to read.
        @native_io = (NATIVE_IO if @sock.is_a?(IO))
        handshake
      rescue SystemCallError, SocketError, IO::TimeoutError => e
        close
        raise ConnectionError, "#{e.class}: #{e} (#{id})"
      rescue Exception # rubocop:disable Lint/RescueException
        close
        raise
      end

      def open_socket
        return UNIXSocket.new(@options.fetch(:path)) if @options.fetch(:path)

        host, port = @sentinels ? sentinel_master : @options.fetch_values(:host, :port)
        sock = Socket.tcp(host, port, connect_timeout: @options.fetch(:connect_timeout)).tap do |s|
          s.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, true)
          s.setsockopt(Socket::SOL_SOCKET, Socket::SO_KEEPALIVE, true)
        end
        @options.fetch(:ssl) ? wrap_ssl(sock, host) : sock
      end

      # Asks the Sentinels, in turn, where the master is. The first one
      # that answers moves to the front of the list for next time.
      def sentinel_master
        # @type ivar @sentinels: Array[[String, Integer]]
        name = @options.fetch(:master_name)
        failures = @sentinels.each_with_index.map do |(host, port), i|
          address = ask_sentinel(host, port, name)
          return address.tap { @sentinels.unshift(@sentinels.delete_at(i)) } if address.instance_of?(Array)

          "#{host}:#{port} #{address}"
        end
        raise ConnectionError, "no Sentinel could locate master #{name} (#{failures.join("; ")})"
      end

      # The master's [host, port], or why the Sentinel couldn't tell (a
      # message or an error).
      def ask_sentinel(host, port, name)
        sentinel = Connection.new(
          host: host, port: port, username: @options.fetch(:sentinel_username),
          password: @options.fetch(:sentinel_password), ssl: @options.fetch(:ssl),
          ssl_params: @options.fetch(:ssl_params), connect_timeout: @options.fetch(:connect_timeout),
          read_timeout: @options.fetch(:connect_timeout), write_timeout: @options.fetch(:connect_timeout)
        )
        begin
          host, port = sentinel.call("SENTINEL", "GET-MASTER-ADDR-BY-NAME", name)
          host ? [host, port] : "doesn't know it" #: [String, String] | String
        rescue ConnectionError, CommandError => e
          e
        ensure
          sentinel.close
        end
      end

      # AUTH, SELECT and CLIENT SETNAME, pipelined. Behind Sentinel, ROLE
      # confirms the server is still the master: right after a failover a
      # Sentinel may briefly hand out the old one.
      def handshake
        commands = [] #: Array[command]
        commands << ["AUTH", *@options.fetch_values(:username, :password).compact] if @options.fetch(:password)
        commands << ["SELECT", @options.fetch(:db)] unless Integer(@options.fetch(:db)).zero?
        commands << ["CLIENT", "SETNAME", @options.fetch(:name)] if @options.fetch(:name)
        commands << ["ROLE"] if @sentinels
        write(encode(commands))
        replies = commands.map do
          reply = read_reply(@options.fetch(:connect_timeout) + @options.fetch(:read_timeout))
          raise reply if reply.instance_of?(CommandError)

          reply
        end
        return unless @sentinels

        role = replies.last.first
        raise ConnectionError, "#{id} reached a #{role}, not the master" unless role == "master"
      end

      def wrap_ssl(sock, host)
        ctx = OpenSSL::SSL::SSLContext.new
        ctx.set_params(@options.fetch(:ssl_params))
        # Check the hostname ourselves after the handshake, the same way on
        # every engine: not every OpenSSL binding (e.g. JRuby's) honors
        # verify_hostname.
        check_hostname = ctx.verify_hostname && !ctx.verify_mode.equal?(OpenSSL::SSL::VERIFY_NONE)
        ctx.verify_hostname = false
        ssl = OpenSSL::SSL::SSLSocket.new(sock, ctx)
        ssl.sync_close = true
        ssl.hostname = host
        loop do
          state = ssl.connect_nonblock(exception: false)
          break unless state.instance_of?(Symbol)

          wait(sock, state, @options.fetch(:connect_timeout))
        end
        ssl.post_connection_check(host) if check_hostname
        ssl
      rescue Exception # rubocop:disable Lint/RescueException
        sock.close
        raise
      end

      # Writes +data+. If the connection breaks after part of it went out,
      # the server may run some of it, so that's a ConnectionError (never
      # retried); a write that sent nothing raises the original error.
      def write(data)
        # @type ivar @sock: Socket | UNIXSocket | OpenSSL::SSL::SSLSocket
        total = data.bytesize
        until data.empty?
          written = @sock.write_nonblock(data, exception: false)
          if written.instance_of?(Symbol)
            wait(@sock, written, @options.fetch(:write_timeout))
          else
            data = data.byteslice(written..) #: String
          end
        end
      rescue Errno::EPIPE, Errno::ECONNRESET, Errno::ECONNABORTED, IOError => e
        raise if data.bytesize == total

        close
        raise ConnectionError, "#{e.class}: #{e} (#{id})"
      end

      def read_reply(timeout)
        loop do
          result = PARSER.parse(@buf, @pos)
          return consume(result) if result

          fill(timeout)
        end
      end

      # Returns a parsed reply's value and moves past it. Once every buffered
      # byte has been consumed the buffer is emptied, so a large reply's
      # memory isn't held on to between commands.
      def consume(result)
        value, pos = result
        if pos == @buf.bytesize
          @buf.clear
          @pos = 0
        else
          @pos = pos
        end
        value
      end

      # Reads whatever the server has sent, waiting up to +timeout+ for it.
      def fill(timeout)
        # @type ivar @sock: Socket | UNIXSocket | OpenSSL::SSL::SSLSocket
        return native_fill(timeout) if @native_io

        chunk = @sock.read_nonblock(READ_CHUNK, exception: false)
        raise ConnectionError, "connection closed by Redis server (#{id})" unless chunk

        chunk.instance_of?(Symbol) ? wait(@sock, chunk, timeout) : @buf << chunk
      end

      # Waits for and reads more of the reply in C (see NATIVE_IO).
      def native_fill(timeout)
        # @type ivar @native_io: singleton(NativeIO)
        # @type ivar @sock: Socket | UNIXSocket
        filled(@native_io.fill(@sock, @buf, timeout))
      end

      # Raises for what NativeIO.fill returns when it read nothing.
      def filled(read)
        raise ConnectionError, "connection closed by Redis server (#{id})" if read.nil?
        raise TimeoutError, "timed out talking to Redis (#{id})" unless read
      end

      # Waits until +io+ is readable or writable; +kind+ is the
      # :wait_readable / :wait_writable symbol a non-blocking call returned.
      # A TLS socket waits on the socket under it (the openssl gem before
      # 3.3, as Ruby 3.3 and earlier ship, has no wait methods of its own).
      def wait(io, kind, timeout)
        ready = timeout.positive? && io.to_io.public_send(kind, timeout)
        raise TimeoutError, "timed out talking to Redis (#{id})" unless ready
      end
    end

    # Collects commands for Connection#pipelined and Connection#multi.
    class Pipeline
      attr_reader :commands

      NONE = [] #: Array[untyped]
        .freeze

      # +scripts+: the SHAs of the scripts the connection's server has, for
      # a pipeline (see #evalsha); nil for a transaction.
      def initialize(scripts = nil)
        @commands = []
        @scripts = scripts
        # {position => SHA} of the SCRIPT LOADs it adds, made once a script
        # needs loading (most pipelines don't): @loads.
      end

      # The positions of the SCRIPT LOADs it added, and the SHAs they load.
      def loads = @loads&.keys || NONE

      def loading = @loads&.values || NONE

      def call(*args)
        @commands << args
        nil
      end

      # A pipeline can't recover from a NOSCRIPT mid-flight, as what it sent
      # after it has run already, so a script its server may not have is
      # loaded first, in the pipeline: then the script runs by its SHA
      # (not resending its source every time). A server that loses its
      # scripts while connected (SCRIPT FLUSH) fails the pipeline once,
      # like any error, and they're loaded again the next time.
      #
      # A transaction sends the script itself (EVAL), always: one of its
      # commands failing with NOSCRIPT would leave the rest applied.
      def evalsha(script, keys = [], argv = nil)
        # @type ivar @scripts: Set[String]
        unless @scripts
          @commands << ["EVAL", script.source, keys.size, *keys, *argv]
          return
        end
        unless @scripts.include?(script.sha) || @loads&.value?(script.sha)
          (@loads ||= {})[@commands.size] = script.sha
          @commands << ["SCRIPT", "LOAD", script.source]
        end
        @commands << ["EVALSHA", script.sha, keys.size, *keys, *argv]
        nil
      end
    end

    # A Lua script with a precomputed SHA1 for EVALSHA.
    class Script
      attr_reader :source, :sha

      def initialize(source)
        @source = source.strip.freeze
        @sha = Digest::SHA1.hexdigest(@source).freeze
      end
    end
  end
end
