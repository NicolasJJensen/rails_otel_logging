# frozen_string_literal: true

require "spec_helper"
require "otel_logging/silencers"

RSpec.describe OtelLogging::Silencers do
  let(:subscriber_class) do
    Class.new do
      def start_processing(_event)
        :delegated
      end

      def send_file(_event)
        :delegated
      end
    end
  end
  let(:subscriber) { subscriber_class.new }

  before do
    OtelLogging.config.rails_logs = :replace
  end

  it "preserves framework logs outside an active trace" do
    subscriber_class.prepend(described_class::ActionControllerMethods)

    expect(subscriber.start_processing(nil)).to eq(:delegated)
  end

  it "replaces covered framework logs only inside an active trace" do
    subscriber_class.prepend(described_class::ActionControllerMethods)

    OtelLogging.with_trace("request") do
      expect(subscriber.start_processing(nil)).to be_nil
      expect(subscriber.send_file(nil)).to eq(:delegated)
    end
  end

  it "does not prepend the same wrapper more than once" do
    described_class.send(:prepend_once, subscriber_class, described_class::ActionControllerMethods)
    described_class.send(:prepend_once, subscriber_class, described_class::ActionControllerMethods)

    expect(subscriber_class.ancestors.count(described_class::ActionControllerMethods)).to eq(1)
  end
end
