# frozen_string_literal: true

require "socket"
require "openssl"

# A scriptable stand-in for a Redis server, for driving connection code
# into states real Redis won't produce on demand (auth failures, dropped
# connections, stalls, TLS).
#
#   server = FakeRedis.new { |command, client| "+OK\r\n" }
#
# The block receives each command (an array of strings) and the client's
# index (0 for the first connection, ...), and returns what to do:
#   a String   - send it as the raw reply
#   :close     - close the connection without replying
#   :ignore    - send nothing (the client will time out)
#   a Proc     - called with the socket (to write in odd ways)
#
# Modes: :normal; :silent reads but never answers (stalls TLS handshakes);
# :deaf never reads at all (fills the client's send buffer).
class FakeRedis
  attr_reader :port, :path, :connections, :disconnects

  class << self
    # The TLS server name (SNI) the last TLS client asked for.
    attr_accessor :last_server_name
  end

  def self.ok = "+OK\r\n"

  def self.bulk(str) = "$#{str.bytesize}\r\n#{str}\r\n"

  def self.error(msg) = "-#{msg}\r\n"

  # An SSL context whose self-signed certificate is valid for +names+
  # (e.g. "DNS:localhost,IP:127.0.0.1"), plus a store trusting it.
  def self.tls(names = "DNS:localhost,IP:127.0.0.1")
    (@tls ||= {})[names] ||= begin
      key = OpenSSL::PKey::RSA.new(2048)
      cert = OpenSSL::X509::Certificate.new
      cert.version = 2
      cert.serial = 1
      cert.subject = cert.issuer = OpenSSL::X509::Name.parse("/CN=robin-test")
      cert.public_key = key.public_key
      cert.not_before = Time.now - 60
      cert.not_after = Time.now + 3600
      ef = OpenSSL::X509::ExtensionFactory.new(cert, cert)
      cert.add_extension(ef.create_extension("subjectAltName", names))
      cert.sign(key, OpenSSL::Digest.new("SHA256"))
      ctx = OpenSSL::SSL::SSLContext.new
      ctx.cert = cert
      ctx.key = key
      ctx.servername_cb = lambda do |(_socket, name)|
        FakeRedis.last_server_name = name
        nil
      end
      store = OpenSSL::X509::Store.new
      store.add_cert(cert)
      [ctx, store]
    end
  end

  # Listens on a unix socket unless +tcp+ is true: tests open and close
  # many connections, and unix sockets don't use up ephemeral TCP ports.
  def initialize(tls: nil, mode: :normal, tcp: false, host: "127.0.0.1", &handler)
    @handler = handler || ->(_command, _client) { FakeRedis.ok }
    @commands = Thread::Queue.new
    @connections = 0
    @disconnects = 0
    if tcp
      @server = TCPServer.new(host, 0)
      @port = @server.addr[1]
    else
      @path = "/tmp/robin-fake-#{Process.pid}-#{object_id}.sock"
      @server = UNIXServer.new(@path)
    end
    @tls = tls
    @mode = mode
    @sockets = Thread::Queue.new
    @thread = Thread.new { accept_loop }
  end

  # Commands received so far, in order.
  def received
    list = []
    list << @commands.pop until @commands.empty?
    list
  end

  def close
    @thread.kill
    @thread.join
    @sockets.pop.close until @sockets.empty?
    @server.close
    File.delete(@path) if @path
  end

  private

  def accept_loop
    loop do
      sock = @server.accept
      @sockets << sock
      index = @connections
      @connections += 1
      Thread.new { serve(sock, index) }
    end
  end

  def serve(sock, index)
    return sleep if @mode == :deaf

    sock = start_tls(sock) if @tls && @mode == :normal
    buf = +"".b
    loop do
      process(sock, buf, index) if @mode == :normal
      buf << sock.readpartial(65_536)
    end
  rescue EOFError
    @disconnects += 1
  rescue IOError, SystemCallError, OpenSSL::SSL::SSLError
    nil
  end

  def start_tls(sock)
    ssl = OpenSSL::SSL::SSLSocket.new(sock, FakeRedis.tls(@tls).first)
    ssl.sync_close = true
    ssl.accept
  end

  def process(sock, buf, index)
    while (parsed = Robin::Redis::RESP.parse(buf, 0))
      command, used = parsed
      buf.replace(buf.byteslice(used..))
      @commands << command
      reply = @handler.call(command, index)
      case reply
      when :close then raise EOFError, sock.close
      when :ignore then nil
      when Proc then reply.call(sock)
      else sock.write(reply)
      end
    end
  end
end
