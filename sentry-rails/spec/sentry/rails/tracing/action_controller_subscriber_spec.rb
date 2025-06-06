# frozen_string_literal: true

require "spec_helper"

RSpec.describe Sentry::Rails::Tracing::ActionControllerSubscriber, :subscriber, type: :request do
  let(:transport) do
    Sentry.get_current_client.transport
  end

  context "when transaction is sampled" do
    let(:string_io) { StringIO.new }
    let(:logger) do
      ::Logger.new(string_io)
    end

    before do
      make_basic_app do |config|
        config.traces_sample_rate = 1.0
        config.rails.tracing_subscribers = [described_class]
        config.sdk_logger = logger
      end
    end

    it "logs deprecation message" do
      expect(string_io.string).to include(
        "DEPRECATION WARNING: sentry-rails has changed its approach on controller span recording and Sentry::Rails::Tracing::ActionControllerSubscriber is now depreacted."
      )
    end

    it "records controller action processing event" do
      get "/world"

      expect(transport.events.count).to eq(1)

      transaction = transport.events.first.to_hash
      expect(transaction[:type]).to eq("transaction")
      expect(transaction[:spans].count).to eq(2)

      span = transaction[:spans][0]
      expect(span[:op]).to eq("view.process_action.action_controller")
      expect(span[:origin]).to eq("auto.view.rails")
      expect(span[:description]).to eq("HelloController#world")
      expect(span[:trace_id]).to eq(transaction.dig(:contexts, :trace, :trace_id))
      expect(span[:data].keys).to match_array(["http.response.status_code", :format, :method, :path, :params])
    end
  end

  context "when transaction is not sampled" do
    before do
      make_basic_app
    end

    it "doesn't record spans" do
      transaction = Sentry::Transaction.new(sampled: false, hub: Sentry.get_current_hub)
      Sentry.get_current_scope.set_span(transaction)

      get "/world"

      transaction.finish

      expect(transport.events.count).to eq(0)
      expect(transaction.span_recorder.spans).to eq([transaction])
    end
  end
end
