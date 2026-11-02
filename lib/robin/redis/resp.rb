# frozen_string_literal: true

module Robin
  module Redis
    # Raised for "-ERR ..." replies. Error replies nested inside arrays (for
    # example, inside an EXEC result) are returned as instances rather than
    # raised so callers can decide what to do with them.
    class CommandError < StandardError; end

    class ProtocolError < StandardError; end

    # Encodes commands and decodes replies in the Redis serialization
    # protocol, version 2 (Robin never switches a connection to RESP3).
    #
    # The decoder works on an in-memory buffer: +parse(buffer, offset)+
    # returns +[value, next_offset]+ or +nil+ when the buffer does not yet
    # hold a complete reply. That contract lets the optional C extension
    # (Robin::Redis::NativeRESP) be swapped in transparently.
    module RESP
      CRLF = "\r\n"

      # Appends the command +args+ (anything responding to #to_s) to +out+.
      def self.encode(args, out = "".b)
        out << "*" << args.size.to_s << CRLF
        args.each do |arg|
          str = arg.to_s
          out << "$" << str.bytesize.to_s << CRLF << str.b << CRLF
        end
        out
      end

      def self.parse(buf, pos)
        eol = buf.byteindex(CRLF, pos)
        return unless eol

        line = buf.byteslice(pos + 1, eol - pos - 1) #: String
        nxt = eol + 2
        case buf.getbyte(pos)
        when 43 then [utf8(line), nxt] # +
        when 45 then [CommandError.new(utf8(line)), nxt] # -
        when 58 then [Integer(line), nxt] # :
        when 36 then parse_bulk(buf, nxt, Integer(line)) # $
        when 42 then parse_array(buf, nxt, Integer(line)) # *
        else raise ProtocolError, "unknown RESP type byte #{buf.getbyte(pos)}"
        end
      end

      def self.parse_bulk(buf, pos, len)
        return [nil, pos] if len.negative?

        stop = pos + len
        return if buf.bytesize < stop + 2

        # (The buffer holds len more bytes, so the slice isn't nil.)
        [utf8(buf.byteslice(pos, len)), stop + 2] # steep:ignore ArgumentTypeMismatch
      end

      def self.parse_array(buf, pos, count)
        return [nil, pos] if count.negative?

        items = [] #: Array[reply]
        count.times do
          result = parse(buf, pos)
          return unless result

          value, pos = result
          items << value
        end
        [items, pos]
      end

      def self.utf8(str) = str.force_encoding(Encoding::UTF_8)

      private_class_method :parse_bulk, :parse_array, :utf8
    end
  end
end
