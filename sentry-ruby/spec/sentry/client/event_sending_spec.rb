# frozen_string_literal: true

RSpec.describe Sentry::Client do
  let(:configuration) do
    Sentry::Configuration.new.tap do |config|
      config.sdk_logger = Logger.new(nil)
      config.dsn = Sentry::TestHelper::DUMMY_DSN
      config.transport.transport_class = Sentry::DummyTransport
    end
  end

  before do
    stub_request(:post, Sentry::TestHelper::DUMMY_DSN)
  end

  subject(:client) { Sentry::Client.new(configuration) }

  let(:hub) do
    Sentry::Hub.new(client, Sentry::Scope.new)
  end

  let(:transaction) do
    transaction = Sentry::Transaction.new(name: "test transaction", op: "rack.request", hub: hub)
    5.times { |i| transaction.with_child_span(description: "span_#{i}") { } }
    transaction
  end
  let(:transaction_event) { client.event_from_transaction(transaction) }

  describe "#capture_event" do
    let(:message) { "Test message" }
    let(:scope) { Sentry::Scope.new }
    let(:event) { client.event_from_message(message) }

    context "with sample_rate set" do
      before do
        configuration.sample_rate = 0.5
        configuration.background_worker_threads = 0
      end

      context "with Event" do
        it "sends the event when it's sampled" do
          allow(Random).to receive(:rand).and_return(0.49)
          client.capture_event(event, scope)
          expect(client.transport.events.count).to eq(1)
        end

        it "doesn't send the event when it's not sampled" do
          allow(Random).to receive(:rand).and_return(0.51)
          client.capture_event(event, scope)
          expect(client.transport).to have_recorded_lost_event(:sample_rate, 'error')
          expect(client.transport.events.count).to eq(0)
        end
      end

      context "with TransactionEvent" do
        it "ignores the sampling" do
          allow(Random).to receive(:rand).and_return(0.51)
          client.capture_event(transaction_event, scope)
          expect(client.transport.events.count).to eq(1)
        end
      end
    end

    context 'with config.async set' do
      let(:async_block) do
        lambda do |event|
          client.send_event(event)
        end
      end

      around do |example|
        prior_async = configuration.async
        configuration.async = async_block
        example.run
        configuration.async = prior_async
      end

      it "executes the given block" do
        expect(async_block).to receive(:call).and_call_original

        returned = client.capture_event(event, scope)

        expect(returned).to be_a(Sentry::ErrorEvent)
        expect(client.transport.events.first).to eq(event.to_json_compatible)
      end

      it "doesn't call the async block if not allow sending events" do
        allow(configuration).to receive(:sending_allowed?).and_return(false)

        expect(async_block).not_to receive(:call)

        returned = client.capture_event(event, scope)

        expect(returned).to eq(nil)
      end

      context "with to json conversion failed" do
        let(:logger) { ::Logger.new(string_io) }
        let(:string_io) { StringIO.new }
        let(:event) { client.event_from_message("Bad data '\x80\xF8'") }

        it "does not mask the exception" do
          configuration.sdk_logger = logger

          client.capture_event(event, scope)

          expect(string_io.string).to match(/Converting event \(#{event.event_id}\) to JSON compatible hash failed:.*illegal\/malformed utf-8/i)
        end
      end

      context "with nil as value (the legacy way to disable it)" do
        let(:async_block) { nil }

        it "doesn't cause any issue" do
          returned = client.capture_event(event, scope, { background: false })

          expect(returned).to be_a(Sentry::ErrorEvent)
          expect(client.transport.events.first).to eq(event)
        end
      end

      context "with 2 arity block" do
        let(:async_block) do
          lambda do |event, hint|
            event["tags"]["hint"] = hint
            client.send_event(event)
          end
        end

        it "serializes hint and supplies it as the second argument" do
          expect(configuration.async).to receive(:call).and_call_original

          returned = client.capture_event(event, scope, { foo: "bar" })

          expect(returned).to be_a(Sentry::ErrorEvent)
          event = client.transport.events.first
          expect(event.dig("tags", "hint")).to eq({ "foo" => "bar" })
        end
      end
    end

    context "with background_worker enabled (default)" do
      before do
        Sentry.background_worker = Sentry::BackgroundWorker.new(configuration)
        configuration.before_send = lambda do |event, _hint|
          sleep 0.1
          event
        end
      end

      it "sends events asynchronously" do
        client.capture_event(event, scope)

        expect(client.transport.events.count).to eq(0)

        sleep(0.2)

        expect(client.transport.events.count).to eq(1)
      end

      context "with hint: { background: false }" do
        it "sends the event immediately" do
          client.capture_event(event, scope, { background: false })

          expect(client.transport.events.count).to eq(1)
        end
      end

      context "with config.background_worker_threads set to 0 on the fly" do
        it "sends the event immediately" do
          configuration.background_worker_threads = 0

          client.capture_event(event, scope)

          expect(client.transport.events.count).to eq(1)
        end
      end

      it "records queue overflow for error event" do
        allow(Sentry.background_worker).to receive(:perform).and_return(false)

        client.capture_event(event, scope)
        expect(client.transport).to have_recorded_lost_event(:queue_overflow, 'error')

        expect(client.transport.events.count).to eq(0)
        sleep(0.2)
        expect(client.transport.events.count).to eq(0)
      end

      it "records queue overflow for transaction event with span counts" do
        allow(Sentry.background_worker).to receive(:perform).and_return(false)

        client.capture_event(transaction_event, scope)
        expect(client.transport).to have_recorded_lost_event(:queue_overflow, 'transaction')
        expect(client.transport).to have_recorded_lost_event(:queue_overflow, 'span', num: 6)

        expect(client.transport.events.count).to eq(0)
        sleep(0.2)
        expect(client.transport.events.count).to eq(0)
      end
    end
  end

  describe "#send_event" do
    let(:event_object) do
      client.event_from_exception(ZeroDivisionError.new("divided by 0"))
    end

    shared_examples "Event in send_event" do
      context "when there's an exception" do
        before do
          expect(client.transport).to receive(:send_event).and_raise(Sentry::ExternalError.new("networking error"))
        end

        it "raises the error" do
          expect do
            client.send_event(event)
          end.to raise_error(Sentry::ExternalError, "networking error")
        end
      end
      it "sends data through the transport" do
        expect(client.transport).to receive(:send_event).with(event)
        client.send_event(event)
      end

      it "applies before_send callback before sending the event" do
        configuration.before_send = lambda do |event, _hint|
          if event.is_a?(Sentry::Event)
            event.tags[:called] = true
          else
            event["tags"]["called"] = true
          end

          event
        end

        client.send_event(event)

        if event.is_a?(Sentry::Event)
          expect(event.tags[:called]).to eq(true)
        else
          expect(event["tags"]["called"]).to eq(true)
        end
      end

      context "for check in events" do
        let(:event_object) { client.event_from_check_in("test_slug", :ok)  }

        it "does not fail due to before_send" do
          configuration.before_send = lambda { |e, _h| e }
          client.send_event(event)

          expect(client.transport).to receive(:send_event).with(event)
          client.send_event(event)
        end
      end

      it "doesn't apply before_send_transaction to Event" do
        dbl = double("before_send_transaction")
        allow(dbl).to receive(:call)
        configuration.before_send_transaction = dbl

        expect(dbl).not_to receive(:call)
        client.send_event(event)
      end

      it "warns if before_send returns nil" do
        string_io = StringIO.new
        logger = Logger.new(string_io, level: :debug)
        configuration.sdk_logger = logger
        configuration.before_send = lambda do |_event, _hint|
          nil
        end

        client.send_event(event)
        expect(string_io.string).to include("Discarded event because before_send didn't return a Sentry::ErrorEvent object but an instance of NilClass")
      end

      it "warns if before_send returns non-Event objects" do
        string_io = StringIO.new
        logger = Logger.new(string_io, level: :debug)
        configuration.sdk_logger = logger
        configuration.before_send = lambda do |_event, _hint|
          123
        end

        return_value = client.send_event(event)
        expect(string_io.string).to include("Discarded event because before_send didn't return a Sentry::ErrorEvent object but an instance of Integer")
        expect(return_value).to eq(nil)
      end

      it "warns about Hash value's deprecation" do
        string_io = StringIO.new
        logger = Logger.new(string_io, level: :debug)
        configuration.sdk_logger = logger
        configuration.before_send = lambda do |_event, _hint|
          { foo: "bar" }
        end

        return_value = client.send_event(event)
        expect(string_io.string).to include("Returning a Hash from before_send is deprecated and will be removed in the next major version.")
        expect(return_value).to eq({ foo: "bar" })
      end
    end

    it_behaves_like "Event in send_event" do
      let(:event) { event_object }
    end

    it_behaves_like "Event in send_event" do
      let(:event) { event_object.to_json_compatible }
    end

    shared_examples "TransactionEvent in send_event" do
      it "sends data through the transport" do
        client.send_event(event)
      end

      it "doesn't apply before_send to TransactionEvent" do
        configuration.before_send = lambda do |event, _hint|
          raise "shouldn't trigger me"
        end

        client.send_event(event)
      end

      it "applies before_send_transaction callback before sending the event" do
        configuration.before_send_transaction = lambda do |event, _hint|
          if event.is_a?(Sentry::TransactionEvent)
            event.tags[:called] = true
          else
            event["tags"]["called"] = true
          end

          event
        end

        client.send_event(event)

        if event.is_a?(Sentry::Event)
          expect(event.tags[:called]).to eq(true)
        else
          expect(event["tags"]["called"]).to eq(true)
        end
      end

      it "warns if before_send_transaction returns nil" do
        string_io = StringIO.new
        logger = Logger.new(string_io, level: :debug)
        configuration.sdk_logger = logger
        configuration.before_send_transaction = lambda do |_event, _hint|
          nil
        end

        return_value = client.send_event(event)
        expect(string_io.string).to include("Discarded event because before_send_transaction didn't return a Sentry::TransactionEvent object but an instance of NilClass")
        expect(return_value).to be_nil
      end

      it "warns about Hash value's deprecation" do
        string_io = StringIO.new
        logger = Logger.new(string_io, level: :debug)
        configuration.sdk_logger = logger
        configuration.before_send_transaction = lambda do |_event, _hint|
          { foo: "bar" }
        end

        return_value = client.send_event(event)
        expect(string_io.string).to include("Returning a Hash from before_send_transaction is deprecated and will be removed in the next major version.")
        expect(return_value).to eq({ foo: "bar" })
      end
    end

    it_behaves_like "TransactionEvent in send_event" do
      let(:event) { transaction_event }
    end

    it_behaves_like "TransactionEvent in send_event" do
      let(:event) { transaction_event.to_json_compatible }
    end
  end

  describe "integrated error handling testing with HTTPTransport" do
    let(:string_io) { StringIO.new }
    let(:logger) do
      ::Logger.new(string_io)
    end
    let(:configuration) do
      Sentry::Configuration.new.tap do |config|
        config.dsn = Sentry::TestHelper::DUMMY_DSN
        config.sdk_logger = logger
      end
    end

    let(:message) { "Test message" }
    let(:scope) { Sentry::Scope.new }
    let(:event) { client.event_from_message(message) }

    describe "#capture_event" do
      around do |example|
        prior_async = configuration.async
        example.run
        configuration.async = prior_async
      end

      context "when scope.apply_to_event returns nil" do
        before do
          scope.add_event_processor do |event, hint|
            nil
          end
        end

        it "discards the event and logs a info" do
          expect(client.capture_event(event, scope)).to be_nil

          expect(string_io.string).to match(/Discarded event because one of the event processors returned nil/)
        end

        it "records correct client report for error event" do
          client.capture_event(event, scope)
          expect(client.transport).to have_recorded_lost_event(:event_processor, 'error')
        end

        it "records correct transaction and span client reports for transaction event" do
          client.capture_event(transaction_event, scope)
          expect(client.transport).to have_recorded_lost_event(:event_processor, 'transaction')
          expect(client.transport).to have_recorded_lost_event(:event_processor, 'span', num: 6)
        end
      end

      context "when scope.apply_to_event modifies spans" do
        before do
          scope.add_event_processor do |event, hint|
            2.times { event.spans.pop }
            event
          end
        end

        it "records correct span delta client report for transaction event" do
          client.capture_event(transaction_event, scope)
          expect(client.transport).to have_recorded_lost_event(:event_processor, 'span', num: 2)
        end
      end

      context "when scope.apply_to_event fails" do
        before do
          scope.add_event_processor do
            raise TypeError
          end
        end

        it "swallows the event and logs the failure" do
          expect(client.capture_event(event, scope)).to be_nil

          expect(string_io.string).to match(/Event capturing failed: TypeError/)
          expect(string_io.string).not_to match(__FILE__)
        end

        context "with config.debug = true" do
          before do
            configuration.debug = true
          end
          it "logs the error with backtrace" do
            expect(client.capture_event(event, scope)).to be_nil

            expect(string_io.string).to match(/Event capturing failed: TypeError/)
            expect(string_io.string).to match(__FILE__)
          end
        end
      end

      context "when sending events inline causes error" do
        before do
          configuration.background_worker_threads = 0
          Sentry.background_worker = Sentry::BackgroundWorker.new(configuration)

          stub_request(:post, "http://sentry.localdomain/sentry/api/42/envelope/")
            .to_raise(Timeout::Error)
        end

        it "swallows and logs Sentry::ExternalError (caused by transport's networking error)" do
          expect(client.capture_event(event, scope)).to be_nil

          expect(string_io.string).to match(/Event sending failed: Exception from WebMock/)
          expect(string_io.string).to match(/Event capturing failed: Exception from WebMock/)
        end

        it "swallows and logs errors caused by the user (like in before_send)" do
          configuration.before_send = ->(_, _) { raise TypeError }

          expect(client.capture_event(event, scope)).to be_nil

          expect(string_io.string).to match(/Event sending failed: TypeError/)
        end

        it "captures client report for error event" do
          client.capture_event(event, scope)
          expect(client.transport).to have_recorded_lost_event(:network_error, 'error')
        end

        it "captures client report for transaction event with span counts" do
          client.capture_event(transaction_event, scope)
          expect(client.transport).to have_recorded_lost_event(:network_error, 'transaction')
          expect(client.transport).to have_recorded_lost_event(:network_error, 'span', num: 6)
        end
      end

      context "when sending events in background causes error", retry: 3 do
        before do
          Sentry.background_worker = Sentry::BackgroundWorker.new(configuration)

          stub_request(:post, "http://sentry.localdomain/sentry/api/42/envelope/")
            .to_raise(Timeout::Error)
        end

        it "swallows and logs Sentry::ExternalError (caused by transport's networking error)" do
          expect(client.capture_event(event, scope)).to be_a(Sentry::ErrorEvent)
          sleep(0.2)

          expect(string_io.string).to match(/Event sending failed: Exception from WebMock/)
        end

        it "swallows and logs errors caused by the user (like in before_send)" do
          configuration.before_send = ->(_, _) { raise TypeError }

          expect(client.capture_event(event, scope)).to be_a(Sentry::ErrorEvent)
          sleep(0.2)

          expect(string_io.string).to match(/Event sending failed: TypeError/)
        end

        it "captures client report for error event" do
          client.capture_event(event, scope)
          sleep(0.2)
          expect(client.transport).to have_recorded_lost_event(:network_error, 'error')
        end

        it "captures client report for transaction event with span counts" do
          client.capture_event(transaction_event, scope)
          sleep(0.2)
          expect(client.transport).to have_recorded_lost_event(:network_error, 'transaction')
          expect(client.transport).to have_recorded_lost_event(:network_error, 'span', num: 6)
        end
      end

      context "when config.async causes error" do
        before do
          expect(client).to receive(:send_event)
        end

        it "swallows Redis related error and send the event synchronizely" do
          configuration.async = ->(_, _) { raise Redis::ConnectionError }

          client.capture_event(event, scope)

          expect(string_io.string).to match(/Async event sending failed: Redis::ConnectionError/)
        end

        it "swallows and logs the exception" do
          configuration.async = ->(_, _) { raise TypeError }

          client.capture_event(event, scope)

          expect(string_io.string).to match(/Async event sending failed: TypeError/)
        end
      end
    end

    describe "#send_event" do
      context "error happens when sending the event" do
        it "raises the error" do
          stub_request(:post, "http://sentry.localdomain/sentry/api/42/envelope/")
            .to_raise(Timeout::Error)

          expect do
            client.send_event(event)
          end.to raise_error(Sentry::ExternalError)

          expect(string_io.string).to match(/Event sending failed: Exception from WebMock/)
        end
      end

      context "error happens in the before_send callback" do
        before do
          configuration.before_send = lambda do |event, _hint|
            raise TypeError
          end
        end

        it "raises the error" do
          expect do
            client.send_event(event)
          end.to raise_error(TypeError)

          expect(string_io.string).to match(/Event sending failed: TypeError/)
        end

        context "with config.debug = true" do
          before do
            configuration.debug = true
          end

          it "logs the error with backtrace" do
            expect do
              client.send_event(event)
            end.to raise_error(TypeError)

            expect(string_io.string).to match(/Event sending failed: TypeError/)
            expect(string_io.string).to match(__FILE__)
          end
        end
      end

      context "before_send returns nil" do
        before do
          configuration.before_send = lambda do |_event, _hint|
            nil
          end
        end

        it "records lost error event" do
          client.send_event(event)
          expect(client.transport).to have_recorded_lost_event(:before_send, 'error')
        end
      end

      context "before_send_transaction returns nil" do
        before do
          configuration.before_send_transaction = lambda do |_event, _hint|
            nil
          end
        end

        it "records lost transaction with span counts client reports" do
          client.send_event(transaction_event)
          expect(client.transport).to have_recorded_lost_event(:before_send, 'transaction')
          expect(client.transport).to have_recorded_lost_event(:before_send, 'span', num: 6)
        end
      end

      context "before_send_transaction modifies spans" do
        before do
          configuration.before_send_transaction = lambda do |event, _hint|
            2.times { event.spans.pop }
            event
          end
        end

        it "records lost span delta client reports" do
          stub_request(:post, "http://sentry.localdomain/sentry/api/42/envelope/")
            .to_raise(Timeout::Error)

          expect { client.send_event(transaction_event) }.to raise_error(Sentry::ExternalError)
          expect(client.transport).to have_recorded_lost_event(:before_send, 'span', num: 2)
        end
      end
    end
  end
end
