# spec/lib/otel_spec.rb
# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OtelLogging do
  describe OtelLogging::Configuration do
    subject(:config) { described_class.new }

    describe '#rails_logs' do
      it 'replaces Rails logs by default' do
        expect(config.rails_logs).to eq(:replace)
      end

      it 'accepts preservation and rejects unknown modes' do
        config.rails_logs = :preserve
        expect(config.rails_logs).to eq(:preserve)
        expect { config.rails_logs = :silent }.to raise_error(ArgumentError, /Invalid rails_logs/)
      end

      it 'reads the environment and allows explicit configuration to override it' do
        allow(ENV).to receive(:fetch).with('OTEL_RAILS_LOGS', 'replace').and_return('preserve')
        expect(config.rails_logs).to eq(:preserve)
        config.rails_logs = :replace
        expect(config.rails_logs).to eq(:replace)
      end
    end

    describe '#output_mode' do
      it 'defaults to :live_delayed_on_error' do
        expect(config.output_mode).to eq(:live_delayed_on_error)
      end

      it 'accepts valid output modes' do
        %i[live delayed both live_delayed_on_error].each do |mode|
          config.output_mode = mode
          expect(config.output_mode).to eq(mode)
        end
      end

      it 'raises ArgumentError for invalid modes' do
        expect { config.output_mode = :invalid }.to raise_error(ArgumentError, /Invalid output_mode/)
      end
    end

    describe '#live?' do
      it 'returns true for live modes' do
        %i[live both live_delayed_on_error].each do |mode|
          config.output_mode = mode
          expect(config.live?).to be true
        end
      end

      it 'returns false for delayed mode' do
        config.output_mode = :delayed
        expect(config.live?).to be false
      end
    end

    describe '#delayed?' do
      it 'returns true for delayed and both modes' do
        %i[delayed both].each do |mode|
          config.output_mode = mode
          expect(config.delayed?).to be true
        end
      end

      it 'returns false for live and live_delayed_on_error modes' do
        %i[live live_delayed_on_error].each do |mode|
          config.output_mode = mode
          expect(config.delayed?).to be false
        end
      end
    end

    describe '#delayed_on_error?' do
      it 'returns true only for live_delayed_on_error mode' do
        config.output_mode = :live_delayed_on_error
        expect(config.delayed_on_error?).to be true

        config.output_mode = :delayed
        expect(config.delayed_on_error?).to be false
      end
    end
  end

end
