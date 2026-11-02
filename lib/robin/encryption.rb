# frozen_string_literal: true

require "openssl"

module Robin
  # Encrypts job arguments at rest with AES-256-GCM.
  #
  #   Robin.configure do |config|
  #     config.encryption_keys = {1 => ENV["ROBIN_KEY_V1"], 2 => ENV["ROBIN_KEY_V2"]}
  #   end
  #
  #   class ChargeCard
  #     include Robin::Job
  #     robin_options encrypt: true
  #   end
  #
  # With +encrypt: "last"+ only the last argument is encrypted (it should
  # hold the secrets, e.g. a Hash of them); the others stay readable, in
  # the dashboard too.
  #
  # The highest key version encrypts; every listed version can decrypt, so
  # keys can be rotated by adding a new version and removing the old one
  # once older jobs have drained. Keys are 32 bytes, given raw, as 64 hex
  # characters, or base64. The jid is authenticated along with the
  # arguments, so ciphertext can't be moved to another job. Retries and the
  # dead set only ever store ciphertext.
  module Encryption
    class Error < Robin::Error; end

    CIPHER = "aes-256-gcm"
    IV_BYTES = 12
    TAG_BYTES = 16

    class << self
      def keys(config)
        keys = config.encryption_keys
        raise Error, "encrypted jobs need config.encryption_keys (e.g. {1 => <32-byte key>})" if keys.nil? || keys.empty?

        keys.to_h { |version, key| [Integer(version), normalize_key(key)] }
      end

      def normalize_key(key)
        key = key.to_s
        return key.b if key.bytesize == 32
        return [key].pack("H*") if key.match?(/\A\h{64}\z/)

        # (Base64 unpacks to a String, which Steep can't tell from the format.)
        decoded = begin
          key.unpack1("m0")
        rescue
          ""
        end #: String
        return decoded if decoded.bytesize == 32

        raise Error, "encryption keys must be 32 bytes (raw, 64 hex chars, or base64)"
      end

      # Returns [version, ciphertext].
      def encrypt(config, args, aad)
        all = keys(config)
        version = all.keys.max
        cipher = cipher(:encrypt, all.fetch(version))
        iv = cipher.random_iv
        cipher.auth_data = aad
        data = cipher.update(Robin.dump_json(args)) + cipher.final
        [version, [iv + cipher.auth_tag + data].pack("m0")]
      end

      def decrypt(config, version, blob, aad)
        key = keys(config).fetch(version) { raise Error, "no encryption key for version #{version}" }
        raw = blob.unpack1("m0") #: String
        cipher = cipher(:decrypt, key)
        # (A slice past the end of a blob cut short is nil, not a String:
        # the TypeError that raises is rescued below.)
        iv = raw.byteslice(0, IV_BYTES) #: String
        tag = raw.byteslice(IV_BYTES, TAG_BYTES) #: String
        data = raw.byteslice((IV_BYTES + TAG_BYTES)..) #: String
        cipher.iv = iv
        cipher.auth_tag = tag
        cipher.auth_data = aad
        Robin.load_json(cipher.update(data) + cipher.final)
      rescue OpenSSL::Cipher::CipherError, ArgumentError, TypeError
        raise Error, "could not decrypt job arguments (wrong key or tampered payload)"
      end

      # Whether only the job's last argument is encrypted.
      def last_only?(payload) = payload["encrypt"].to_s == "last"

      # An encrypted job's arguments as they may be shown: the encrypted
      # ones hidden.
      def visible_args(payload)
        last_only?(payload) ? [*payload.fetch("args")[...-1], "[encrypted]"] : ["[encrypted]"]
      end

      def cipher(mode, key)
        cipher = OpenSSL::Cipher.new(CIPHER)
        cipher.public_send(mode)
        cipher.key = key
        cipher
      end
    end

    class ClientMiddleware
      include Middleware::ConfigAware
      include Middleware::Stateless

      def self.applies?(_job_class, payload, _queue, _redis) = payload.key?("encrypt")

      def call(_job_class, payload, _queue, _redis)
        if payload["encrypt"] && !payload["encrypted"]
          *clear, secret = args = payload.fetch("args")
          last = Encryption.last_only?(payload)
          version, blob = Encryption.encrypt(config, last ? secret : args, payload.fetch("jid"))
          payload["args"] = last ? [*clear, blob] : [blob]
          payload["encrypted"] = version
        end
        yield
      end
    end

    class ServerMiddleware
      include Middleware::ConfigAware
      include Middleware::Stateless

      def self.applies?(_job, payload, _queue) = payload.key?("encrypted")

      def call(_job, payload, _queue)
        return yield unless payload["encrypted"]

        original = payload.fetch("args")
        version = payload.fetch("encrypted")
        payload["args"] = if Encryption.last_only?(payload)
          [*original[...-1], Encryption.decrypt(config, version, original.last, payload.fetch("jid"))]
        else
          Encryption.decrypt(config, version, original.first, payload.fetch("jid"))
        end
        begin
          yield
        ensure
          # Jobs are written back from Robin.pristine, but code that looks
          # at the payload afterwards shouldn't see plaintext either.
          payload["args"] = original
        end
      end
    end
  end
end
