# frozen_string_literal: true

require 'contexts/with_request_mock'

RSpec.describe Sentry::HTTPTransport do
  include_context "with request mock"

  let(:configuration) do
    Sentry::Configuration.new.tap do |config|
      config.dsn = Sentry::TestHelper::DUMMY_DSN
      config.sdk_logger = Logger.new(nil)
    end
  end
  let(:client) { Sentry::Client.new(configuration) }
  let(:event) { client.event_from_message("foobarbaz") }
  let(:fake_time) { Time.now }
  let(:data) do
    subject.serialize_envelope(subject.envelope_from_event(event.to_hash)).first
  end

  subject { client.transport }

  it "logs a debug message only during initialization" do
    sentry_stub_request(build_fake_response("200"))
    string_io = StringIO.new
    configuration.sdk_logger = Logger.new(string_io)

    subject

    expect(string_io.string).to include("sentry: Sentry HTTP Transport will connect to http://sentry.localdomain")

    string_io.string = ""
    expect(string_io.string).to eq("")

    subject.send_data(data)

    expect(string_io.string).not_to include("sentry: Sentry HTTP Transport will connect to http://sentry.localdomain")
  end

  it "initializes new Net::HTTP instance for every request" do
    sentry_stub_request(build_fake_response("200")) do |request|
      expect(request["User-Agent"]).to eq("sentry-ruby/#{Sentry::VERSION}")
    end

    subject

    expect(Net::HTTP).to receive(:new).and_call_original.exactly(2)

    subject.send_data(data)
    subject.send_data(data)
  end

  describe "port detection" do
    let(:configuration) do
      Sentry::Configuration.new.tap do |config|
        config.dsn = dsn
        config.sdk_logger = Logger.new(nil)
      end
    end

    context "with http DSN" do
      let(:dsn) { "http://12345:67890@sentry.localdomain/sentry/42" }

      it "sets port to 80" do
        expect(subject.send(:conn).port).to eq(80)
      end
    end
    context "with https DSN" do
      let(:dsn) { "https://12345:67890@sentry.localdomain/sentry/42" }

      it "sets port to 443" do
        expect(subject.send(:conn).port).to eq(443)
      end
    end

    context "with specified port" do
      let(:dsn) { "https://12345:67890@sentry.localdomain:1234/sentry/42" }

      it "sets port to 1234" do
        expect(subject.send(:conn).port).to eq(1234)
      end
    end
  end

  describe "customizations" do
    let(:fake_response) { build_fake_response("200") }

    it 'sets default User-Agent' do
      sentry_stub_request(fake_response) do |request|
        expect(request["User-Agent"]).to eq("sentry-ruby/#{Sentry::VERSION}")
      end

      subject.send_data(data)
    end

    it "accepts custom proxy" do
      configuration.transport.proxy = { uri:  URI("https://example.com"), user: "stan", password: "foobar" }

      sentry_stub_request(fake_response) do |_, http_obj|
        expect(http_obj.proxy_address).to eq("example.com")
        expect(http_obj.proxy_user).to eq("stan")
        expect(http_obj.proxy_pass).to eq("foobar")
      end

      subject.send_data(data)
    end

    it "accepts a custom proxy string" do
      configuration.transport.proxy = "https://stan:foobar@example.com:8080"

      sentry_stub_request(fake_response) do |_, http_obj|
        expect(http_obj.proxy_address).to eq("example.com")
        expect(http_obj.proxy_user).to eq("stan")
        expect(http_obj.proxy_pass).to eq("foobar")
        expect(http_obj.proxy_port).to eq(8080)
      end

      subject.send_data(data)
    end

    it "accepts a custom proxy URI" do
      configuration.transport.proxy = URI("https://stan:foobar@example.com:8080")

      sentry_stub_request(fake_response) do |_, http_obj|
        expect(http_obj.proxy_address).to eq("example.com")
        expect(http_obj.proxy_user).to eq("stan")
        expect(http_obj.proxy_pass).to eq("foobar")
        expect(http_obj.proxy_port).to eq(8080)
      end

      subject.send_data(data)
    end

    it "accepts a proxy from ENV[HTTP_PROXY]" do
      begin
        ENV["http_proxy"] = "https://stan:foobar@example.com:8080"

        sentry_stub_request(fake_response) do |_, http_obj|
          expect(http_obj.proxy_address).to eq("example.com")
          expect(http_obj.proxy_port).to eq(8080)

          if Gem::Version.new(RUBY_VERSION) >= Gem::Version.new("2.5")
            expect(http_obj.proxy_user).to eq("stan")
            expect(http_obj.proxy_pass).to eq("foobar")
          end
        end

        subject.send_data(data)
      ensure
        ENV["http_proxy"] = nil
      end
    end

    it "accepts custom timeout" do
      configuration.transport.timeout = 10

      sentry_stub_request(fake_response) do |_, http_obj|
        expect(http_obj.read_timeout).to eq(10)

        if Gem::Version.new(RUBY_VERSION) >= Gem::Version.new("2.6")
          expect(http_obj.write_timeout).to eq(10)
        end
      end

      subject.send_data(data)
    end

    it "accepts custom open_timeout" do
      configuration.transport.open_timeout = 10

      sentry_stub_request(fake_response) do |_, http_obj|
        expect(http_obj.open_timeout).to eq(10)
      end

      subject.send_data(data)
    end

    describe "ssl configurations" do
      it "has the corrent default" do
        sentry_stub_request(fake_response) do |_, http_obj|
          expect(http_obj.verify_mode).to eq(1)
          expect(http_obj.ca_file).to eq(nil)
        end

        subject.send_data(data)
      end

      it "accepts custom ssl_verification configuration" do
        configuration.transport.ssl_verification = false

        sentry_stub_request(fake_response) do |_, http_obj|
          expect(http_obj.verify_mode).to eq(0)
          expect(http_obj.ca_file).to eq(nil)
        end

        subject.send_data(data)
      end

      it "accepts custom ssl_ca_file configuration" do
        configuration.transport.ssl_ca_file = "/tmp/foo"

        sentry_stub_request(fake_response) do |_, http_obj|
          expect(http_obj.verify_mode).to eq(1)
          expect(http_obj.ca_file).to eq("/tmp/foo")
        end

        subject.send_data(data)
      end

      it "accepts custom ssl configuration" do
        configuration.transport.ssl  = { verify: false, ca_file: "/tmp/foo" }

        sentry_stub_request(fake_response) do |_, http_obj|
          expect(http_obj.verify_mode).to eq(0)
          expect(http_obj.ca_file).to eq("/tmp/foo")
        end

        subject.send_data(data)
      end
    end
  end

  describe "request payload" do
    let(:fake_response) { build_fake_response("200") }

    it "compresses data by default" do
      sentry_stub_request(fake_response) do |request|
        expect(request["Content-Type"]).to eq("application/x-sentry-envelope")
        expect(request["Content-Encoding"]).to eq("gzip")

        envelope = Zlib.gunzip(request.body)
        expect(envelope).to include(event.event_id)
        expect(envelope).to include("foobarbaz")
      end

      subject.send_data(data)
    end

    it "doesn't compress small event" do
      sentry_stub_request(fake_response) do |request|
        expect(request["Content-Type"]).to eq("application/x-sentry-envelope")
        expect(request["Content-Encoding"]).to eq("")

        envelope = request.body
        expect(envelope).to include(event.event_id)
        expect(envelope).to include("foobarbaz")
      end

      event.instance_variable_set(:@threads, nil) # shrink event

      subject.send_data(data)
    end

    it "doesn't compress data if the encoding is not gzip" do
      configuration.transport.encoding = "json"

      sentry_stub_request(fake_response) do |request|
        expect(request["Content-Type"]).to eq("application/x-sentry-envelope")
        expect(request["Content-Encoding"]).to eq("")

        envelope = request.body
        expect(envelope).to include(event.event_id)
        expect(envelope).to include("foobarbaz")
      end

      subject.send_data(data)
    end
  end

  describe "failed to perform the network request" do
    it "does not report Net::HTTP errors to Sentry" do
      allow(::Net::HTTP).to receive(:new).and_raise(Errno::ECONNREFUSED)
      expect do
        subject.send_data(data)
      end.to raise_error(Sentry::ExternalError)
    end

    it "does not report SocketError errors to Sentry" do
      allow(::Net::HTTP).to receive(:new).and_raise(SocketError.new("socket error"))
      expect do
        subject.send_data(data)
      end.to raise_error(Sentry::ExternalError)
    end

    it "reports other errors to Sentry if they are not recognized" do
      allow(::Net::HTTP).to receive(:new).and_raise(StandardError.new("Booboo"))
      expect do
        subject.send_data(data)
      end.to raise_error(StandardError, /Booboo/)
    end
  end

  describe "failed request handling" do
    context "receive 4xx responses" do
      let(:fake_response) { build_fake_response("404") }

      it "raises an error" do
        sentry_stub_request(fake_response)

        expect { subject.send_data(data) }.to raise_error(Sentry::ExternalError, /the server responded with status 404/)
      end
    end

    context "receive 5xx responses" do
      let(:fake_response) { build_fake_response("500") }

      it "raises an error" do
        sentry_stub_request(fake_response)

        expect { subject.send_data(data) }.to raise_error(Sentry::ExternalError, /the server responded with status 500/)
      end
    end

    context "receive error responses with headers" do
      let(:error_response) do
        build_fake_response("500", headers: { 'x-sentry-error' => 'error_in_header' })
      end

      it "raises an error with header" do
        sentry_stub_request(error_response)

        expect { subject.send_data(data) }.to raise_error(Sentry::ExternalError, /error_in_header/)
      end
    end
  end

  describe "#generate_auth_header" do
    before do
      allow(Time).to receive(:now).and_return(fake_time)
    end

    it "generates an auth header" do
      expect(subject.send(:generate_auth_header)).to eq(
        "Sentry sentry_version=7, sentry_client=sentry-ruby/#{Sentry::VERSION}, sentry_timestamp=#{fake_time.to_i}, " \
        "sentry_key=12345, sentry_secret=67890"
      )
    end

    it "generates an auth header without a secret (Sentry 9)" do
      configuration.server = "https://66260460f09b5940498e24bb7ce093a0@sentry.io/42"

      expect(subject.send(:generate_auth_header)).to eq(
        "Sentry sentry_version=7, sentry_client=sentry-ruby/#{Sentry::VERSION}, sentry_timestamp=#{fake_time.to_i}, " \
        "sentry_key=66260460f09b5940498e24bb7ce093a0"
      )
    end
  end

  describe "#endpoint" do
    it "returns correct endpoint" do
      expect(subject.endpoint).to eq("/sentry/api/42/envelope/")
    end
  end

  describe "#conn" do
    it "returns a connection" do
      expect(subject.conn).to be_a(Net::HTTP)
      expect(subject.conn.address).to eq("sentry.localdomain")
      expect(subject.conn.use_ssl?).to eq(false)
    end
  end
end
